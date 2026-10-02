import std/[os, strutils, sequtils, atomics]
from std/net import IpAddress
when defined(windows):
  import mpx/win
else:
  import std/[posix, selectors]
import mpx/[pty, protocol, log, config]
import ttty/[terminal, grid]

const
  # Cap on a client's pending output. A client that cannot drain (dead
  # peer, stalled TCP link) gets dropped instead of growing the queue
  # without bound. Snapshots are a few MB at worst and must fit.
  OutqCap = 16 * 1024 * 1024

when defined(windows):
  const
    # WaitForMultipleObjects cannot watch more than MAXIMUM_WAIT_OBJECTS
    # (64) handles. The loop holds three fixed ones (stop, pty data,
    # listener) plus one per client.
    MaxClients = 56
    # Double-buffer cap for pty output. The reader parks chunks here for
    # the loop; when both are full the reader waits instead of dropping.
    PtyBufCap = 256 * 1024

  type
    Spin = object
      # The pty queues are shared with the pty threads, and the critical
      # sections are memcpy-scale, so a spinlock beats a Win32 one.
      held: Atomic[bool]

  proc acquire(s: var Spin) =
    while s.held.exchange(true, moAcquire):
      discard

  proc release(s: var Spin) =
    s.held.store(false, moRelease)

type
  Client = object
    fd: SocketHandle
    vetted: bool      # unix clients are trusted on arrival, TCP must name the session
    snapshotPending: bool  # no frame sent yet: wait for the client's resize so
                           # the snapshot renders at the client's geometry
    outq: seq[byte]   # framed bytes the socket would not take yet
    inbuf: seq[byte]  # partial frame(s) read off a non-blocking socket
    when defined(windows):
      ev: Handle      # WSA event carrying this socket's read/write/close

  Session = object
    name: string
    pty: Pty
    clients: seq[Client]
    ptyInq: seq[byte]  # posix: input the pty buffer would not take yet;
                       # windows: the handoff queue the writer thread drains
    running: bool
    term: Terminal  # ttty side cache for attach snapshots
    when not defined(windows):
      sel: Selector[SocketHandle]
    else:
      # The reader thread is a raw CreateThread (no Nim TLS), so it must
      # not allocate: pty output lands in double fixed buffers the loop
      # swaps under the spinlock, zero allocations on that thread.
      ptyBufs: array[2, array[PtyBufCap, byte]]
      ptyLen: array[2, int]
      ptyActive: int
      ptyEof: Atomic[bool]  # the reader saw the console side go away
      pspin: Spin          # guards ptyInq and the pty buffers
      stopEv, dataEv, inEv: Handle

when not defined(windows):
  # Set by the signal handler, polled by the event loop: a signal interrupts
  # select (EINTR makes it return empty) and the loop condition picks it up.
  var shutdownRequested: Atomic[bool]

  proc onShutdown(sig: cint) {.noconv.} =
    shutdownRequested.store(true, moRelaxed)

proc newSession*(name, cmd: string, args: openArray[string] = []): Session =
  ## Built from mpx.nim's main on purpose, never inside runDaemon: the
  ## Windows ConPTY spawn in here must run at main's stack depth. One
  ## frame deeper, inside runDaemon, the spawned child does not get
  ## attached to the pseudoconsole on Win11 26100 in this mingw build.

  result.name = name
  result.pty = openPty(cmd, args)
  result.running = true
  result.term = newTerminal(80, 24, 10000)  # larger scrollback

proc clientIndex(session: Session, fd: SocketHandle): int =
  for i, c in session.clients:
    if c.fd == fd:
      return i
  -1

proc removeClient(session: var Session, fd: SocketHandle) =
  var i = 0
  while i < session.clients.len:
    if session.clients[i].fd == fd:
      session.clients.delete(i)
    else:
      inc i

proc addClient(session: var Session, fd: SocketHandle, vetted: bool): bool =
  ## Register a fresh client with the loop. False: refused (the windows
  ## wait-handle cap) or the platform registration failed; the socket is
  ## closed either way.
  when defined(windows):
    if session.clients.len >= MaxClients:
      discard closeSocket(fd)
      return false
    let ev = wsaCreateEvent()
    if ev == Handle(0) or ev == Handle(-1):
      discard closeSocket(fd)
      return false
    # FD_WRITE is edge-triggered: it fires when the socket unblocks after
    # a would-block send, which is the whole outq mechanism on this side.
    discard wsaEventSelect(fd, ev, FD_READ or FD_WRITE or FD_CLOSE)
    session.clients.add(Client(fd: fd, vetted: vetted,
                               snapshotPending: vetted, ev: ev))
  else:
    session.clients.add(Client(fd: fd, vetted: vetted, snapshotPending: vetted))
    session.sel.registerHandle(fd, {Event.Read}, fd)
  result = true

proc dropClient(session: var Session, fd: SocketHandle) =
  when defined(windows):
    let i = session.clientIndex(fd)
    if i >= 0:
      discard closeHandle(session.clients[i].ev)
    discard closeSocket(fd)
  else:
    try:
      session.sel.unregister(fd)
    except ValueError:
      discard
    discard posix.close(fd)
  session.removeClient(fd)

when not defined(windows):
  proc setInterest(session: var Session, fd: SocketHandle,
                   wantWrite: bool) =
    # Write interest only while a queue is pending: an always-writable fd
    # would make select spin.
    var evs = {Event.Read}
    if wantWrite:
      evs.incl Event.Write
    session.sel.updateHandle(fd, evs)

proc flushClient(session: var Session, i: int): bool =
  ## Push queued frames until the socket is full. False: peer is gone.
  let c = addr session.clients[i]
  while c.outq.len > 0:
    when defined(windows):
      let w = send(c.fd, addr c.outq[0], cint(c.outq.len), 0)
      if w > 0:
        c.outq.delete(0 ..< w.int)
      elif w == -1 and wsaGetLastError() == WSAEWOULDBLOCK:
        break
      else:
        return false
    else:
      let w = posix.write(c.fd.cint, addr c.outq[0], c.outq.len)
      if w > 0:
        c.outq.delete(0 ..< w)
      elif errno == EAGAIN or errno == EWOULDBLOCK:
        break
      else:
        return false
  when not defined(windows):
    session.setInterest(c.fd, c.outq.len > 0)
  result = true

proc queueClient(session: var Session, i: int,
                 kind: MsgKind, payload: openArray[byte]): bool =
  ## Frame and append to a client's queue, then send what fits now.
  ## False: over cap or hard write error; caller drops the client.
  let frame = frameBytes(kind, payload)
  let c = addr session.clients[i]
  if c.outq.len + frame.len > OutqCap:
    return false
  c.outq.add frame
  result = session.flushClient(i)

proc broadcast(session: var Session, kind: MsgKind, payload: openArray[byte]) =
  var i = 0
  while i < session.clients.len:
    if not session.clients[i].vetted or session.clients[i].snapshotPending:
      inc i  # unvetted TCP clients hear nothing; a pre-snapshot client is
             # about to receive the whole modeled screen instead
    elif session.queueClient(i, kind, payload):
      inc i
    else:
      session.dropClient(session.clients[i].fd)

proc queueSnapshot(session: var Session, i: int) =
  ## Full-model render: scrollback as text, then the live screen with
  ## attributes. Ends by moving the terminal cursor to the cell the
  ## session's program thinks it occupies: programs keep drawing with
  ## relative cursor moves after the attach, and a cursor left at the
  ## bottom row would smear that output across the screen.
  let g = session.term.grid
  let snap = g.renderAnsiFull()
  if snap.len > 0:
    let first = max(0, g.rows.len - g.height)
    let r = max(0, g.row - first)
    var frame = snap & "\x1b[" & $(r + 1) & ";" & $(g.col + 1) & "H"
    if not session.queueClient(i, mkOutput, frame.toOpenArrayByte(0, frame.len-1)):
      session.dropClient(session.clients[i].fd)

proc flushPty(session: var Session) =
  ## Feed queued input to the pty. The program may stop reading (a build
  ## spewing output, a stopped editor); blocking the loop would stall
  ## every client, so posix parks the remainder for writability while
  ## windows hands it to the blocking writer thread.
  when defined(windows):
    discard setEvent(session.inEv)
  else:
    let fd = session.pty.masterFd.SocketHandle
    while session.ptyInq.len > 0:
      let w = posix.write(session.pty.masterFd, addr session.ptyInq[0],
                          session.ptyInq.len)
      if w > 0:
        session.ptyInq.delete(0 ..< w)
      elif errno == EAGAIN or errno == EWOULDBLOCK:
        session.setInterest(fd, true)
        return
      else:
        discard  # EIO: child gone; the read side ends the session
    session.setInterest(fd, false)

proc takeClientFrame(session: var Session, i: int,
                     kind: var MsgKind, payload: var seq[byte]): bool =
  takeFrame(session.clients[i].inbuf, kind, payload)

proc handleClientMsg(session: var Session, i: int,
                     kind: MsgKind, payload: seq[byte]): bool =
  ## Handle one parsed frame. False: the client must be dropped.
  if not session.clients[i].vetted:
    return true  # unvetted TCP clients only get mkAttach processed
  case kind
  of mkInput:
    # Primaryless: every attached client writes to the pty.
    if payload.len > 0:
      when defined(windows):
        session.pspin.acquire()
        session.ptyInq.add payload
        session.pspin.release()
      else:
        session.ptyInq.add payload
      session.flushPty()
  of mkResize:
    # Any client may resize; last one wins.
    if payload.len >= 4:
      let w = (payload[0].uint16 shl 8) or payload[1].uint16
      let h = (payload[2].uint16 shl 8) or payload[3].uint16
      session.pty.setSize(w, h)
      session.term.grid.resize(w.int, h.int)
      # First frame to a fresh client renders at its geometry: resized
      # grid first, then the snapshot. Rendered before the resize, a
      # taller grid than the client pushes all content off the top of
      # its screen, leaving a blank screen with the cursor at the bottom.
      if session.clients[i].snapshotPending:
        session.clients[i].snapshotPending = false
        session.queueSnapshot(i)
      # Broadcast resize to all clients so they can adapt
      session.broadcast(mkResize, payload)
  of mkDetach:
    return false
  else:
    discard
  result = true

proc feedClient(session: var Session, log: Logger, fd: SocketHandle,
                data: openArray[byte]): bool =
  ## Buffer new socket bytes and run every complete frame in them.
  ## False: the client must be dropped. Handling a frame can drop
  ## another client (dead peer in broadcast); indexes shift, so ours is
  ## re-resolved every time.
  let first = session.clientIndex(fd)
  if first < 0:
    return false
  session.clients[first].inbuf.add data
  var kind: MsgKind
  var payload: seq[byte]
  while true:
    let ci = session.clientIndex(fd)
    if ci < 0:
      return false
    if not session.takeClientFrame(ci, kind, payload):
      return true  # no complete frame left: wait for more bytes
    if kind == mkIdent:
      # Identity probe (isActive on Windows): answer with the session
      # name, leave the client unvetted, it hangs up right after.
      if not session.queueClient(ci, mkIdent,
          session.name.toOpenArrayByte(0, session.name.len-1)):
        return false
      continue
    if kind == mkAttach and session.clients[ci].vetted.not:
      # Unvetted TCP client: check the session name
      if payload == session.name.toOpenArrayByte(0, session.name.len-1):
        session.clients[ci].vetted = true
        if not session.queueClient(ci, mkAttached, []):
          return false
        session.clients[ci].snapshotPending = true
        log.info "client attached fd=" & $fd.cint & " (tcp)"
      else:
        let err = "no such session"
        discard session.queueClient(ci, mkError,
          err.toOpenArrayByte(0, err.len-1))
        return false
    else:
      if not session.handleClientMsg(ci, kind, payload):
        return false

proc startTcpListener(ip: IpAddress, basePort: int): (SocketHandle, int) =
  ## First free port at or above basePort. Raises OSError when nothing
  ## is free in the scan window.
  const maxTries = 64
  for p in basePort ..< basePort + maxTries:
    try:
      let fd = listenTcp(ip, p)
      return (fd, p)
    except OSError:
      continue
  raise newException(OSError, "no free TCP port in " & $basePort & ".." & $(basePort + maxTries - 1))

when defined(windows):

  proc ptyReaderProc(param: pointer): DWORD {.stdcall, gcsafe.} =
    ## Blocking ReadFile on the ConPTY output pipe: anonymous pipes are
    ## not selectable, so a thread is the honest translation of a
    ## readable pty master. Chunks land in the shared buffer, the data
    ## event wakes the loop.
    let s = cast[ptr Session](param)
    while true:
      var buf: array[4096, byte]
      let n = s.pty.read(addr buf[0], buf.len)
      if n <= 0:
        # Broken pipe or hard error: the console side is gone, the same
        # fact a posix master reports as EOF or EIO when the child exits.
        s.ptyEof.store(true, moRelease)
        discard setEvent(s.dataEv)
        return 0
      var off = 0
      while off < n:
        s.pspin.acquire()
        let active = s.ptyActive
        let room = PtyBufCap - s.ptyLen[active]
        let take = min(room, n - off)
        if take > 0:
          copyMem(addr s.ptyBufs[active][s.ptyLen[active]], addr buf[off], take)
          inc s.ptyLen[active], take
        s.pspin.release()
        if take == 0:
          sleep(1)  # both buffers full: the loop drains them
        inc off, take
      discard setEvent(s.dataEv)

  proc ptyWriterProc(param: pointer): DWORD {.stdcall, gcsafe.} =
    ## Wait for input to show up in the shared queue, then feed it to the
    ## console with blocking WriteFile: console backpressure parks here,
    ## in this thread, instead of stalling the loop.
    let s = cast[ptr Session](param)
    var waits: array[2, Handle]
    waits[0] = s.stopEv
    waits[1] = s.inEv
    while waitForMultipleObjects(2, cast[PWOHandleArray](addr waits[0]), 0,
                                 INFINITE) == WAIT_OBJECT_0 + 1:
      while true:
        s.pspin.acquire()
        if s.ptyInq.len == 0:
          s.pspin.release()
          break
        var chunk = move(s.ptyInq)
        s.pspin.release()
        var off = 0
        while off < chunk.len:
          let w = s.pty.write(addr chunk[off], chunk.len - off)
          if w <= 0:
            return 0  # child gone; the reader side ends the session
          off += w
    return 0

  proc runDaemon*(sessionName, cmd: string, cfg: Config,
                  session: Session) =
    var session = session  # params are immutable; the loop mutates this
    let log = initLogger(cfg.log)
    log.info "daemon: session=" & sessionName & " cmd=" & cmd
    removeSocket(sessionName)
    let path = socketPath(sessionName)
    # Loopback TCP is the transport on Windows: anonymous pipes do not mix
    # with WSA events, so the endpoint is a port number in the .port file.
    # -l moves the listener off loopback, same flag, same scan.
    let (ip, basePort) = parseListen(
      if cfg.listen.len > 0: cfg.listen else: "127.0.0.1:4534")
    let (listenFd, port) = startTcpListener(ip, basePort)
    writeFile(path, $port)
    # Record the daemon pid next to the port file: kill targets the exact
    # process without /proc or toolhelp snapshot walking.
    writeFile(path.changeFileExt("pid"), $getCurrentProcessId())
    log.info "listening on tcp " & $ip & ":" & $port
    log.info "listening on " & path

    session.stopEv = createEvent(nil, 1, 0, nil)   # sticky: shutdown
    session.dataEv = createEvent(nil, 0, 0, nil)   # auto-reset: one drain per wake
    session.inEv = createEvent(nil, 0, 0, nil)     # auto-reset: one queue drain
    let listenEv = wsaCreateEvent()
    if session.stopEv == Handle(0) or session.dataEv == Handle(0) or
        session.inEv == Handle(0) or listenEv == Handle(0) or
        listenEv == Handle(-1):
      raise newException(OSError, "event creation failed: " & $getLastError())
    discard wsaEventSelect(listenFd, listenEv, FD_ACCEPT)
    let reader = CreateThread(nil, 0, ptyReaderProc,
                              cast[pointer](addr session), 0, nil)
    let writer = CreateThread(nil, 0, ptyWriterProc,
                              cast[pointer](addr session), 0, nil)
    if reader == Handle(0) or writer == Handle(0):
      raise newException(OSError, "CreateThread failed: " & $getLastError())

    while session.running:
      var handles: WOHandleArray
      handles[0] = session.stopEv
      handles[1] = session.dataEv
      handles[2] = listenEv
      for i, c in session.clients:
        handles[3 + i] = c.ev
      let count = (3 + session.clients.len).DWORD
      let r = waitForMultipleObjects(count, cast[PWOHandleArray](addr handles[0]),
                                     0, INFINITE)
      let idx = r.int - WAIT_OBJECT_0.int
      if idx < 0 or idx >= count.int:
        break  # WAIT_FAILED: nothing sensible left to do but clean up
      if idx == 0:
        session.running = false
      elif idx == 1:
        # PTY output. Drain before the eof check: the reader's last chunk
        # and its eof report can coalesce into one wake.
        session.pspin.acquire()
        let taken = session.ptyActive
        session.ptyActive = 1 - taken
        let n = session.ptyLen[taken]
        session.pspin.release()
        if n > 0:
          var chunk = newString(n)
          copyMem(addr chunk[0], addr session.ptyBufs[taken][0], n)
          session.term.write(chunk)
          session.broadcast(mkOutput, toOpenArray(session.ptyBufs[taken], 0, n - 1))
          session.pspin.acquire()
          session.ptyLen[taken] = 0
          session.pspin.release()
        if session.ptyEof.load(moAcquire):
          session.running = false
      elif idx == 2:
        var ne: WSANETWORKEVENTS
        discard WSAEnumNetworkEvents(listenFd, listenEv, addr ne)
        if (ne.lNetworkEvents and FD_ACCEPT) != 0:
          while true:
            let clientFd = accept(listenFd, nil, nil)
            if clientFd == SocketHandle(-1):
              break
            setNonBlocking(clientFd)
            # Every client arrives over TCP: held until it names the
            # session, exactly like the posix -l path.
            discard session.addClient(clientFd, false)
      else:
        let ci = idx - 3
        let fd = session.clients[ci].fd
        var ne: WSANETWORKEVENTS
        discard WSAEnumNetworkEvents(fd, session.clients[ci].ev, addr ne)
        let evs = ne.lNetworkEvents
        var drop = false
        try:
          if (evs and FD_WRITE) != 0:
            drop = not session.flushClient(ci)
          if (evs and FD_READ) != 0 and not drop:
            var buf: array[4096, byte]
            while not drop:
              let n = recv(fd, addr buf[0], buf.len.cint, 0)
              if n > 0:
                drop = not session.feedClient(log, fd, buf[0..<n])
              elif n == 0:
                drop = true  # orderly close
              elif wsaGetLastError() == WSAEWOULDBLOCK:
                break
              else:
                drop = true
          if (evs and FD_CLOSE) != 0:
            drop = true
        except IOError:
          drop = true
        if drop:
          session.dropClient(fd)

    # Cleanup
    discard setEvent(session.stopEv)  # releases the writer thread
    # Bounded: the writer may be sitting in a WriteFile the console is
    # not draining; the process exit below reaps it either way.
    discard waitForSingleObject(writer, 1000)
    for c in session.clients:
      discard closeHandle(c.ev)
      discard closeSocket(c.fd)
    discard closeSocket(listenFd)
    discard closeHandle(listenEv)
    removeSocket(sessionName)
    removeLock(sessionName)
    try:
      removeFile(socketPath(sessionName).changeFileExt("pid"))
    except OSError:
      discard
    session.pty.close()
    discard closeHandle(reader)
    discard closeHandle(writer)
    discard closeHandle(session.stopEv)
    discard closeHandle(session.dataEv)
    discard closeHandle(session.inEv)
    log.info "daemon: exited"
    log.close()

else:

  proc runDaemon*(sessionName, cmd: string, cfg: Config,
                  session: Session) =
    var session = session  # params are immutable; the loop mutates this
    let log = initLogger(cfg.log)
    # A client that vanished mid-broadcast must cost us the client, not the
    # process: writes to its dead socket would raise SIGPIPE and take the
    # daemon, and the session with it.
    discard signal(SIGPIPE, SIG_IGN)
    # SIGTERM/SIGINT/SIGHUP must run the cleanup below, not skip it: the
    # default disposition kills the daemon mid-flight and leaves socket,
    # pid, and lock files behind for attach to trip over.
    discard signal(SIGTERM, onShutdown)
    discard signal(SIGINT, onShutdown)
    discard signal(SIGHUP, onShutdown)
    log.info "daemon: session=" & sessionName & " cmd=" & cmd
    removeSocket(sessionName)
    let path = socketPath(sessionName)
    # Record the daemon pid next to the socket: kill targets the exact
    # process without /proc cmdline matching (which breaks under qemu
    # emulation and differs across platforms).
    writeFile(path.changeFileExt("pid"), $getpid())

    let listenFd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    if listenFd == SocketHandle(-1):
      raise newException(OSError, "socket failed")

    var saddr: Sockaddr_un
    saddr.sun_family = AF_UNIX.TSa_Family
    let pathCstr = path.cstring
    if pathCstr.len >= saddr.sun_path.len:
      raise newException(OSError, "socket path too long")
    copyMem(addr saddr.sun_path, pathCstr, pathCstr.len)

    if bindSocket(listenFd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_un).SockLen) != 0:
      raise newException(OSError, "bind failed: " & path)
    if listen(listenFd, 5) != 0:
      raise newException(OSError, "listen failed")

    # Optional TCP listener. Session name gates access: TCP clients send
    # mkAttach with the session name, wrong names get dropped.
    var tcpFd = SocketHandle(-1)
    var tcpPort = 0
    if cfg.listen.len > 0:
      try:
        let (ip, basePort) = parseListen(cfg.listen)
        (tcpFd, tcpPort) = startTcpListener(ip, basePort)
        log.info "listening on tcp " & cfg.listen.rsplit(':', 1)[0] & ":" & $tcpPort
      except ValueError, OSError:
        log.info "tcp listener disabled: " & getCurrentExceptionMsg()

    # Everything the event loop touches is non-blocking: a single stalled
    # write (slow client, busy program) used to wedge the loop, freezing
    # the session for every client, including fresh attaches.
    setNonBlocking(session.pty.masterFd.SocketHandle)
    session.sel = newSelector[SocketHandle]()
    session.sel.registerHandle(listenFd, {Event.Read}, listenFd)
    if tcpFd != SocketHandle(-1):
      session.sel.registerHandle(tcpFd, {Event.Read}, tcpFd)
    session.sel.registerHandle(session.pty.masterFd.SocketHandle, {Event.Read}, session.pty.masterFd.SocketHandle)

    log.info "listening on " & path

    while session.running and not shutdownRequested.load(moRelaxed):
      let events = session.sel.select(-1)
      for ev in events:
        if ev.fd == listenFd.cint:
          # New client on the unix socket: trusted, attach immediately
          let clientFd = accept(listenFd, nil, nil)
          if clientFd != SocketHandle(-1):
            setNonBlocking(clientFd)
            discard session.addClient(clientFd, true)
            log.info "client attached fd=" & $clientFd.cint
        elif ev.fd == tcpFd.cint:
          # New TCP client: hold it until it names the right session
          let clientFd = accept(tcpFd, nil, nil)
          if clientFd != SocketHandle(-1):
            setNonBlocking(clientFd)
            discard session.addClient(clientFd, false)
        elif ev.fd == session.pty.masterFd:
          if Event.Write in ev.events:
            session.flushPty()
          if (Event.Read in ev.events or Event.Error in ev.events) and
              session.running:
            # PTY output. The last slave fd closing surfaces as
            # Event.Error (EPOLLHUP), not Read: the read below confirms it.
            var buf: array[4096, byte]
            let n = session.pty.read(addr buf[0], buf.len)
            if n > 0:
              # Feed ttty side cache
              session.term.write(cast[string](buf[0..<n]))
              session.broadcast(mkOutput, buf[0..<n])
            elif n == 0 or errno == EIO:
              # Child exited. Linux reports PTY EOF as EIO (-1), BSD as 0.
              # EAGAIN just means the readable edge was already drained.
              session.running = false
              break
        else:
          # Client socket: readable frames, writable queue
          let fd = ev.fd.SocketHandle
          let i = session.clientIndex(fd)
          if i < 0:
            continue
          var drop = false
          try:
            if Event.Write in ev.events:
              drop = not session.flushClient(i)
            if (Event.Read in ev.events or Event.Error in ev.events) and
              not drop:
              # Error on a client socket is a dead peer; the read says EOF
              var buf: array[4096, byte]
              let n = posix.read(fd.cint, addr buf[0], buf.len)
              if n > 0:
                drop = not session.feedClient(log, fd, buf[0..<n])
              else:
                drop = true  # EOF
          except IOError:
            drop = true
          if drop:
            session.dropClient(fd)

    # Cleanup
    for client in session.clients:
      discard posix.close(client.fd)
    discard posix.close(listenFd)
    if tcpFd != SocketHandle(-1):
      discard posix.close(tcpFd)
    removeSocket(sessionName)
    removeLock(sessionName)
    try:
      removeFile(socketPath(sessionName).changeFileExt("pid"))
    except OSError:
      discard
    session.pty.close()
    log.info "daemon: exited"
    log.close()
