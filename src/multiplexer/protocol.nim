import std/[posix, os]

type
  MsgKind* = enum
    mkInput = 0'u8    # client -> daemon: raw input bytes
    mkOutput = 1'u8   # daemon -> client: raw output bytes
    mkResize = 2'u8   # client -> daemon: width, height (2 bytes each, big endian)
    mkAttach = 3'u8   # client -> daemon: attach request (payload: session name)
    mkDetach = 4'u8   # client -> daemon: detach
    mkError = 5'u8    # daemon -> client: error message

const
  ProtocolVersion = 1'u8

proc sendMsg*(fd: SocketHandle, kind: MsgKind, payload: openArray[byte] = []) =
  var header = [ProtocolVersion, kind.byte, payload.len.byte]
  discard posix.write(fd.cint, addr header[0], 3)
  if payload.len > 0:
    discard posix.write(fd.cint, unsafeAddr payload[0], payload.len)

proc recvMsg*(fd: SocketHandle): tuple[kind: MsgKind, payload: seq[byte]] =
  var header: array[3, byte]
  let n = posix.read(fd.cint, addr header[0], 3)
  if n != 3:
    raise newException(IOError, "short read on message header")
  if header[0] != ProtocolVersion:
    raise newException(IOError, "protocol version mismatch")
  result.kind = header[1].MsgKind
  let plen = header[2].int
  if plen > 0:
    result.payload.setLen(plen)
    discard posix.read(fd.cint, addr result.payload[0], plen)

proc socketPath*(sessionName: string): string =
  let runtimeDir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp"))
  result = runtimeDir / "mpx"
  createDir(result)
  result = result / sessionName & ".sock"

proc removeSocket*(sessionName: string) =
  let path = socketPath(sessionName)
  try:
    removeFile(path)
  except OSError:
    discard  # Ignore if file doesn't exist or can't be removed