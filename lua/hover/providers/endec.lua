--- Hover provider for decoding Base64 and Base64URL strings.
--- Uses treesitter to detect string nodes under the cursor,
--- then attempts to decode the content as Base64 or Base64URL.
--- Requires Neovim >= 0.10 (for vim.base64).

-- Node types that contain raw string content (no surrounding quotes)
local CONTENT_NODE_TYPES = {
  string_content = true,
  string_fragment = true,
}

-- Node types that represent full strings (may include quotes or indicators)
local STRING_NODE_TYPES = {
  string = true,
  string_literal = true,
  raw_string = true,
  raw_string_literal = true,
  interpreted_string_literal = true,
  template_string = true,
  -- YAML
  string_scalar = true,
  double_quote_scalar = true,
  single_quote_scalar = true,
  block_scalar = true,
}

--- Strip surrounding quotes from a string.
--- @param text string
--- @return string
local function strip_quotes(text)
  -- Triple quotes (Python)
  if #text >= 6 then
    if text:sub(1, 3) == '"""' and text:sub(-3) == '"""' then
      return text:sub(4, -4)
    end
    if text:sub(1, 3) == "'''" and text:sub(-3) == "'''" then
      return text:sub(4, -4)
    end
  end
  -- Lua long strings
  if #text >= 4 and text:sub(1, 2) == '[[' and text:sub(-2) == ']]' then
    return text:sub(3, -3)
  end
  -- Single character quotes
  if #text >= 2 then
    local first, last = text:sub(1, 1), text:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") or (first == '`' and last == '`') then
      return text:sub(2, -2)
    end
  end
  return text
end

--- Find the string content at the cursor using treesitter.
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
  for _ = 1, 5 do
    if not current then
      break
    end

    local ntype = current:type()

    if CONTENT_NODE_TYPES[ntype] then
      return vim.treesitter.get_node_text(current, bufnr)
    end

    if STRING_NODE_TYPES[ntype] then
      local text = vim.treesitter.get_node_text(current, bufnr)
      if ntype == 'block_scalar' then
        -- Strip YAML block scalar indicator (|, >, |-, >-, |+, >+)
        text = text:gsub('^[|>][+-]?%d*[ \t]*\n', '')
        -- Strip common leading indentation
        local indent = text:match('^(%s+)')
        if indent then
          text = text:gsub('\n' .. indent, '\n'):gsub('^' .. indent, '')
        end
      else
        text = strip_quotes(text)
      end
      return text
    end

    current = current:parent()
  end

  return nil
end

--- Check if a string could be base64 encoded.
--- @param str string Whitespace-stripped string
--- @return boolean
local function is_base64_like(str)
  if #str < 4 then
    return false
  end
  -- Allow standard base64 chars and base64url chars
  return str:match('^[A-Za-z0-9+/=_-]+$') ~= nil
end

--- Validate that a string is valid UTF-8.
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

--- Attempt to decode base64 content at the cursor position.
--- @param bufnr integer
--- @param pos [integer, integer] [1-indexed row, 0-indexed col]
--- @return string? decoded
--- @return string? encoding_name
local function decode_at_cursor(bufnr, pos)
  local text = find_string_at_cursor(bufnr, pos[1] - 1, pos[2])
  if not text then
    return nil, nil
  end

  local stripped = text:gsub('%s+', '')
  if not is_base64_like(stripped) then
    return nil, nil
  end

  return try_decode(stripped)
end

--- @type Hover.Provider
return {
  name = 'Endec',
  priority = 200,

  --- @param bufnr integer
  --- @return boolean
  enabled = function(bufnr)
    local pos = vim.api.nvim_win_get_cursor(0)
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
