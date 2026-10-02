import std/[os, times, strutils]
import protocol, runtime

when defined(windows):
  from std/net import parseIpAddress
  import mpx/win
else:
  import std/posix

when defined(windows):
  const EndpointExt* = ".port"
else:
  const EndpointExt* = ".sock"

proc defaultName*(): string =
  ## Sessions started without a name are named after the current directory.
  ## Homedir collapses to `~`. The check is stat-based, not lexical: on
  ## macOS the same directory is reachable via /var and /private/var.
  let cwd = getCurrentDir()
  try:
    if sameFile(cwd, getHomeDir()):
      return "~"
  except OSError:
    discard  # no home to collapse into
  lastPathPart(cwd)

when defined(windows):
  proc daemonPort*(sessionName: string): int =
    ## Loopback TCP port recorded by the daemon in its .port file, or 0
    ## when absent or unparseable.
    try:
      parseInt(readFile(socketPath(sessionName)).strip)
    except CatchableError:
      0

proc isActive*(sessionName: string): bool =
  ## True if a daemon is answering on the session endpoint.
  when defined(windows):
    # A port file alone can be stale garbage, and a completed TCP
    # handshake only proves *a* daemon listens there: a dead session's
    # port can be re-claimed by a different session's daemon in the
    # base-port scan. Ask the daemon its name; only a matching answer
    # proves this session's daemon.
    let port = daemonPort(sessionName)
    if port <= 0 or port > 65535:
      return false
    try:
      let fd = connectTcp(parseIpAddress("127.0.0.1"), port)
      defer: discard closeSocket(fd)
      setRecvTimeoutMs(fd, 500)
      if not sendMsg(fd, mkIdent):
        return false
      let (kind, payload) = recvMsg(fd)
      result = kind == mkIdent and
        payload == sessionName.toOpenArrayByte(0, sessionName.len-1)
    except CatchableError:
      result = false
  else:
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

proc pathPresent*(p: string): bool =
  ## fileExists is false for sockets; lstat only says the path is there.
  ## A .port file is a regular file, so plain fileExists works.
  when defined(windows):
    fileExists(p)
  else:
    var st: Stat
    lstat(p.cstring, st) == 0

proc cleanSessionFiles*(sessionName: string) =
  for ext in [EndpointExt, ".lock", ".pid"]:
    let p = socketPath(sessionName).changeFileExt(ext)
    if pathPresent(p):
      try:
        removeFile(p)
      except OSError:
        discard

proc resolveSession*(name: string): string =
  ## Empty name defaults to the directory name, deconflicted with a counter:
  ## mpx, mpx0, mpx1, ...
  if name.len > 0:
    return name
  let base = defaultName()
  let dir = mpxDir()
  # Claim the name with a lock file so concurrent `mpx new` calls don't collide.
  # A lock whose session is neither live nor freshly claimed is a crashed
  # start's garbage; honoring it forever would march every future session
  # onto a counter suffix (the ~, ~0, ~1 trail). Reclaim it instead: the
  # 2s grace window exceeds any daemon's bind time, and the `new` client
  # removes its own claim after its 5s readiness wait, so an older lock
  # with no live session behind it can only be garbage.
  var i = -1
  while true:
    let candidate = if i < 0: base else: base & $i
    inc i
    let endpoint = socketPath(candidate)
    if fileExists(endpoint) or fileExists(endpoint.changeFileExt(".lock")):
      if isActive(candidate):
        continue
      var freshClaim = false
      try:
        let age = (getTime() -
          getLastModificationTime(endpoint.changeFileExt(".lock"))).inSeconds
        if age < 2:
          freshClaim = true
      except OSError:
        discard  # no lock to date: endpoint-only garbage, sweep it
      if freshClaim:
        continue  # someone's daemon may still be binding
      cleanSessionFiles(candidate)
    when defined(windows):
      # CREATE_NEW is the atomic exclusivity O_EXCL provides on posix
      let h = createFileW(newWideCString(
          socketPath(candidate).changeFileExt(".lock")), GENERIC_WRITE,
                          FILE_SHARE_READ or FILE_SHARE_WRITE, nil, CREATE_NEW,
                          FILE_ATTRIBUTE_NORMAL, 0)
      if h == INVALID_HANDLE_VALUE:
        if getLastError() == ERROR_FILE_EXISTS:
          continue  # someone else claimed it between the check and the create
        raise newException(OSError, "cannot create session lock in " & dir)
      discard closeHandle(h)
    else:
      let fd = posix.open(socketPath(candidate).changeFileExt(".lock").cstring,
                           O_CREAT or O_EXCL or O_WRONLY, 0o600)
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

proc oldestSession*(): string =
  ## The session for `mpx attach` with no name: the one whose daemon
  ## started first, by pid-file mtime. mtime has second resolution, so a
  ## tie is broken by the recorded pid (started earlier usually means
  ## lower pid). "" when no session answers.
  let dir = mpxDir()
  if not dirExists(dir):
    return ""
  var best = ""
  var bestSec: int64 = high(int64)
  var bestPid = high(int)
  for (_, f) in walkDir(dir):
    if not f.endsWith(EndpointExt):
      continue
    let name = f.extractFilename.changeFileExt("")
    if not isActive(name):
      continue
    let sec =
      try:
        getLastModificationTime(f.changeFileExt("pid")).toUnix
      except OSError:
        continue  # no pid file: not a session mpx started
    let pid = daemonPid(name)
    if sec < bestSec or (sec == bestSec and pid < bestPid):
      best = name
      bestSec = sec
      bestPid = pid
  best
