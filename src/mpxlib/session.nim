import std/[os, posix]
import protocol

proc resolveSession*(name: string): string =
  ## Empty name picks the next free integer session id, starting at 1.
  if name.len > 0:
    return name
  let dir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp")) / "mpx"
  createDir(dir)
  # Claim the id with a lock file so concurrent `mpx new` calls don't collide
  var n = 1
  while true:
    if fileExists(dir / $n & ".sock") or fileExists(dir / $n & ".lock"):
      inc n
      continue
    let fd = posix.open((dir / $n & ".lock").cstring, O_CREAT or O_EXCL or O_WRONLY, 0o600)
    if fd < 0:
      inc n  # someone else claimed it between the check and the create
      continue
    discard posix.close(fd)
    break
  result = $n

proc requireSession*(name: string): string =
  ## Session name for attach/kill: error out if empty.
  if name.len == 0:
    raise newException(ValueError, "session name required")
  name

proc isActive*(sessionName: string): bool =
  ## True if a daemon is answering on the session socket.
  let path = socketPath(sessionName)
  if not fileExists(path):
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
