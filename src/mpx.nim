import std/[os, strutils, sequtils]
import mpx/[daemon, client, protocol, session, cli, runtime, pty]

when defined(windows):
  import mpx/win
else:
  import std/posix

const
  Version = staticRead("../mpx.nimble").splitLines.filterIt(it.startsWith("version"))[0].split('=')[1].strip().strip(chars={' ', '"'})

  UsageText = """
Usage:
  mpx [options] [session] [cmd]        # default action: session in background + attach
  mpx [options] daemon [session] [cmd]  # start daemon in foreground (name defaults to dir basename, ~ in homedir)
  mpx [options] attach [session]       # attach to a session (default: oldest)
  mpx ls                               # list sessions
  mpx kill <session>                   # kill daemon and remove socket

Any unambiguous command prefix works: mpx d, mpx at, mpx ne, mpx l, mpx ki.

Options:
"""

proc help() =
  echo(UsageText)
  for (flag, text) in FlagDocs:
    echo flag
    if text.len > 0:
      echo "      " & text
  quit(0)

proc die*(msg: string) =
  stderr.writeLine "mpx: " & msg
  quit(1)

proc cleanStale(sessionName: string) =
  var stale = false
  for ext in [EndpointExt, ".lock", ".pid"]:
    if pathPresent(socketPath(sessionName).changeFileExt(ext)):
      stale = true
      break
  cleanSessionFiles(sessionName)
  die((if stale: "cleaned stale socket, no daemon for session: " else: "no such session: ") & sessionName)

proc main() =
  when defined(windows):
    initWinsock()
  var opts: Opts
  try:
    opts = parseCliArgs(commandLineParams())
  except ValueError:
    die(getCurrentExceptionMsg())

  if opts.help:
    help()
  if opts.version:
    echo "mpx " & Version
    quit(0)

  # Commands resolve by unambiguous prefix. A word that matches no
  # command at all starts a `new` with the word as its first argument,
  # so `mpx htop` runs htop in a session and bare `mpx` starts a shell.
  var mode = "new"
  var rest: seq[string]
  if opts.sessions.len > 0:
    let matches = matchModes(opts.sessions[0])
    if matches.len == 1:
      mode = matches[0]
      rest = opts.sessions[1 ..^ 1]
    elif matches.len > 1:
      die("ambiguous command: " & opts.sessions[0] & " (" & matches.join(", ") & "). " & UsageHint)
    else:
      rest = opts.sessions

  var sessionName = if rest.len > 0: rest[0] else: ""
  var cmd = if rest.len > 1: rest[1] else: defaultShell()
  var cmdArgs: seq[string]

  case mode
  of "daemon", "new":
    # Disambiguate: one argument that is an existing command is the command,
    # not a session name. `mpx new htop` runs htop in an auto-numbered session.
    # Everything after the command rides along as its arguments: `mpx new
    # sleep 30` execs `sleep 30`, not a bare `sleep` that dies at once.
    if sessionName.len > 0 and findExe(sessionName).len > 0:
      cmd = sessionName
      cmdArgs = if rest.len > 1: rest[1 ..^ 1] else: @[]
      sessionName = ""
    else:
      cmdArgs = if rest.len > 2: rest[2 ..^ 1] else: @[]
    sessionName = resolveSession(sessionName)
  of "attach", "kill":
    if sessionName.len == 0:
      if mode == "attach":
        sessionName = oldestSession()
        if sessionName.len == 0:
          die("attach: no active sessions")
      else:
        die("kill: session name required")
  of "ls":
    discard
  else:
    die("unknown command: " & mode & ". " & UsageHint)

  let cfg = toConfig(opts)

  case mode
  of "daemon":
    try:
      # Endpoint before pty: the socket is the daemon's only interface,
      # and a client that connects while openPty is still spawning the
      # program waits in the listen backlog instead of behind the spawn.
      let endpoint = bindEndpoint(sessionName, cfg)
      runDaemon(sessionName, cmd & (if cmdArgs.len > 0: " " & cmdArgs.join(" ") else: ""),
                cfg, endpoint, newSession(sessionName, cmd, cmdArgs))
    except CatchableError:
      # Whatever runDaemon managed to claim (lock, port, pid) is
      # garbage now; a name must not stay burned because a daemon died
      # before its cleanup path ran.
      cleanSessionFiles(sessionName)
      die(getCurrentExceptionMsg())
  of "attach":
    try:
      runClient(sessionName, cfg)
    except CatchableError:
      # A SIGKILLed or crashed daemon leaves socket/pid/lock behind;
      # connecting then fails with ECONNREFUSED. Clean the leftovers so
      # the error names the session, not the socket path.
      if not isActive(sessionName):
        cleanStale(sessionName)  # dies: cleaned stale socket / no such session
      die(getCurrentExceptionMsg())
  of "new":
    if isActive(sessionName):
      stderr.writeLine "mpx: reusing active session " & sessionName
    else:
      # Re-exec as daemon: preserves argv[0] for kill-by-matching and
      # avoids forked-thread issues in the client
      let exe = getAppFilename()
      var args = @[exe, "daemon", sessionName, cmd]
      if cfg.listen.len > 0:
        args.add(["-l", cfg.listen])
      if opts.port != 0:
        args.add(["-p", $opts.port])
      if opts.log:
        args.add("--log")
      if cmdArgs.len > 0:
        args.add("--")
        args.add(cmdArgs)
      when defined(windows):
        # Same detachment the posix fork path earns with setsid: no
        # console at all, free of any job the spawning terminal put us
        # in, its own group so a Ctrl-C in the client cannot reach it.
        var si = STARTUPINFO()
        si.cb = int32(sizeof(STARTUPINFO))
        var pi = PROCESS_INFORMATION()
        let cmdline = newWideCString(args.mapIt(quoteArg(it)).join(" "))
        var flags = DETACHED_PROCESS or CREATE_BREAKAWAY_FROM_JOB or
                    CREATE_NEW_PROCESS_GROUP
        if createProcessW(newWideCString(exe), cmdline,
                          nil, nil, 0, flags, nil, nil, si, pi) == 0:
          # A job that denies breakaway (CI runners put steps in one)
          # fails the combined call; without the flag the daemon is
          # still console-free and in its own group, just not out of
          # the job.
          flags = flags and not CREATE_BREAKAWAY_FROM_JOB
          if createProcessW(newWideCString(exe), cmdline,
                            nil, nil, 0, flags, nil, nil, si, pi) == 0:
            die("CreateProcessW failed for daemon: " & $getLastError())
        discard closeHandle(pi.hThread)
        # The daemon runs in the foreground forever; wait for its port
        # file, not for the process. A signaled handle catches an early
        # exit (bad cmd, bind failure) so it surfaces instead of hanging
        # until the timeout.
        # Readiness backoff: a healthy daemon binds in a few ms, so poll
        # finely at first (a fixed 50ms tick parked every cold start on a
        # full tick), then back off so a wedged start cannot spin the CPU
        # for the whole 5s window.
        var ready = false
        var waitMs = 2
        var waitedMs = 0
        while waitedMs < 5000:
          if isActive(sessionName):
            ready = true
            break
          if waitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0:
            break
          sleep(waitMs)
          inc waitedMs, waitMs
          waitMs = min(waitMs * 2, 50)
        discard closeHandle(pi.hProcess)
        if not ready:
          # The claimed name would otherwise be skipped by every future
          # auto-naming pass: resolveSession honors the lock file.
          cleanSessionFiles(sessionName)
          die("daemon failed to start: " & sessionName)
      else:
        let pid = fork()
        if pid == 0:
          # Detach from the client's session: the daemon must survive the
          # terminal closing (SIGHUP to the foreground process group)
          discard setsid()
          # And from its fds: a daemon holding the spawning terminal or a
          # script's pipes open keeps ssh logouts and pipe readers waiting.
          # The socket is the daemon's only interface.
          let nfd = posix.open("/dev/null", O_RDWR)
          if nfd >= 0:
            discard dup2(nfd, 0)
            discard dup2(nfd, 1)
            discard dup2(nfd, 2)
            if nfd > 2:
              discard posix.close(nfd)
          for i in 3 .. 1023:
            discard posix.close(cint(i))
          discard execv(exe.cstring, allocCStringArray(args))
          die("exec failed: " & exe)
        # The daemon runs in the foreground forever; wait for its socket,
        # not for the process. WNOHANG catches an early exit (bad cmd, bind
        # failure) so it surfaces instead of hanging until the timeout.
        # Readiness backoff: a healthy daemon binds in a few ms, so poll
        # finely at first (a fixed 50ms tick parked every cold start on a
        # full tick), then back off so a wedged start cannot spin the CPU
        # for the whole 5s window.
        var ready = false
        var status: cint = 0
        var waitMs = 2
        var waitedMs = 0
        while waitedMs < 5000:
          if isActive(sessionName):
            ready = true
            break
          if posix.waitpid(pid, status, WNOHANG) == pid:
            break
          sleep(waitMs)
          inc waitedMs, waitMs
          waitMs = min(waitMs * 2, 50)
        if not ready:
          cleanSessionFiles(sessionName)
          die("daemon failed to start: " & sessionName)
    try:
      runClient(sessionName, cfg)
    except CatchableError:
      die(getCurrentExceptionMsg())
  of "ls":
    # walkDir, not walkFiles: sockets are not regular files
    let dir = mpxDir()
    if dirExists(dir):
      for (_, f) in walkDir(dir):
        if f.endsWith(EndpointExt):
          let name = f.extractFilename.changeFileExt("")
          # A killed daemon can leave a socket behind: list only sessions
          # that still answer
          if isActive(name):
            echo name
  of "kill":
    if not isActive(sessionName):
      # Daemon is gone; leftover files are stale garbage, clean them
      cleanStale(sessionName)
    let pid = daemonPid(sessionName)
    when defined(windows):
      # TerminateProcess is blunt, but a detached daemon has no console
      # to post a graceful close to; the sweep below is the cleanup a
      # graceful exit would have done.
      var killed = false
      if pid != 0:
        let h = openProcess(PROCESS_TERMINATE, 0, pid.DWORD)
        if h != 0:
          killed = terminateProcess(h, 1) != 0
          discard closeHandle(h)
      if killed:
        echo "killed ", pid
        sleep(100)
        cleanSessionFiles(sessionName)
      else:
        die("no daemon found for session: " & sessionName)
    else:
      if pid != 0 and posix.kill(pid.Pid, SIGTERM) == 0:
        echo "killed ", pid
        # Daemon cleanup runs on graceful exit; sweep whatever remains so
        # a crashed daemon leaves nothing behind
        sleep(100)
        cleanSessionFiles(sessionName)
      else:
        die("no daemon found for session: " & sessionName)
  else:
    die("unknown command: " & mode & ". " & UsageHint)

when isMainModule:
  main()
