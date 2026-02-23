; extends

; Conceal the backslash in escape sequences so \. renders as just .
; #offset! trims the capture to the backslash only, leaving the escaped char visible.
((backslash_escape) @conceal
  (#offset! @conceal 0 0 0 -1)
  (#set! conceal ""))
