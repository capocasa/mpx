import std/[os, strutils, sequtils]
from std/net import parseIpAddress, IpAddress, IpAddressFamily
import runtime
when defined(windows):
  import mpx/win
else:
  import std/posix

type
  MsgKind* = enum
    mkInput = 0'u8    # client -> daemon: raw input bytes
    mkOutput = 1'u8   # daemon -> client: raw output bytes
    mkResize = 2'u8   # client -> daemon: width, height (2 bytes each, big endian)
    mkAttach = 3'u8   # client -> daemon: attach to session (payload: session name)
    mkDetach = 4'u8   # client -> daemon: detach
    mkError = 5'u8    # daemon -> client: error message
    mkAttached = 6'u8 # daemon -> client: attach accepted
    mkIdent = 7'u8    # both ways: "which session is this?" / "<name>".
                      # Lets a probe tell whether the listener it reached
                      # is the session its .port file named, or a younger
                      # daemon that claimed the port in the base-port scan.
    mkSuspend = 8'u8  # client -> daemon: stop the program (Ctrl-Z in a
                      # command session; no inner shell to take the stop)
    mkResume = 9'u8   # client -> daemon: continue the program (fg)

const
  # v2: the payload length is a 32-bit big-endian field. v1's single length
  # byte capped frames at 255 bytes, which a full-model attach snapshot
  # (scrollback + screen) overflows immediately.
  ProtocolVersion = 2'u8
  HeaderSize = 6

  # Attach snapshots (scrollback with attributes) are the largest real
  # frames: a few MB at 10000 lines. Anything past this is a desynced or
  # hostile peer, and reading it would pin the loop forever.
  MaxPayload = 0xFFFFFF

proc frameBytes*(kind: MsgKind, payload: openArray[byte]): seq[byte] =
  ## Serialized frame: version, kind, 32-bit big-endian length, payload.
  if payload.len > MaxPayload:
    raise newException(IOError, "payload too large: " & $payload.len)
  result = newSeq[byte](HeaderSize + payload.len)
  result[0] = ProtocolVersion
  result[1] = kind.byte
  let n = payload.len.uint32
  result[2] = byte(n shr 24)
  result[3] = byte(n shr 16)
  result[4] = byte(n shr 8)
  result[5] = byte(n)
  if payload.len > 0:
    copyMem(addr result[HeaderSize], unsafeAddr payload[0], payload.len)

proc wasInterrupted(): bool =
  ## Posix only: a signal can cut a send short. Winsock has no signal
  ## interruption, so there a failed send is plain failure.
  when defined(windows):
    false
  else:
    errno == EINTR

proc sockClose(fd: SocketHandle) =
  when defined(windows):
    discard closeSocket(fd)
  else:
    discard posix.close(fd)

proc sendMsg*(fd: SocketHandle, kind: MsgKind,
             payload: openArray[byte] = []): bool =
  ## Write one framed message, one send call per frame: a frame split
  ## across two writes can be interleaved with another writer on the
  ## same fd, and the peer would read the length prefix out of sync.
  ## Short sends (interrupted after partial transfer) are retried.
  ## Returns false on a hard error (peer gone).
  if payload.len > MaxPayload:
    return false
  var buf = frameBytes(kind, payload)
  var sent = 0
  while sent < buf.len:
    let w = send(fd, addr buf[sent], cint(buf.len - sent), 0)
    if w > 0:
      inc(sent, w)
    elif w == -1 and wasInterrupted():
      continue
    else:
      return false
  result = true

proc readFull*(fd: SocketHandle, buf: pointer, n: int): bool =
  ## Read exactly n bytes. False on EOF or error before n bytes arrived.
  var got = 0
  while got < n:
    let r = recv(fd, cast[pointer](cast[int](buf) + got), cint(n - got), 0)
    if r <= 0:
      return false
    inc(got, r)
  true

proc takeFrame*(buf: var seq[byte], kind: var MsgKind,
                payload: var seq[byte]): bool =
  ## Pop one complete frame off the front of buf. False when buf holds
  ## less than a full frame. Raises IOError on a malformed header: the
  ## buffer is desynced and the peer must go.
  if buf.len < HeaderSize:
    return false
  if buf[0] != ProtocolVersion:
    raise newException(IOError, "protocol version mismatch")
  let plen = (buf[2].int shl 24) or (buf[3].int shl 16) or
             (buf[4].int shl 8) or buf[5].int
  if plen > MaxPayload:
    raise newException(IOError, "frame too large: " & $plen & " bytes")
  if buf.len < HeaderSize + plen:
    return false
  kind = buf[1].MsgKind
  payload = buf[HeaderSize ..< HeaderSize + plen]
  buf.delete(0 ..< HeaderSize + plen)
  result = true

when defined(windows):
  proc setRecvTimeoutMs*(fd: SocketHandle, ms: int) =
    ## Cap a blocking recv, so a probe cannot hang ls forever on a
    ## daemon that took the connection but never answers.
    var v: DWORD = ms.DWORD
    discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr v,
                       sizeof(v).SockLen)

else:
  proc setRecvTimeoutMs*(fd: SocketHandle, ms: int) =
    ## Same cap on posix: ms of 0 clears it (blocking again). Used for
    ## one-shot handshakes on an otherwise blocking socket.
    var tv: Timeval
    tv.tv_sec = Time(ms div 1000)
    tv.tv_usec = Suseconds((ms mod 1000) * 1000)
    discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv,
                       sizeof(tv).SockLen)

proc setNonBlocking*(fd: SocketHandle) =
  when defined(windows):
    var mode: culong = 1
    discard ioctlsocket(fd, FIONBIO, addr mode)
  else:
    let fl = fcntl(fd.cint, F_GETFL)
    discard fcntl(fd.cint, F_SETFL, fl or O_NONBLOCK)

proc recvMsg*(fd: SocketHandle): tuple[kind: MsgKind, payload: seq[byte]] =
  var header: array[HeaderSize, byte]
  if not readFull(fd, addr header[0], HeaderSize):
    raise newException(IOError, "short read on message header")
  if header[0] != ProtocolVersion:
    raise newException(IOError, "protocol version mismatch")
  result.kind = header[1].MsgKind
  let plen = (header[2].int shl 24) or (header[3].int shl 16) or
             (header[4].int shl 8) or header[5].int
  if plen > MaxPayload:
    raise newException(IOError, "frame too large: " & $plen & " bytes")
  if plen > 0:
    result.payload.setLen(plen)
    if not readFull(fd, addr result.payload[0], plen):
      raise newException(IOError, "short read on message payload")

proc socketPath*(sessionName: string): string =
  ## The daemon's endpoint file: the unix socket path on posix, the .port
  ## file carrying the loopback TCP port on Windows.
  ##
  ## sockaddr_un.sun_path is only 92 bytes on macOS and TMPDIR alone eats
  ## ~50 of them, so a name whose plain path would not fit folds to a
  ## readable prefix plus a deterministic FNV-1a digest of the full name.
  ## Every lookup goes through this proc, and a folded name is always
  ## short enough to resolve to itself, so `ls` output still attaches.
  when defined(windows):
    mpxDir() / sessionName & ".port"
  else:
    const sunPathLen = block:
      var sa: Sockaddr_un
      sa.sun_path.len
    proc fnv1a(s: string): uint32 =
      var h = 2166136261'u32
      for c in s:
        h = (h xor c.uint32) * 16777619'u32
      h
    let dir = mpxDir()
    let plain = dir / sessionName & ".sock"
    if plain.len < sunPathLen:
      return plain
    # name budget = sunPathLen - NUL - dir - sep - ".sock"; digest eats 9
    let prefixLen = sunPathLen - 1 - dir.len - 1 - 5 - 9
    if prefixLen < 1:
      return plain  # not even a digest fits: let bind() name the problem
    let prefix = sessionName[0 ..< min(sessionName.len, prefixLen)]
    dir / prefix & "-" & fnv1a(sessionName).toHex & ".sock"

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

proc daemonPid*(sessionName: string): int =
  ## Pid recorded by the daemon next to its socket, or 0 when absent.
  try:
    parseInt(readFile(socketPath(sessionName).changeFileExt("pid")).strip)
  except CatchableError:
    0

when not defined(windows):
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
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  var saddr: Sockaddr_in
  when defined(windows):
    saddr.sin_family = AF_INET
  else:
    saddr.sin_family = AF_INET.TSa_Family
  saddr.sin_port = htons(uint16(port))
  saddr.sin_addr.s_addr = cast[uint32](ip.address_v4)
  if connect(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_in).SockLen) != 0:
    sockClose(fd)
    raise newException(OSError, "connect failed: " & $ip & ":" & $port)
  fd

proc listenTcp*(ip: IpAddress, port: int): SocketHandle =
  ## Bind and listen on ip:port. Raises OSError if the port is taken.
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  # Windows SO_REUSEADDR does not mean posix's "rebind after close": it
  # silently lets a second daemon bind the same port, and connects then
  # land on the wrong session's listener. SO_EXCLUSIVEADDRUSE is the
  # actual "this port is mine" there.
  var one: cint = 1
  when defined(windows):
    discard setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, addr one, sizeof(one).SockLen)
  else:
    discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one, sizeof(one).SockLen)
  var saddr: Sockaddr_in
  when defined(windows):
    saddr.sin_family = AF_INET
  else:
    saddr.sin_family = AF_INET.TSa_Family
  saddr.sin_port = htons(uint16(port))
  saddr.sin_addr.s_addr = cast[uint32](ip.address_v4)
  if bindSocket(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_in).SockLen) != 0:
    sockClose(fd)
    raise newException(OSError, "cannot bind " & $ip & ":" & $port)
  if listen(fd, 5) != 0:
    sockClose(fd)
    raise newException(OSError, "listen failed")
  fd
