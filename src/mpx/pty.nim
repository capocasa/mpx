import std/[posix]

# Manual declarations for openpty and winsize (not in Nim's posix module)

type
  Winsize* {.importc: "struct winsize", header: "<sys/ioctl.h>", final, pure.} = object
    ws_row*: uint16
    ws_col*: uint16
    ws_xpixel: uint16
    ws_ypixel: uint16

proc openpty(amaster, aslave: ptr cint, name: cstring, termp: pointer, winp: ptr Winsize): cint
  {.importc, header: "<pty.h>".}

proc ioctl(fd: cint, request: culong, arg: pointer): cint
  {.importc, header: "<sys/ioctl.h>".}

const
  TIOCSCTTY = 0x540E'u32
  TIOCSWINSZ = 0x5414'u32
  TIOCGWINSZ = 0x5413'u32

type
  Pty* = object
    masterFd*: cint
    childPid*: Pid

proc openPty*(cmd: string, args: openArray[string] = [], width: uint16 = 80, height: uint16 = 24): Pty =
  var master, slave: cint
  var win: Winsize
  win.ws_col = width
  win.ws_row = height
  win.ws_xpixel = 0
  win.ws_ypixel = 0

  if openpty(addr master, addr slave, nil, nil, addr win) != 0:
    raise newException(OSError, "openpty failed")

  let pid = fork()
  if pid == 0:
    # Child: become session leader, attach slave as controlling terminal
    discard setsid()
    discard ioctl(slave, TIOCSCTTY, nil)
    discard dup2(slave, 0)
    discard dup2(slave, 1)
    discard dup2(slave, 2)
    if slave > 2:
      discard close(slave)
    discard close(master)

    let argv = allocCStringArray(@[cmd] & @args)
    discard execvp(cmd.cstring, argv)
    deallocCStringArray(argv)
    quit(1)
  elif pid < 0:
    discard close(master)
    discard close(slave)
    raise newException(OSError, "fork failed")

  discard close(slave)
  result.masterFd = master
  result.childPid = pid

proc setSize*(pty: Pty, width, height: uint16) =
  var win: Winsize
  win.ws_col = width
  win.ws_row = height
  win.ws_xpixel = 0
  win.ws_ypixel = 0
  discard ioctl(pty.masterFd, TIOCSWINSZ, addr win)

proc read*(pty: Pty, buf: pointer, len: int): int =
  result = posix.read(pty.masterFd, buf, len)

proc write*(pty: Pty, buf: pointer, len: int): int =
  result = posix.write(pty.masterFd, buf, len)

proc close*(pty: Pty) =
  discard posix.close(pty.masterFd)
  var status: cint
  discard waitpid(pty.childPid, status, WNOHANG)