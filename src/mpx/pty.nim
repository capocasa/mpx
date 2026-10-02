import std/os

when defined(windows):
  import mpx/win
else:
  import std/posix

proc defaultShell*(): string =
  ## The program to run when the user names no command. POSIX has
  ## $SHELL; Windows has no such convention, so probe the usual suspects.
  when defined(windows):
    for exe in ["pwsh.exe", "powershell.exe"]:
      let found = findExe(exe)
      if found.len > 0:
        return found
    result = "cmd.exe"
  else:
    result = getEnv("SHELL", "/bin/sh")

when not defined(windows):
  # Manual declarations for openpty and winsize (not in Nim's posix module)

  type
    Winsize* {.importc: "struct winsize", header: "<sys/ioctl.h>", final, pure.} = object
      ws_row*: uint16
      ws_col*: uint16
      ws_xpixel: uint16
      ws_ypixel: uint16

  when defined(macosx) or defined(freebsd) or defined(netbsd) or defined(openbsd) or defined(dragonfly):
    # BSD lineage: openpty lives in <util.h> (and needs -lutil on some)
    proc openpty(amaster, aslave: ptr cint, name: cstring, termp: pointer, winp: ptr Winsize): cint
      {.importc, header: "<util.h>".}
  else:
    proc openpty(amaster, aslave: ptr cint, name: cstring, termp: pointer, winp: ptr Winsize): cint
      {.importc, header: "<pty.h>".}

  proc ioctl(fd: cint, request: culong, arg: pointer): cint
    {.importc, header: "<sys/ioctl.h>".}

  when defined(macosx) or defined(macos):
    const TIOCSCTTY = 0x20007461'u32  # _IOW('t', 132) on BSD/macOS
  else:
    const TIOCSCTTY = 0x540E'u32   # Linux
  const
    TIOCSWINSZ = 0x5414'u32
    TIOCGWINSZ = 0x5413'u32

  type
    Pty* = object
      masterFd*: cint
      childPid*: Pid

  proc openPty*(cmd: string, args: openArray[string] = [], width: uint16 = 80, height: uint16 = 24): Pty =
    let exe = if cmd.len == 0: defaultShell() else: cmd
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

      let argv = allocCStringArray(@[exe] & @args)
      discard execvp(exe.cstring, argv)
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

else:
  type
    Pty* = object
      hpc*: HPCON       # the pseudoconsole
      inWrite*: Handle  # our end of the pipe feeding the child input
      outRead*: Handle  # our end of the pipe draining the child output
      hProcess*: Handle # signaled when the child exits; the daemon can
                        # WaitForSingleObject on it instead of fishing
                        # the exit out of the read side

  proc quoteArg*(s: string): string =
    # Minimal Windows quoting: an argument with spaces, tabs or quotes
    # gets wrapped, embedded quotes doubled. Full CRT rules are more
    # ceremony than the command lines mpx builds ever need.
    if s.len == 0:
      return "\"\""
    var plain = true
    for c in s:
      if c == ' ' or c == '\t' or c == '"':
        plain = false
        break
    if plain:
      return s
    result = "\""
    for c in s:
      if c == '"':
        result.add '"'
      result.add c
    result.add '"'

  proc openPty*(cmd: string, args: openArray[string] = [], width: uint16 = 80, height: uint16 = 24): Pty =
    let exe = if cmd.len == 0: defaultShell() else: cmd
    var size: COORD
    size.x = width.SHORT
    size.y = height.SHORT

    # Two anonymous pipes. inWrite is where we push bytes for the child,
    # outRead is where its output lands; the other two ends belong to the
    # pseudoconsole after CreatePseudoConsole takes them.
    var inRead, inWrite, outRead, outWrite: Handle
    # Inheritable, like portable-pty: conhost needs to take over these
    # ends when CreatePseudoConsole hands them across. Our own copies of
    # the consumed ends are closed right after, and the ends we keep are
    # never passed to any other child, so inheritance is harmless here.
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
                                 bInheritHandle: 1)
    if createPipe(inRead, inWrite, sa, 0) == 0 or
        createPipe(outRead, outWrite, sa, 0) == 0:
      raise newException(OSError, "CreatePipe failed: " & $getLastError())

    var hpc: HPCON
    let hr = CreatePseudoConsole(size, inRead, outWrite, 0, addr hpc)
    discard closeHandle(inRead)
    discard closeHandle(outWrite)
    if hr != 0:
      discard closeHandle(inWrite)
      discard closeHandle(outRead)
      raise newException(OSError, "CreatePseudoConsole failed: " & $hr)

    # Attribute list carrying the pseudoconsole: this is how the child
    # gets hooked to it instead of stdio handles. si lives on the heap on
    # purpose: as a stack local, CreateProcessW fails with
    # ERROR_INVALID_PARAMETER in this mingw build on Win11 26100, while
    # the same struct heap- or statically-allocated works there and a
    # plain C build with a stack struct works too.
    let si = cast[ptr STARTUPINFOEXW](alloc(sizeof(STARTUPINFOEXW)))
    zeroMem(si, sizeof(STARTUPINFOEXW))
    si[].StartupInfo.cb = int32(sizeof(STARTUPINFOEXW))
    # STARTF_USESTDHANDLES with invalid handles, exactly like the
    # pseudoconsole attach in microsoft/terminal's ConptyConnection:
    # without it, a child spawned by a parent whose own stdio is
    # redirected (pipes, not a console) inherits those redirected
    # handles and never talks to the pseudoconsole at all. The
    # pseudoconsole attribute replaces the invalid handles with the pty.
    si[].StartupInfo.dwFlags = STARTF_USESTDHANDLES
    si[].StartupInfo.hStdInput = INVALID_HANDLE_VALUE
    si[].StartupInfo.hStdOutput = INVALID_HANDLE_VALUE
    si[].StartupInfo.hStdError = INVALID_HANDLE_VALUE
    var attrSize: uint = 0
    discard InitializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
    var attrBuf = newSeq[byte](attrSize.int)
    si[].lpAttributeList = cast[LPPROC_THREAD_ATTRIBUTE_LIST](addr attrBuf[0])
    if InitializeProcThreadAttributeList(si[].lpAttributeList, 1, 0, addr attrSize) == 0 or
        UpdateProcThreadAttribute(si[].lpAttributeList, 0,
                                  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                  cast[pointer](hpc), sizeof(HPCON).uint,
                                  nil, nil) == 0:
      DeleteProcThreadAttributeList(si[].lpAttributeList)
      discard closeHandle(inWrite)
      discard closeHandle(outRead)
      ClosePseudoConsole(hpc)
      raise newException(OSError, "proc thread attribute list failed: " &
        $getLastError())

    var cmdline = quoteArg(exe)
    for a in args:
      cmdline.add ' '
      cmdline.add quoteArg(a)
    var pi = PROCESS_INFORMATION()
    # nil application name: CreateProcessW PATH-searches the first token of
    # the command line, the same deal execvp gives a bare "cmd" on posix. A
    # non-null lpApplicationName must be a real path; a bare name fails
    # with ERROR_FILE_NOT_FOUND.
    if createProcessW(nil, newWideCString(cmdline), nil, nil, 0,
                      EXTENDED_STARTUPINFO_PRESENT, nil, nil,
                      si[].StartupInfo, pi) == 0:
      DeleteProcThreadAttributeList(si[].lpAttributeList)
      discard closeHandle(inWrite)
      discard closeHandle(outRead)
      ClosePseudoConsole(hpc)
      raise newException(OSError, "CreateProcessW failed for " & exe & ": " &
        $getLastError())
    DeleteProcThreadAttributeList(si[].lpAttributeList)
    dealloc(si)

    result.hpc = hpc
    result.inWrite = inWrite
    result.outRead = outRead
    result.hProcess = pi.hProcess
    discard closeHandle(pi.hThread)

  proc setSize*(pty: Pty, width, height: uint16) =
    var size: COORD
    size.x = width.SHORT
    size.y = height.SHORT
    discard ResizePseudoConsole(pty.hpc, size)

  proc read*(pty: Pty, buf: pointer, len: int): int =
    # Blocking: the Windows daemon reads from a dedicated thread.
    var n: int32
    if readFile(pty.outRead, buf, len.int32, addr n, nil) != 0:
      return n.int
    let err = getLastError()
    if err == ERROR_BROKEN_PIPE or err == ERROR_NO_DATA:
      return 0  # the console side is gone; a posix master reports EOF too
    result = -1

  proc write*(pty: Pty, buf: pointer, len: int): int =
    var n: int32
    if writeFile(pty.inWrite, buf, len.int32, addr n, nil) != 0:
      return n.int
    result = -1

  proc close*(pty: Pty) =
    # Close our input end first: ClosePseudoConsole waits for the attached
    # child to acknowledge shutdown, and that wait ends promptly once the
    # console sees it will never get more input.
    discard closeHandle(pty.inWrite)
    ClosePseudoConsole(pty.hpc)
    discard closeHandle(pty.outRead)
    discard closeHandle(pty.hProcess)
