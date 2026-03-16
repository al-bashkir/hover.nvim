--- Hover provider for decoding Base64 and Base64URL strings.
--- Uses treesitter to detect string nodes under the cursor,
--- then attempts to decode the content as Base64 or Base64URL.
--- Requires Neovim >= 0.10 (for vim.base64).
---
--- Limitations:
--- - Requires a treesitter parser for the buffer's filetype.
--- - Only triggers on recognized treesitter string node types (quoted
---   strings, YAML scalars, etc.) -- not on arbitrary unquoted text.
--- - Only single-line string content is supported; multi-line base64
---   blocks are not joined.
--- - Decoded content must be printable UTF-8 text; binary payloads
---   are rejected to avoid false positives.

local api = vim.api

-- Maximum encoded string length to attempt decoding.
-- Prevents expensive decode on very large strings during enabled().
local MAX_DECODE_LENGTH = 65536

-- Minimum encoded string length to consider as base64.
-- Reduces false positives on short common words that happen to
-- be valid base64 characters.
local MIN_ENCODE_LENGTH = 8

-- Node types that contain raw string content (no surrounding quotes).
-- These are inner content nodes produced by most treesitter grammars.
local CONTENT_NODE_TYPES = {
  string_content = true,
  string_fragment = true,
}

-- Node types that represent full strings (may include quotes, prefixes,
-- or indicators that need stripping before content extraction).
local STRING_NODE_TYPES = {
  -- Generic / multi-language
  string = true,
  string_literal = true,
  raw_string = true,
  raw_string_literal = true,
  interpreted_string_literal = true,
  template_string = true,
  -- YAML
  string_scalar = true,
  plain_scalar = true,
  double_quote_scalar = true,
  single_quote_scalar = true,
  flow_scalar_plain = true,
  flow_scalar_double_quote = true,
  flow_scalar_single_quote = true,
}

--- Strip surrounding quotes and language-specific prefixes from a string.
--- Handles:
--- - Python prefixed strings: b"...", r"...", f"...", u"...", rb"...", br"..."
--- - Python triple-quoted variants: b\"""...\""", etc.
--- - Rust raw strings: r"...", r#"..."#, r##"..."##, br"...", br#"..."#
--- - Lua long strings: [[...]], [=[...]=], [==[...]==]
--- - Backtick strings (JS/Go template literals)
--- - Plain single/double quotes
--- @param text string
--- @return string
local function strip_quotes(text)
  -- Python strings with optional prefix + quotes.
  -- Valid prefixes (case-insensitive): b, r, u, f, rb, br, rf, fr, or none.
  -- Enumerate valid two-char prefixes, then one-char, then no prefix.
  -- This rejects invalid combinations like "ff", "bb", "rrbb", etc.
  local prefixes = { '[rR][bB]', '[bB][rR]', '[rR][fF]', '[fF][rR]', '[brufBRUF]', '' }
  local quotes = { '"""', "'''", '"', "'" }
  for _, prefix in ipairs(prefixes) do
    for _, q in ipairs(quotes) do
      local eq = vim.pesc(q)
      local inner = text:match('^' .. prefix .. eq .. '(.-)' .. eq .. '$')
      if inner then
        return inner
      end
    end
  end

  -- Rust raw strings: r"...", r#"..."#, r##"..."##, br"...", br#"..."#
  -- Uses Lua backreference %1 to match the same number of # on both sides.
  local _, rust_inner = text:match('^b?r(#*)"(.-)"%1$')
  if rust_inner then
    return rust_inner
  end

  -- Lua long strings: [[...]], [=[...]=], [==[...]==], etc.
  -- Uses Lua backreference %1 to match the same number of = on both sides.
  local _, lua_inner = text:match('^%[(=*)%[(.-)%]%1%]$')
  if lua_inner then
    return lua_inner
  end

  -- Backtick strings (JS/Go template literals)
  local inner = text:match('^`(.-)`$')
  if inner then
    return inner
  end

  return text
end

--- Find the string content at the cursor using treesitter.
--- Walks up the syntax tree (max 10 levels) from the cursor node to find
--- a recognized string node type, then extracts and returns its text content.
--- @param bufnr integer
--- @param row integer 0-indexed
--- @param col integer 0-indexed
--- @return string?
local function find_string_at_cursor(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then
    return nil
  end

  local current = node
  for _ = 1, 10 do
    if not current then
      break
    end

    local ntype = current:type()

    if CONTENT_NODE_TYPES[ntype] then
      return vim.treesitter.get_node_text(current, bufnr)
    end

    if STRING_NODE_TYPES[ntype] then
      return strip_quotes(vim.treesitter.get_node_text(current, bufnr))
    end

    current = current:parent()
  end

  return nil
end

--- Check if a string has valid base64 structure.
--- Rejects strings that are too short, have mixed standard/URL-safe
--- alphabets, invalid padding placement, or impossible encoded lengths.
--- @param str string Whitespace-stripped string
--- @return boolean
local function is_base64_like(str)
  if #str < MIN_ENCODE_LENGTH then
    return false
  end

  -- Only valid base64/base64url characters
  if not str:match('^[A-Za-z0-9+/=_-]+$') then
    return false
  end

  -- Reject mixed standard (+/) and URL-safe (-_) alphabets
  local has_standard = str:find('[+/]') ~= nil
  local has_urlsafe = str:find('[-_]') ~= nil
  if has_standard and has_urlsafe then
    return false
  end

  -- Padding '=' must only appear at the end
  if str:find('=[^=]') then
    return false
  end

  -- Validate padding length and content length
  local content = str:gsub('=+$', '')
  if #content == 0 then
    return false
  end

  local padding_len = #str - #content
  if padding_len > 2 then
    return false
  end

  -- Content length % 4 == 1 is never valid base64
  -- (no number of input bytes produces 4n+1 encoded chars)
  if #content % 4 == 1 then
    return false
  end

  return true
end

--- Heuristic UTF-8 byte-structure validation.
--- Checks that multi-byte sequences have correct start/continuation byte
--- patterns. This is a simplified validator that accepts overlong encodings
--- but catches broken continuation bytes, truncated sequences, and invalid
--- start bytes. Sufficient for filtering binary vs text content.
--- @param str string
--- @return boolean
local function is_valid_utf8(str)
  local i = 1
  while i <= #str do
    local b = str:byte(i)
    local len
    if b < 0x80 then
      len = 1
    elseif b >= 0xC0 and b < 0xE0 then
      len = 2
    elseif b >= 0xE0 and b < 0xF0 then
      len = 3
    elseif b >= 0xF0 and b < 0xF8 then
      len = 4
    else
      return false
    end
    for j = 1, len - 1 do
      if i + j > #str then
        return false
      end
      local cb = str:byte(i + j)
      if cb < 0x80 or cb >= 0xC0 then
        return false
      end
    end
    i = i + len
  end
  return true
end

--- Check if decoded content is printable text (not binary).
--- Requires valid (heuristic) UTF-8 and >= 90% printable characters.
--- @param str string
--- @return boolean
local function is_printable_text(str)
  if #str == 0 then
    return false
  end
  if str:find('\0') then
    return false
  end
  if not is_valid_utf8(str) then
    return false
  end
  local printable = 0
  for i = 1, #str do
    local b = str:byte(i)
    if (b >= 0x20 and b <= 0x7E) or b == 0x09 or b == 0x0A or b == 0x0D or b >= 0x80 then
      printable = printable + 1
    end
  end
  return (printable / #str) >= 0.9
end

--- Convert base64url to standard base64.
--- @param str string
--- @return string
local function base64url_to_base64(str)
  str = str:gsub('-', '+'):gsub('_', '/')
  local pad = #str % 4
  if pad > 0 then
    str = str .. string.rep('=', 4 - pad)
  end
  return str
end

--- Add padding to standard base64 if missing.
--- @param str string
--- @return string
local function ensure_padding(str)
  local pad = #str % 4
  if pad > 0 then
    str = str .. string.rep('=', 4 - pad)
  end
  return str
end

--- Try to decode a base64/base64url string.
--- @param str string Whitespace-stripped potential base64 content
--- @return string? decoded
--- @return string? encoding_name
local function try_decode(str)
  local is_url_safe = str:find('[-_]') ~= nil

  if is_url_safe then
    local normalized = base64url_to_base64(str)
    local ok, result = pcall(vim.base64.decode, normalized)
    if ok and is_printable_text(result) then
      return result, 'Base64URL'
    end
  else
    local padded = ensure_padding(str)
    local ok, result = pcall(vim.base64.decode, padded)
    if ok and is_printable_text(result) then
      return result, 'Base64'
    end
  end

  return nil, nil
end

-- Decode result cache to avoid duplicate work between enabled() and execute().
-- Keyed by (bufnr, position, changedtick).
--- @class Hover.provider.endec.Cache
--- @field bufnr integer
--- @field pos_row integer
--- @field pos_col integer
--- @field tick integer
--- @field decoded string?
--- @field encoding_name string?
local cache = {} --- @type Hover.provider.endec.Cache

--- Attempt to decode base64 content at the cursor position.
--- Results are cached by (bufnr, position, changedtick) so that
--- execute() reuses the decode result computed during enabled().
--- @param bufnr integer
--- @param pos [integer, integer] [1-indexed row, 0-indexed col]
--- @return string? decoded
--- @return string? encoding_name
local function decode_at_cursor(bufnr, pos)
  local tick = api.nvim_buf_get_changedtick(bufnr)

  -- Return cached result if buffer, position, and content haven't changed
  if cache.bufnr == bufnr
    and cache.tick == tick
    and cache.pos_row == pos[1]
    and cache.pos_col == pos[2]
  then
    return cache.decoded, cache.encoding_name
  end

  local decoded, encoding_name

  local text = find_string_at_cursor(bufnr, pos[1] - 1, pos[2])
  if text and not text:find('\n') and #text <= MAX_DECODE_LENGTH and is_base64_like(text) then
    decoded, encoding_name = try_decode(text)
  end

  cache = {
    bufnr = bufnr,
    pos_row = pos[1],
    pos_col = pos[2],
    tick = tick,
    decoded = decoded,
    encoding_name = encoding_name,
  }

  return decoded, encoding_name
end

--- @type Hover.Provider
return {
  name = 'Endec',
  priority = 200,

  --- @param bufnr integer
  --- @param opts? Hover.Options
  --- @return boolean
  enabled = function(bufnr, opts)
    local pos = opts and opts.pos or api.nvim_win_get_cursor(0)
    local decoded = decode_at_cursor(bufnr, pos)
    return decoded ~= nil
  end,

  --- @param params Hover.Provider.Params
  --- @param done fun(result?: false|Hover.Provider.Result)
  execute = function(params, done)
    local decoded, encoding_name = decode_at_cursor(params.bufnr, params.pos)

    if not decoded or not encoding_name then
      done()
      return
    end

    local decoded_lines = vim.split(decoded, '\n')

    local lines = {
      '**' .. encoding_name .. '** decoded:',
      '',
      '```',
    }
    vim.list_extend(lines, decoded_lines)
    table.insert(lines, '```')

    done({ lines = lines, filetype = 'markdown' })
  end,
}
