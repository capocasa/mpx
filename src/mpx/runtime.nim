## Where mpx keeps its sockets and locks.
##
## XDG_RUNTIME_DIR when set (systemd convention), else TMPDIR, else the
## platform default: /tmp everywhere except Termux/Android, where /tmp
## exists but is not writable by apps and the Termux prefix tmp is the
## right place. Termux is detected at runtime ($TERMUX_VERSION is set by
## the Termux app itself); the compiler's `android` define is not
## reliable here because Termux's Nim targets plain linux.

import std/os

proc runtimeDir*(): string =
  result = getEnv("XDG_RUNTIME_DIR")
  if result.len == 0:
    result = getEnv("TMPDIR")
  if result.len == 0:
    when defined(android):
      result = getEnv("PREFIX", "/data/data/com.termux/files/usr") / "tmp"
    elif not defined(windows):
      # Termux: /tmp exists but is not app-writable
      if getEnv("TERMUX_VERSION").len > 0:
        result = getEnv("PREFIX", "/data/data/com.termux/files/usr") / "tmp"
      else:
        result = "/tmp"
    else:
      result = getTempDir()

proc mpxDir*(): string =
  result = runtimeDir() / "mpx"
  createDir(result)