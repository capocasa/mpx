import std/[strutils]
import ttty/grid

proc renderGrid*(grid: Grid, width, height: int): string =
  ## Render grid contents as ANSI escape sequences for attaching clients.
  ## Clears screen, moves cursor home, then writes rows with attributes.
  result = "\x1b[2J\x1b[H"  # clear screen, home cursor
  
  for r in 0..<min(height, grid.rows.len):
    if r > 0:
      result.add "\r\n"
    var lastFg = colDefault
    var lastBg = colDefault
    var lastAttrs = SgrAttr(0)
    var col = 0
    for cell in grid.rows[r]:
      if col >= width: break
      # Emit SGR if attributes changed
      if cell.fgColor != lastFg or cell.bgColor != lastBg or cell.attrs.uint16 != lastAttrs.uint16:
        var params: seq[string] = @["0"]  # reset
        # Foreground
        case cell.fgColor
        of colDefault: discard
        of colBlack: params.add "30"
        of colRed: params.add "31"
        of colGreen: params.add "32"
        of colYellow: params.add "33"
        of colBlue: params.add "34"
        of colMagenta: params.add "35"
        of colCyan: params.add "36"
        of colWhite: params.add "37"
        of colBrightBlack: params.add "90"
        of colBrightRed: params.add "91"
        of colBrightGreen: params.add "92"
        of colBrightYellow: params.add "93"
        of colBrightBlue: params.add "94"
        of colBrightMagenta: params.add "95"
        of colBrightCyan: params.add "96"
        of colBrightWhite: params.add "97"
        of col256: params.add "38;5;" & $cell.fgColorIdx
        of colRgb: discard  # not supported in simple renderer
        # Background
        case cell.bgColor
        of colDefault: discard
        of colBlack: params.add "40"
        of colRed: params.add "41"
        of colGreen: params.add "42"
        of colYellow: params.add "43"
        of colBlue: params.add "44"
        of colMagenta: params.add "45"
        of colCyan: params.add "46"
        of colWhite: params.add "47"
        of colBrightBlack: params.add "100"
        of colBrightRed: params.add "101"
        of colBrightGreen: params.add "102"
        of colBrightYellow: params.add "103"
        of colBrightBlue: params.add "104"
        of colBrightMagenta: params.add "105"
        of colBrightCyan: params.add "106"
        of colBrightWhite: params.add "107"
        of col256: params.add "48;5;" & $cell.bgColorIdx
        of colRgb: discard
        # Attributes
        if cell.attrs.hasAttr(saBold): params.add "1"
        if cell.attrs.hasAttr(saDim): params.add "2"
        if cell.attrs.hasAttr(saItalic): params.add "3"
        if cell.attrs.hasAttr(saUnderline): params.add "4"
        if cell.attrs.hasAttr(saBlink): params.add "5"
        if cell.attrs.hasAttr(saReverse): params.add "7"
        if cell.attrs.hasAttr(saStrikethrough): params.add "9"
        result.add "\x1b[" & params.join(";") & "m"
        lastFg = cell.fgColor
        lastBg = cell.bgColor
        lastAttrs = cell.attrs
      if cell.text.len > 0:
        result.add cell.text
      else:
        result.add " "
      inc col
  # Reset attributes at end
  result.add "\x1b[0m"