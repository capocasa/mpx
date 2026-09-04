import std/[posix, os, strutils, selectors]
import mpx/[pty, protocol]
import ttty/[terminal, grid]

type
  Client = object
    fd: SocketHandle
    snapshotSent: bool

  Session = object
    name: string
    pty: Pty
    clients: seq[Client]
    running: bool
    term: Terminal  # ttty side cache for attach snapshots

proc newSession(name, cmd: string): Session =
  result.name = name
  result.pty = openPty(cmd)
  result.running = true
  result.term = newTerminal(80, 24, 10000)  # larger scrollback

proc removeClient(session: var Session, fd: SocketHandle) =
  var i = 0
  while i < session.clients.len:
    if session.clients[i].fd == fd:
      session.clients.delete(i)
    else:
      inc i

proc broadcast(session: var Session, kind: MsgKind, payload: openArray[byte]) =
  var i = 0
  while i < session.clients.len:
    let client = session.clients[i]
    try:
      sendMsg(client.fd, kind, payload)
      inc i
    except IOError:
      session.clients.delete(i)

proc handleClientMsg(session: var Session, fd: SocketHandle, kind: MsgKind, payload: seq[byte]) =
  # Find client
  var clientIdx = -1
  for i, c in session.clients:
    if c.fd == fd:
      clientIdx = i
      break
  if clientIdx < 0: return
  
  case kind
  of mkInput:
    discard session.pty.write(unsafeAddr payload[0], payload.len)
  of mkResize:
    # Any client may resize; last one wins
    if payload.len >= 4:
      let w = (payload[0].uint16 shl 8) or payload[1].uint16
      let h = (payload[2].uint16 shl 8) or payload[3].uint16
      session.pty.setSize(w, h)
      session.term.grid.resize(w.int, h.int)
      # Broadcast resize to all clients so they can adapt
      session.broadcast(mkResize, payload)
    # Send snapshot to newly attached client on first resize
    if not session.clients[clientIdx].snapshotSent:
      let snap = session.term.grid.renderAnsi(session.term.grid.width, session.term.grid.height)
      sendMsg(fd, mkOutput, snap.toOpenArrayByte(0, snap.len-1))
      session.clients[clientIdx].snapshotSent = true
  of mkDetach:
    session.removeClient(fd)
    discard posix.close(fd)
  else:
    discard

proc runDaemon*(sessionName, cmd: string) =
  removeSocket(sessionName)
  let path = socketPath(sessionName)
  
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

  var session = newSession(sessionName, cmd)
  var sel = newSelector[SocketHandle]()
  sel.registerHandle(listenFd, {Event.Read}, listenFd)
  sel.registerHandle(session.pty.masterFd.SocketHandle, {Event.Read}, session.pty.masterFd.SocketHandle)

  # TODO: route to a log file under $XDG_DATA_HOME/mpx once logging lands
  # echo "daemon: listening on ", path

  while session.running:
    let events = sel.select(-1)
    for ev in events:
      if ev.fd == listenFd.cint:
        # New client
        let clientFd = accept(listenFd, nil, nil)
        if clientFd != SocketHandle(-1):
          session.clients.add(Client(fd: clientFd))
          sel.registerHandle(clientFd, {Event.Read}, clientFd)
          # echo "daemon: client attached, fd=", clientFd.cint
      elif ev.fd == session.pty.masterFd:
        # PTY output
        var buf: array[4096, byte]
        let n = session.pty.read(addr buf[0], buf.len)
        if n > 0:
          # Feed ttty side cache
          session.term.write(cast[string](buf[0..<n]))
          session.broadcast(mkOutput, buf[0..<n])
        else:
          # Child exited. Linux reports PTY EOF as EIO (-1), BSD as 0.
          session.running = false
          break
      else:
        # Client message
        let fd = ev.fd.SocketHandle
        try:
          let (kind, payload) = recvMsg(fd)
          session.handleClientMsg(fd, kind, payload)
          if kind == mkDetach:
            sel.unregister(fd)
        except IOError:
          # Client disconnected
          session.removeClient(fd)
          sel.unregister(fd)
          discard posix.close(fd)

  # Cleanup
  for client in session.clients:
    discard posix.close(client.fd)
  discard posix.close(listenFd)
  removeSocket(sessionName)
  removeLock(sessionName)
  session.pty.close()
  # echo "daemon: exited"