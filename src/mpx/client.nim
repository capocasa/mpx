import mpx/[protocol, config]
when defined(windows):
  import std/[os, atomics]
  from std/net import parseIpAddress
  import mpx/win
  import mpx/session
else:
  import std/[posix, termios, selectors]
  import mpx/pty  # Winsize

const CtrlG = 0x07.byte  # detach key: BEL, layout-independent, unbound
                          # in practice (readline abort, dvtm mod)
const CtrlZ = 0x1a.byte  # suspend key: the tty's SUSP byte, handled here in
                          # command sessions where no inner shell can take it

when not defined(windows):

  # Not exported by Nim's posix: Linux, macOS, and the BSDs all use 28.
  const SIGWINCH = cint(28)

  # Self-pipe for SIGWINCH: the handler only pokes a byte (write to a pipe
  # is async-signal-safe); the resize frame itself is sent from the main
  # loop. Writing the socket from the handler interleaved a frame between
  # another frame's length prefix and payload, desyncing the daemon's
  # stream parse and freezing the session.
  var winchPipe: array[2, cint] = [cint(-1), cint(-1)]

  proc onWinch(sig: cint) {.noconv.} =
    var b: byte = 1
    discard posix.write(winchPipe[1], addr b, 1)

  proc sendResize(fd: SocketHandle) =
    var ws: Winsize
    discard ioctl(1, TIOCGWINSZ, addr ws)
    if ws.ws_col > 0 and ws.ws_row > 0:
      discard sendMsg(fd, mkResize,
        [byte(ws.ws_col shr 8), byte(ws.ws_col and 0xff),
         byte(ws.ws_row shr 8), byte(ws.ws_row and 0xff)])

  proc runClient*(sessionName: string, cfg: Config) =
    discard signal(SIGPIPE, SIG_IGN)  # a closed peer is an error, not death
    var directSession = false  # the session runs a bare command: Ctrl-Z is
                               # ours, not the program's
    let fd =
      try:
        let ufd = connectUnix(socketPath(sessionName))
        # Unix clients are trusted on arrival, but they still introduce
        # themselves: the reply's payload says whether the session runs a
        # bare command, which decides who owns Ctrl-Z. A daemon from
        # before suspend support never answers mkAttach; the timeout
        # falls back to plain byte forwarding, the only thing it knows.
        discard sendMsg(ufd, mkAttach,
          sessionName.toOpenArrayByte(0, sessionName.len-1))
        setRecvTimeoutMs(ufd, 1000)
        var refused = false
        try:
          let (kind, payload) = recvMsg(ufd)
          if kind == mkAttached:
            directSession = payload.len > 0 and payload[0] == 1
          else:
            refused = true
        except IOError:
          discard  # legacy daemon: no handshake, no suspend support
        setRecvTimeoutMs(ufd, 0)
        if refused:
          discard posix.close(ufd)
          raise newException(IOError, "attach refused: " & sessionName)
        ufd
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
            discard sendMsg(candidate, mkAttach, sessionName.toOpenArrayByte(0, sessionName.len-1))
            setRecvTimeoutMs(candidate, 1000)
            let (kind, payload) = recvMsg(candidate)
            if kind == mkAttached:
              found = candidate
              directSession = payload.len > 0 and payload[0] == 1
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

    # Winch pipe and handler before raw mode: nothing between the raw
    # tcsetattr and the try below may raise (pipe failure, resize send)
    # or that raise escapes without the restore the finally owns, and the
    # tty stays raw. Registered this early, both are torn down by the
    # finally on every exit path.
    if pipe(winchPipe) != 0:
      raise newException(OSError, "pipe failed")
    # Both ends non-blocking: the handler must never block on a full pipe,
    # and the drain loop must not block on an emptied one.
    for i in {0, 1}:
      let pfl = fcntl(winchPipe[i], F_GETFL)
      discard fcntl(winchPipe[i], F_SETFL, pfl or O_NONBLOCK)
    let oldWinch = signal(SIGWINCH, onWinch)

    var sel = newSelector[SocketHandle]()
    sel.registerHandle(fd, {Event.Read}, fd)
    sel.registerHandle(winchPipe[0].SocketHandle, {Event.Read}, winchPipe[0].SocketHandle)

    # Try to register stdin; may fail if stdin is not selectable (e.g. /dev/null)
    var stdinRegistered = false
    try:
      sel.registerHandle(SocketHandle(0), {Event.Read}, SocketHandle(0))
      stdinRegistered = true
    except IOSelectorsException:
      discard

    # A scripted client (stdin a pipe) never self-suspends: stopping mid-
    # script hangs the script. Its Ctrl-Z bytes ride to the program.
    let ttyIn = isatty(0.cint) == 1

    discard tcsetattr(0, TCSADRAIN, addr rawTermios)
    try:
      # Our terminal size is the session's size: claim it, and follow the
      # local window with SIGWINCH for the life of the attach (the desk
      # window resizing re-sizes the shared pty; a smaller co-attached
      # viewer -- the phone -- deliberately does not).
      var win: Winsize
      discard ioctl(1, TIOCGWINSZ, addr win)
      var w = win.ws_col
      var h = win.ws_row
      if w == 0 or h == 0:
        w = 80
        h = 24
      discard sendMsg(fd, mkResize, [byte(w shr 8), byte(w and 0xff), byte(h shr 8), byte(h and 0xff)])

      var running = true
      var detached = false   # Ctrl-G: the one exit that is not news
      var stdinEof = false   # scripted attach: input done, not an error
      while running:
        let events = sel.select(if stdinRegistered: -1 else: 100)
        for ev in events:
          if ev.fd == 0:
            # stdin -> daemon, through the detach keys
            var buf: array[4096, byte]
            let n = posix.read(0, addr buf[0], buf.len)
            if n > 0:
              # Ctrl-G (BEL) detaches; everything else reaches the program,
              # including Ctrl-D so shells and REPLs see EOF. Both act only
              # on a lone keypress: the same byte inside pasted text must
              # ride through, not kick the client out of the session or stop
              # it. One key, no prefix state, present on every keyboard
              # layout; readline binds Ctrl-G to an abort nobody presses on
              # purpose (dvtm uses it as its mod key).
              if n == 1 and buf[0] == CtrlG:
                discard sendMsg(fd, mkDetach)
                detached = true
                running = false
              elif n == 1 and buf[0] == CtrlZ and directSession and ttyIn:
                # Ctrl-Z in a command session: no shell inside the session
                # can take the stop, so this client does what the terminal
                # driver does for a foreground job -- stop the program, stop
                # itself. The shell that launched mpx wakes on our stop with
                # its prompt back, as in any terminal, and its fg resumes
                # both: back to raw mode here, SIGCONT for the program.
                discard sendMsg(fd, mkSuspend)
                discard tcsetattr(0, TCSADRAIN, addr oldTermios)
                let oldTstp = signal(SIGTSTP, SIG_DFL)
                discard kill(getpid(), SIGTSTP)
                discard signal(SIGTSTP, oldTstp)
                discard tcsetattr(0, TCSADRAIN, addr rawTermios)
                discard sendMsg(fd, mkResume)
              else:
                discard sendMsg(fd, mkInput, buf[0..<n])
            else:
              stdinEof = true
              running = false
          elif ev.fd == winchPipe[0]:
            # SIGWINCH arrived: drain the poke and send the resize from here
            var poke: array[64, byte]
            while posix.read(winchPipe[0], addr poke[0], poke.len) > 0:
              discard
            sendResize(fd)
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
            discard sendMsg(fd, mkInput, buf[0..<n])
          elif n == 0:
            # EOF: unselectable stdin still ends the session when it closes.
            # An empty nonblocking read reports -1 EAGAIN, never 0.
            stdinEof = true
            running = false

      # A session that vanished under us (daemon exit, mpx kill) is an
      # error, not a silent success: the user asked for a session, and it
      # is gone. Detach and stdin EOF are the only quiet exits.
      if not detached and not stdinEof:
        raise newException(OSError, "session ended: " & sessionName)
    finally:
      # Every exit path -- detach, stdin EOF, and the raise above alike --
      # hands the tty back cooked. The raise used to skip this block,
      # leaving the terminal in raw mode (no echo) until `reset`.
      discard signal(SIGWINCH, oldWinch)
      if winchPipe[0] != -1:
        discard posix.close(winchPipe[0])
        discard posix.close(winchPipe[1])
        winchPipe = [cint(-1), cint(-1)]
      discard tcsetattr(0, TCSADRAIN, addr oldTermios)
      discard posix.close(fd)

else:

  const StdinBufCap = 4096

  type
    ResizeWatch = object
      # Shared with the poller thread: the size stash is the last sample
      # the loop has not consumed yet, the event says a new one landed.
      hOut: Handle
      ev: Handle
      w, h: Atomic[int]
      stop: Atomic[bool]

    Spin = object
      held: Atomic[bool]

    StdinWatch = object
      # stdin arrives on a thread of its own: a pipe or console input
      # handle cannot share WaitForMultipleObjects with events (a pipe
      # makes the wait return immediately forever), so the reader thread
      # blocks in readFile and pokes an event instead. Raw CreateThread,
      # so no allocation on that thread: fixed buffers swapped under the
      # spinlock, same discipline as the daemon's pty reader.
      hIn: Handle
      ev: Handle
      bufs: array[2, array[StdinBufCap, byte]]
      lens: array[2, int]   # 0 means the slot is free for the reader
      eof: Atomic[bool]
      spin: Spin

  proc acquire(s: var Spin) =
    while s.held.exchange(true, moAcquire):
      discard

  proc release(s: var Spin) =
    s.held.store(false, moRelease)

  proc stdinProc(param: pointer): DWORD {.stdcall, gcsafe.} =
    let w = cast[ptr StdinWatch](param)
    while not w.eof.load(moRelaxed):
      var slot = -1
      while slot < 0:
        w.spin.acquire()
        if w.lens[0] == 0:
          slot = 0
        elif w.lens[1] == 0:
          slot = 1
        w.spin.release()
        if slot < 0:
          sleep(1)  # both slots full: the loop drains them
      var n: int32
      if readFile(w.hIn, addr w.bufs[slot][0], StdinBufCap.int32,
                  addr n, nil) == 0 or n <= 0:
        w.eof.store(true, moRelaxed)
        discard setEvent(w.ev)
        return 0
      w.spin.acquire()
      w.lens[slot] = n.int
      w.spin.release()
      discard setEvent(w.ev)
    0

  proc consoleSize(hOut: Handle): tuple[w, h: int] =
    var info: CONSOLE_SCREEN_BUFFER_INFO
    if GetConsoleScreenBufferInfo(hOut, addr info) != 0:
      result.w = info.srWindow.Right.int - info.srWindow.Left.int + 1
      result.h = info.srWindow.Bottom.int - info.srWindow.Top.int + 1

  proc resizeProc(param: pointer): DWORD {.stdcall, gcsafe.} =
    # Windows has no SIGWINCH: poll the screen buffer size and poke the
    # event when it moves. 250ms is well under what a person notices in
    # a resize.
    let watch = cast[ptr ResizeWatch](param)
    var lastW = watch.w.load(moRelaxed)
    var lastH = watch.h.load(moRelaxed)
    while not watch.stop.load(moRelaxed):
      let (w, h) = consoleSize(watch.hOut)
      if w > 0 and h > 0 and (w != lastW or h != lastH):
        lastW = w
        lastH = h
        watch.w.store(w, moRelease)
        watch.h.store(h, moRelease)
        discard setEvent(watch.ev)
      sleep(250)
    0

  proc runClient*(sessionName: string, cfg: Config) =
    # Connect through the daemon's recorded port: on Windows the .port
    # file is the endpoint, there is no unix socket to try first. A
    # daemon started with -l off loopback recorded the same port on its
    # own address, which is the fallback when 127.0.0.1 refuses us.
    let port = daemonPort(sessionName)
    if port <= 0 or port > 65535:
      raise newException(OSError, "session not found: " & sessionName)
    var fd: SocketHandle
    try:
      fd = connectTcp(parseIpAddress("127.0.0.1"), port)
    except OSError:
      if cfg.listen.len == 0:
        raise
      let (ip, _) = parseListen(cfg.listen)
      fd = connectTcp(ip, port)
    # Every client arrives over TCP and must name the session, exactly
    # like the posix -l path.
    discard sendMsg(fd, mkAttach, sessionName.toOpenArrayByte(0, sessionName.len-1))
    let (kind, _) = recvMsg(fd)
    if kind != mkAttached:
      discard closeSocket(fd)
      raise newException(OSError, "attach refused: " & sessionName)

    let hIn = getStdHandle(STD_INPUT_HANDLE)
    let hOut = getStdHandle(STD_OUTPUT_HANDLE)
    let sockEv = wsaCreateEvent()
    var watch = ResizeWatch(hOut: hOut)
    watch.ev = createEvent(nil, 0, 0, nil)  # auto-reset: one resize per wake
    var stdinWatch = StdinWatch(hIn: hIn)
    stdinWatch.ev = createEvent(nil, 0, 0, nil)  # auto-reset: one drain per wake
    if sockEv == Handle(0) or sockEv == Handle(-1) or
        watch.ev == Handle(0) or watch.ev == Handle(-1) or
        stdinWatch.ev == Handle(0) or stdinWatch.ev == Handle(-1):
      raise newException(OSError, "event creation failed: " & $getLastError())
    # WSAEventSelect turns the socket nonblocking, which is why it comes
    # after the attach exchange above: that read must block for its frame.
    discard wsaEventSelect(fd, sockEv, FD_READ or FD_CLOSE)

    # Save console state, then raw VT input: line editing, echo, and
    # signal processing off, VT sequences on, so keys arrive as the same
    # escape sequences a posix terminal sends. VT processing on output is
    # best effort; a console without it just renders the stream ugly.
    var oldIn, oldOut: DWORD
    discard getConsoleMode(hIn, addr oldIn)
    discard getConsoleMode(hOut, addr oldOut)
    var rawIn = oldIn and not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or
                               ENABLE_PROCESSED_INPUT)
    rawIn = rawIn or ENABLE_VIRTUAL_TERMINAL_INPUT
    discard setConsoleMode(hIn, rawIn)
    discard setConsoleMode(hOut, oldOut or ENABLE_VIRTUAL_TERMINAL_PROCESSING)

    # Our terminal size is the session's size: claim it, and follow the
    # local window with the poller for the life of the attach (the desk
    # window resizing re-sizes the shared pty; a smaller co-attached
    # viewer -- the phone -- deliberately does not).
    var w = 80
    var h = 24
    let (w0, h0) = consoleSize(hOut)
    if w0 > 0 and h0 > 0:
      w = w0
      h = h0
    discard sendMsg(fd, mkResize,
      [byte(w shr 8), byte(w and 0xff), byte(h shr 8), byte(h and 0xff)])
    watch.w.store(w, moRelaxed)
    watch.h.store(h, moRelaxed)
    let resizeThread = CreateThread(nil, 0, resizeProc,
                                    cast[pointer](addr watch), 0, nil)
    let stdinThread = CreateThread(nil, 0, stdinProc,
                                   cast[pointer](addr stdinWatch), 0, nil)
    if resizeThread == Handle(0) or stdinThread == Handle(0):
      discard setConsoleMode(hIn, oldIn)
      discard setConsoleMode(hOut, oldOut)
      raise newException(OSError, "CreateThread failed: " & $getLastError())

    var running = true
    var detached = false   # Ctrl-G: the one exit that is not news
    var stdinEof = false   # scripted attach: input done, not an error
    var inbuf: seq[byte]  # partial frame(s) read off the nonblocking socket

    proc handleSocket(fd: SocketHandle, hOut: Handle) =
      ## FD_READ is edge-set once per arrival: whatever landed before the
      ## event select was armed (or between wakes) must be pulled by
      ## hand, then every complete frame in it is rendered. A frame can
      ## straddle reads on a nonblocking socket, so bytes accumulate
      ## until complete.
      var buf: array[4096, byte]
      while running:
        let n = recv(fd, addr buf[0], buf.len.cint, 0)
        if n > 0:
          inbuf.add buf[0..<n]
        elif n == 0:
          running = false  # orderly close
        elif wsaGetLastError() == WSAEWOULDBLOCK:
          break
        else:
          running = false
      try:
        var kind: MsgKind
        var payload: seq[byte]
        while running and takeFrame(inbuf, kind, payload):
          case kind
          of mkOutput:
            if payload.len > 0:
              var written: int32
              discard writeFile(hOut, unsafeAddr payload[0],
                                payload.len.int32, addr written, nil)
          else:
            discard  # another client resized; we just follow the pty
      except IOError:
        running = false

    handleSocket(fd, hOut)

    while running:
      var handles: array[3, Handle]
      handles[0] = stdinWatch.ev
      handles[1] = watch.ev
      handles[2] = sockEv
      let r = waitForMultipleObjects(3, cast[PWOHandleArray](addr handles[0]),
                                     0, INFINITE)
      if r == WAIT_FAILED:
        break
      let idx = r.int - WAIT_OBJECT_0.int
      if idx == 0:
        # stdin -> daemon, through the detach key. The reader thread
        # parked one or two chunks in the fixed slots; take them without
        # holding the spinlock across the network write.
        for slot in 0 .. 1:
          stdinWatch.spin.acquire()
          let n = stdinWatch.lens[slot]
          stdinWatch.spin.release()
          if n == 0:
            continue
          # Ctrl-G (BEL) detaches; everything else reaches the program.
          # Detach only on a lone keypress: a BEL inside pasted text must
          # not kick the client out of the session.
          if n == 1 and stdinWatch.bufs[slot][0] == CtrlG:
            discard sendMsg(fd, mkDetach)
            detached = true
            running = false
          else:
            discard sendMsg(fd, mkInput,
              toOpenArray(stdinWatch.bufs[slot], 0, n - 1))
          stdinWatch.spin.acquire()
          stdinWatch.lens[slot] = 0
          stdinWatch.spin.release()
        if stdinWatch.eof.load(moRelaxed):
          stdinEof = true
          running = false
      elif idx == 1:
        # The poller saw the console move: claim the new size for the
        # session.
        let w = watch.w.load(moAcquire)
        let h = watch.h.load(moAcquire)
        discard sendMsg(fd, mkResize,
          [byte(w shr 8), byte(w and 0xff), byte(h shr 8), byte(h and 0xff)])
      elif idx == 2:
        # daemon -> console. WSAEnumNetworkEvents is the reset.
        var ne: WSANETWORKEVENTS
        discard WSAEnumNetworkEvents(fd, sockEv, addr ne)
        if (ne.lNetworkEvents and (FD_READ or FD_CLOSE)) != 0:
          handleSocket(fd, hOut)

    # A session that vanished under us (daemon exit, mpx kill) is an
    # error, not a silent success. Detach and stdin EOF are the only
    # quiet exits.
    if not detached and not stdinEof:
      raise newException(OSError, "session ended: " & sessionName)

    # Cleanup: stop the poller before restoring, so no resize lands after
    # the console went back to cooked mode. The stdin reader may sit in
    # readFile until the next byte forever; the process exit reaps it.
    watch.stop.store(true, moRelease)
    discard waitForSingleObject(resizeThread, 1000)
    discard setConsoleMode(hIn, oldIn)
    discard setConsoleMode(hOut, oldOut)
    discard closeHandle(resizeThread)
    discard closeHandle(stdinThread)
    discard closeHandle(watch.ev)
    discard closeHandle(stdinWatch.ev)
    discard closeHandle(sockEv)
    discard closeSocket(fd)
