import std/[os, times, strutils, sets]
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

proc resolveSession*(name: string): string =
  ## Empty name defaults to the directory name, deconflicted with a counter:
  ## mpx, mpx0, mpx1, ...
  if name.len > 0:
    return name
  let base = defaultName()
  let dir = mpxDir()
  # Claim the name with a lock file so concurrent `mpx new` calls don't collide
  var i = -1
  while true:
    let candidate = if i < 0: base else: base & $i
    inc i
    if fileExists(socketPath(candidate)) or
       fileExists(socketPath(candidate).changeFileExt(".lock")):
      continue
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
    # A port file alone can be stale garbage; a completed TCP handshake
    # to it proves a daemon is listening.
    let port = daemonPort(sessionName)
    if port <= 0 or port > 65535:
      return false
    try:
      let fd = connectTcp(parseIpAddress("127.0.0.1"), port)
      discard closeSocket(fd)
      result = true
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

when defined(windows):
  import std/tables

  proc parentPidMap(): Table[int, int] =
    ## th32ProcessID -> th32ParentProcessID for every running process.
    result = initTable[int, int]()
    let snap = createToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == INVALID_HANDLE_VALUE:
      return
    var entry = PROCESSENTRY32W()
    entry.dwSize = DWORD(sizeof(PROCESSENTRY32W))
    if process32FirstW(snap, addr entry) != 0:
      while true:
        result[int(entry.th32ProcessID)] = int(entry.th32ParentProcessID)
        if process32NextW(snap, addr entry) == 0:
          break
    discard closeHandle(snap)

else:
  when defined(macosx) or defined(macos):
    type
      ProcBsdinfo = object
        pbi_flags: uint32
        pbi_status: uint32
        pbi_xstatus: uint32
        pbi_pid: uint32
        pbi_ppid: uint32
        pbi_uid: uint32
        pbi_gid: uint32
        pbi_ruid: uint32
        pbi_rgid: uint32
        pbi_svuid: uint32
        pbi_svgid: uint32
        pbi_rfu: uint32
        pbi_comm: array[17, cchar]
        pbi_name: array[32, cchar]
        pbi_nfiles: uint32
        pbi_pgid: uint32
        pbi_pjobid: uint32
        pbi_totaluser: uint64
        pbi_totalsystem: uint64
        pbi_pidversion: uint32
        pbi_pflags: uint32
        pbi_pflags2: uint32
        pbi_pflags3: uint32
        pbi_pflags4: uint32

    const PROC_PIDTBSDINFO = 3

    proc proc_pidinfo(pid: cint, flavor: cint, arg: uint64,
                      buffer: pointer, buffersize: cint): cint
      {.importc, header: "<libproc.h>".}

    proc parentPid(pid: int): int =
      if pid <= 0:
        return 0
      var info: ProcBsdinfo
      if proc_pidinfo(cint(pid), PROC_PIDTBSDINFO, 0'u64,
                      addr info, cint(sizeof(ProcBsdinfo))) <= 0:
        return 0
      int(info.pbi_ppid)
  else:
    proc parentPid(pid: int): int =
      if pid <= 0:
        return 0
      try:
        for line in readFile("/proc/" & $pid & "/status").splitLines():
          if line.startsWith("PPid:"):
            return parseInt(line.split(':', 1)[1].strip())
      except CatchableError:
        discard
      0

proc sessionForDaemonPid*(pid: int): string =
  ## Active session whose recorded daemon pid equals pid, or "".
  let dir = mpxDir()
  if not dirExists(dir):
    return ""
  for (_, f) in walkDir(dir):
    if not f.endsWith(EndpointExt):
      continue
    let name = f.extractFilename.changeFileExt("")
    if not isActive(name):
      continue
    if daemonPid(name) == pid:
      return name
  ""

proc currentSession*(): string =
  ## Session whose daemon is an ancestor of this process. Nearest ancestor
  ## wins (inner session when sessions are nested). "" when not inside one.
  when defined(windows):
    let parents = parentPidMap()
    var pid = parents.getOrDefault(int(getCurrentProcessId()), 0)
    var seen = initHashSet[int]()
    while pid > 0 and pid notin seen:
      seen.incl(pid)
      let name = sessionForDaemonPid(pid)
      if name.len > 0:
        return name
      pid = parents.getOrDefault(pid, 0)
    ""
  else:
    var pid = parentPid(int(getpid()))
    var seen = initHashSet[int]()
    while pid > 1 and pid notin seen:
      seen.incl(pid)
      let name = sessionForDaemonPid(pid)
      if name.len > 0:
        return name
      pid = parentPid(pid)
    ""

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
