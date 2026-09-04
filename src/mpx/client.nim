import std/[posix, termios, selectors]
import mpx/[protocol, config, pty]

proc runClient*(sessionName: string) =
  let cfg = loadConfig()
  let fd =
    try:
      connectUnix(socketPath(sessionName))
    except OSError:
      # No local socket. If TCP is configured, scan for the session there
      # (wireguard, port forward, or same host over 127.0.0.1).
      if cfg.listen.len == 0:
        raise
      var found = SocketHandle(-1)
      let (ip, basePort) = parseListen(cfg.listen)
      for p in basePort ..< basePort + 64:
        try:
          let candidate = connectTcp(ip, p)
          sendMsg(candidate, mkAttach, sessionName.toOpenArrayByte(0, sessionName.len-1))
          let (kind, payload) = recvMsg(candidate)
          if kind == mkAttached:
            found = candidate
            break
          # Wrong session or error: keep scanning
          discard posix.close(candidate)
        except OSError, IOError, ValueError:
          continue  # nothing on this port, keep scanning
      if found == SocketHandle(-1):
        raise newException(OSError, "connect failed: session not found on socket or tcp")
      found

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
          # Ctrl+\ (0x1c) detaches; Ctrl+D passes through so the
          # contained program sees EOF and can exit
          if n == 1 and buf[0] == 0x1c:
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
            # Another client resized; we just ignore
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
