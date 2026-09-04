## Logging for mpx.
##
## Off by default. Enable with MPX_LOG=1: appends to
## `$XDG_DATA_HOME/mpx/mpx-YYYY.log` (or `~/.local/share/mpx/...`).

import std/[os, times]

type
  Logger* = ref object
    file: File    # nil when disabled
    path*: string

proc logFilePath*(): string =
  let base = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
  base / "mpx" / "mpx-" & now().format("yyyy") & ".log"

proc initLogger*(): Logger =
  result = Logger()
  if getEnv("MPX_LOG") != "1":
    return
  let path = logFilePath()
  try:
    createDir(path.parentDir)
    result.file = open(path, fmAppend)
    result.path = path
  except CatchableError:
    result.file = nil

proc close*(l: Logger) =
  if l == nil or l.file == nil: return
  try: l.file.close()
  except CatchableError: discard
  l.file = nil

proc info*(l: Logger, msg: string) =
  if l == nil or l.file == nil: return
  try:
    l.file.writeLine now().format("yyyy-MM-dd'T'HH:mm:ss") & " " & msg
    l.file.flushFile()
  except CatchableError:
    discard
