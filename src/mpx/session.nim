import std/[os, posix]
import protocol

proc defaultName*(): string =
  ## Sessions started without a name are named after the current directory.
  ## Homedir collapses to `~`.
  let cwd = normalizedPath(getCurrentDir())
  if cwd == normalizedPath(getHomeDir()):
    "~"
  else:
    lastPathPart(cwd)

proc resolveSession*(name: string): string =
  ## Empty name defaults to the directory name, deconflicted with a counter:
  ## mpx, mpx0, mpx1, ...
  if name.len > 0:
    return name
  let base = defaultName()
  let dir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp")) / "mpx"
  createDir(dir)
  # Claim the name with a lock file so concurrent `mpx new` calls don't collide
  var i = -1
  while true:
    let candidate = if i < 0: base else: base & $i
    inc i
    if fileExists(dir / candidate & ".sock") or fileExists(dir / candidate & ".lock"):
      continue
    let fd = posix.open((dir / candidate & ".lock").cstring, O_CREAT or O_EXCL or O_WRONLY, 0o600)
    if fd < 0:
      if errno == EEXIST:
        continue  # someone else claimed it between the check and the create
      raise newException(OSError, "cannot create session lock in " & dir)
    discard posix.close(fd)
    result = candidate
    break

proc requireSession*(name: string): string =
  ## Session name for attach/kill: error out if empty.
  if name.len == 0:
    raise newException(ValueError, "session name required")
  name

proc isActive*(sessionName: string): bool =
  ## True if a daemon is answering on the session socket.
  let path = socketPath(sessionName)
  var st: Stat
  if lstat(path.cstring, st) != 0 or not S_ISSOCK(st.st_mode):
    return false
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    return false
  var saddr: Sockaddr_un
  saddr.sun_family = AF_UNIX.TSa_Family
  let pathCstr = path.cstring
  if pathCstr.len >= saddr.sun_path.len:
    discard posix.close(fd)
    return false
  copyMem(addr saddr.sun_path, pathCstr, pathCstr.len)
  result = connect(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_un).SockLen) == 0
  discard posix.close(fd)
