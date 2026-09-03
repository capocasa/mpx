import std/[posix, os, strutils, selectors]
import multiplexer/[pty, protocol]

type
  Client = object
    fd: SocketHandle
    controlling: bool

  Session = object
    name: string
    pty: Pty
    clients: seq[Client]
    running: bool

proc newSession(name, cmd: string): Session =
  result.name = name
  result.pty = openPty(cmd)
  result.running = true

proc removeClient(session: var Session, fd: SocketHandle) =
  for i in 0..<session.clients.len:
    if session.clients[i].fd == fd:
      session.clients.delete(i)
      break

proc broadcast(session: var Session, kind: MsgKind, payload: openArray[byte]) =
  for client in session.clients.mitems:
    try:
      sendMsg(client.fd, kind, payload)
    except IOError:
      discard

proc handleClientMsg(session: var Session, fd: SocketHandle, kind: MsgKind, payload: seq[byte]) =
  case kind
  of mkInput:
    discard session.pty.write(unsafeAddr payload[0], payload.len)
  of mkResize:
    if payload.len >= 4:
      let w = (payload[0].uint16 shl 8) or payload[1].uint16
      let h = (payload[2].uint16 shl 8) or payload[3].uint16
      session.pty.setSize(w, h)
      # Broadcast resize to all clients so they can adapt
      session.broadcast(mkResize, payload)
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

  echo "daemon: listening on ", path
  
  while session.running:
    let events = sel.select(-1)
    for ev in events:
      if ev.fd == listenFd.cint:
        # New client
        let clientFd = accept(listenFd, nil, nil)
        if clientFd != SocketHandle(-1):
          session.clients.add(Client(fd: clientFd, controlling: session.clients.len == 0))
          sel.registerHandle(clientFd, {Event.Read}, clientFd)
          echo "daemon: client attached, fd=", clientFd.cint
      elif ev.fd == session.pty.masterFd:
        # PTY output
        var buf: array[4096, byte]
        let n = session.pty.read(addr buf[0], buf.len)
        if n > 0:
          session.broadcast(mkOutput, buf[0..<n])
        elif n == 0:
          # Child exited
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
  session.pty.close()
  echo "daemon: exited"