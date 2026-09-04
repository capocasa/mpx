## Configuration for mpx.
##
## No config file is created by default; mpx runs on a unix socket with
## logging off. When `~/.config/mpx/config` (or the platform equivalent)
## exists it is read once:
##
##   listen = 10.0.0.4:4534    # also serve TCP, base port (see below)
##   log = true                # append to $XDG_DATA_HOME/mpx/mpx-YYYY.log
##
## Lines are `key = value`. `#` starts a comment. Blank lines are ignored.
## Unknown keys are ignored, so the file stays forward-compatible.
##
## `listen` gives a base port, not a fixed one: every session daemon needs
## its own port, so the first session takes 4534, the next free port above
## that the second, and so on. Clients scan up from the base port and
## identify the right daemon by session name.

import std/[os, strutils, net]

type
  Config* = object
    listen*: string   # "host:port" to also listen on TCP, "" for socket only
    log*: bool

proc configPath*(): string =
  when defined(windows):
    getEnv("APPDATA", getHomeDir() / "AppData" / "Roaming") / "mpx" / "config"
  elif defined(macos):
    getHomeDir() / "Library" / "Application Support" / "mpx" / "config"
  else:
    getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "mpx" / "config"

proc parseConfig*(text: string): Config =
  for line in text.splitLines():
    let line = line.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let key = line[0 ..< eq].strip.toLowerAscii
    let value = line[eq + 1 ..^ 1].strip
    case key
    of "listen":
      result.listen = value
    of "log":
      result.log = value.toLowerAscii in ["1", "true", "yes", "on"]
    else:
      discard

proc loadConfig*(): Config =
  let path = configPath()
  if fileExists(path):
    try:
      result = parseConfig(readFile(path))
    except OSError:
      result = Config()

proc parseListen*(listen: string): tuple[ip: IpAddress, basePort: int] =
  ## "10.0.0.4:4534" -> (parsed ip, 4534). Raises ValueError on bad input.
  let colon = listen.rfind(':')
  if colon < 0:
    raise newException(ValueError, "listen must be host:port, got: " & listen)
  let host = listen[0 ..< colon]
  let portStr = listen[colon + 1 ..^ 1]
  let port = parseInt(portStr)
  if port < 1 or port > 65535:
    raise newException(ValueError, "listen port out of range: " & portStr)
  if host.len == 0:
    raise newException(ValueError, "listen host missing")
  # Accept hostnames too: resolve at call time, not parse time
  (parseIpAddress(host), port)
