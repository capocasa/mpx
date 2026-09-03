import std/[posix, termios, selectors]
import mpxlib/[protocol, pty]

proc runClientAt*(path: string)

proc runClient*(sessionName: string) =
  runClientAt(socketPath(sessionName))

proc runClientAt*(path: string) =
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    raise newException(OSError, "socket failed")
  
  var saddr: Sockaddr_un
  saddr.sun_family = AF_UNIX.TSa_Family
  let pathCstr = path.cstring
  if pathCstr.len >= saddr.sun_path.len:
    raise newException(OSError, "socket path too long")
  copyMem(addr saddr.sun_path, pathCstr, pathCstr.len)
  
  if connect(fd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_un).SockLen) != 0:
    raise newException(OSError, "connect failed: " & path)

  # Save terminal state and set raw mode
  var oldTermios, rawTermios: Termios
  discard tcgetattr(0, addr oldTermios)
  rawTermios = oldTermios
  rawTermios.c_iflag = rawTermios.c_iflag and not (ICRNL or IXON)
  rawTermios.c_lflag = rawTermios.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  rawTermios.c_oflag = rawTermios.c_oflag and not OPOST
  rawTermios.c_cc[VMIN] = 1.char
  rawTermios.c_cc[VTIME] = 0.char
  discard tcsetattr(0, TCSADRAIN, addr rawTermios)

  # Send terminal size
  var win: Winsize
  discard ioctl(1, TIOCGWINSZ, addr win)
  var w = win.ws_col
  var h = win.ws_row
  if w == 0 or h == 0:
    w = 80
    h = 24
  sendMsg(fd, mkResize, [byte(w shr 8), byte(w and 0xff), byte(h shr 8), byte(h and 0xff)])

  var sel = newSelector[SocketHandle]()
  sel.registerHandle(fd, {Event.Read}, fd)
  
  # Try to register stdin; may fail if stdin is not selectable (e.g. /dev/null)
  var stdinRegistered = false
  try:
    sel.registerHandle(SocketHandle(0), {Event.Read}, SocketHandle(0))
    stdinRegistered = true
  except IOSelectorsException:
    discard

  var running = true
  while running:
    let events = sel.select(if stdinRegistered: -1 else: 100)
    for ev in events:
      if ev.fd == 0:
        # stdin -> daemon
        var buf: array[4096, byte]
        let n = posix.read(0, addr buf[0], buf.len)
        if n > 0:
          # Check for Ctrl+D (0x04) to detach
          if n == 1 and buf[0] == 0x04:
            sendMsg(fd, mkDetach)
            running = false
          else:
            sendMsg(fd, mkInput, buf[0..<n])
        else:
          running = false
      elif ev.fd == fd.cint:
        # daemon -> stdout
        try:
          let (kind, payload) = recvMsg(fd)
          case kind
          of mkOutput:
            discard posix.write(1, unsafeAddr payload[0], payload.len)
          of mkResize:
            # Terminal was resized by controlling client, we just ignore
            discard
          else:
            discard
        except IOError:
          running = false
    # If stdin not registered, poll it manually with non-blocking read
    if not stdinRegistered:
      var buf: array[4096, byte]
      let fl = fcntl(0, F_GETFL)
      discard fcntl(0, F_SETFL, fl or O_NONBLOCK)
      let n = posix.read(0, addr buf[0], buf.len)
      discard fcntl(0, F_SETFL, fl)
      if n > 0:
        sendMsg(fd, mkInput, buf[0..<n])

  # Restore terminal
  discard tcsetattr(0, TCSADRAIN, addr oldTermios)
  discard posix.close(fd)