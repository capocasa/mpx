## Where mpx keeps its sockets and locks.
##
## XDG_RUNTIME_DIR when set (systemd convention), else TMPDIR, else the
## platform default: /tmp everywhere except Termux/Android, where /tmp
## exists but is not writable by apps and the Termux prefix tmp is the
## right place.
##
## Termux detection is runtime, not compile-time: Termux's own Nim
## identifies as plain linux, and the termux-docker CI container exports
## $PREFIX but not $TERMUX_VERSION. A $PREFIX ending in
## com.termux/files/usr is true in both.

import std/[os, strutils]

proc isTermux*(): bool =
  when defined(android):
    result = true
  elif defined(windows) or defined(macosx):
    result = false
  else:
    let prefix = getEnv("PREFIX")
    result = prefix.len > 0 and prefix.endsWith("com.termux/files/usr")

proc runtimeDir*(): string =
  result = getEnv("XDG_RUNTIME_DIR")
  if result.len == 0:
    result = getEnv("TMPDIR")
  if result.len == 0:
    if isTermux():
      result = getEnv("PREFIX", "/data/data/com.termux/files/usr") / "tmp"
    else:
      result = "/tmp"

proc mpxDir*(): string =
  result = runtimeDir() / "mpx"
  createDir(result)