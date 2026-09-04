import std/[posix, os]
from std/net import parseIpAddress, IpAddress, IpAddressFamily

type
  MsgKind* = enum
    mkInput = 0'u8    # client -> daemon: raw input bytes
    mkOutput = 1'u8   # daemon -> client: raw output bytes
    mkResize = 2'u8   # client -> daemon: width, height (2 bytes each, big endian)
    mkAttach = 3'u8   # client -> daemon: attach to session (payload: session name)
    mkDetach = 4'u8   # client -> daemon: detach
    mkError = 5'u8    # daemon -> client: error message
    mkAttached = 6'u8 # daemon -> client: attach accepted

const
  ProtocolVersion = 1'u8

proc sendMsg*(fd: SocketHandle, kind: MsgKind, payload: openArray[byte] = []) =
  var header = [ProtocolVersion, kind.byte, payload.len.byte]
  discard posix.write(fd.cint, addr header[0], 3)
  if payload.len > 0:
    discard posix.write(fd.cint, unsafeAddr payload[0], payload.len)

proc readFull*(fd: SocketHandle, buf: pointer, n: int): bool =
  ## Read exactly n bytes. False on EOF or error before n bytes arrived.
  var got = 0
  while got < n:
    let r = posix.read(fd.cint, cast[pointer](cast[int](buf) + got), n - got)
    if r <= 0:
      return false
    inc(got, r)
  true

proc recvMsg*(fd: SocketHandle): tuple[kind: MsgKind, payload: seq[byte]] =
  var header: array[3, byte]
  if not readFull(fd, addr header[0], 3):
    raise newException(IOError, "short read on message header")
  if header[0] != ProtocolVersion:
    raise newException(IOError, "protocol version mismatch")
  result.kind = header[1].MsgKind
  let plen = header[2].int
  if plen > 0:
    result.payload.setLen(plen)
    if not readFull(fd, addr result.payload[0], plen):
      raise newException(IOError, "short read on message payload")

proc socketPath*(sessionName: string): string =
  let runtimeDir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp"))
  result = runtimeDir / "mpx"
  createDir(result)
  result = result / sessionName & ".sock"

proc removeSocket*(sessionName: string) =
  ## Remove a stale socket. Never removes the session lock file: the daemon
  ## calls this on startup, right after the parent claimed the id with it.
  let path = socketPath(sessionName)
  try:
    removeFile(path)
  except OSError:
    discard  # Ignore if file doesn't exist or can't be removed

proc removeLock*(sessionName: string) =
  try:
    removeFile(socketPath(sessionName).changeFileExt("lock"))
  except OSError:
    discard

proc connectUnix*(path: string): SocketHandle =
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  var saddr: Sockaddr_un
  saddr.sun_family = AF_UNIX.TSa_Family
  let pathCstr = path.cstring
  if pathCstr.len >= saddr.sun_path.len:
    discard posix.close(fd)
    raise newException(OSError, "socket path too long")
  copyMem(addr saddr.sun_path, pathCstr, pathCstr.len)
  if connect(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_un).SockLen) != 0:
    discard posix.close(fd)
    raise newException(OSError, "connect failed: " & path)
  fd

proc connectTcp*(ip: IpAddress, port: int): SocketHandle =
  let fd = posix.socket(AF_INET, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  var saddr: Sockaddr_in
  saddr.sin_family = AF_INET.TSa_Family
  saddr.sin_port = htons(uint16(port))
  saddr.sin_addr.s_addr = cast[uint32](ip.address_v4)
  if connect(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_in).SockLen) != 0:
    discard posix.close(fd)
    raise newException(OSError, "connect failed: " & $ip & ":" & $port)
  fd

proc listenTcp*(ip: IpAddress, port: int): SocketHandle =
  ## Bind and listen on ip:port. Raises OSError if the port is taken.
  let fd = posix.socket(AF_INET, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  var one: cint = 1
  discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one, sizeof(one).SockLen)
  var saddr: Sockaddr_in
  saddr.sin_family = AF_INET.TSa_Family
  saddr.sin_port = htons(uint16(port))
  saddr.sin_addr.s_addr = cast[uint32](ip.address_v4)
  if bindSocket(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_in).SockLen) != 0:
    discard posix.close(fd)
    raise newException(OSError, "cannot bind " & $ip & ":" & $port)
  if listen(fd, 5) != 0:
    discard posix.close(fd)
    raise newException(OSError, "listen failed")
  fd
