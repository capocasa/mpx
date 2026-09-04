import std/[os, posix, strutils, sequtils]
import mpx/[daemon, client, protocol, session, cli, runtime]

const
  Version = staticRead("../mpx.nimble").splitLines.filterIt(it.startsWith("version"))[0].split('=')[1].strip().strip(chars={' ', '"'})

  UsageText = """
Usage:
  mpx [options] daemon [session] [cmd]  # start daemon (default name: dir basename, ~ in homedir)
  mpx [options] attach <session>        # attach to session
  mpx [options] new [session] [cmd]     # daemon in background + attach
  mpx ls                                # list sessions
  mpx kill <session>                    # kill daemon and remove socket

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

proc pathPresent(p: string): bool =
  # fileExists is false for sockets; lstat only says the path is there
  var st: Stat
  lstat(p.cstring, st) == 0

proc cleanSessionFiles(sessionName: string) =
  for ext in [".sock", ".lock", ".pid"]:
    let p = socketPath(sessionName).changeFileExt(ext)
    if pathPresent(p):
      try:
        removeFile(p)
      except OSError:
        discard

proc cleanStale(sessionName: string) =
  var stale = false
  for ext in [".sock", ".lock", ".pid"]:
    if pathPresent(socketPath(sessionName).changeFileExt(ext)):
      stale = true
      break
  cleanSessionFiles(sessionName)
  die((if stale: "cleaned stale socket, no daemon for session: " else: "no such session: ") & sessionName)

proc main() =
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

  if opts.sessions.len < 1:
    die("missing command. " & UsageHint)

  let mode = opts.sessions[0]
  var sessionName = if opts.sessions.len > 1: opts.sessions[1] else: ""
  var cmd = if opts.sessions.len > 2: opts.sessions[2] else: getEnv("SHELL", "/bin/sh")

  case mode
  of "daemon", "new":
    # Disambiguate: one argument that is an existing command is the command,
    # not a session name. `mpx new htop` runs htop in an auto-numbered session.
    if sessionName.len > 0 and findExe(sessionName).len > 0:
      cmd = sessionName
      sessionName = ""
    sessionName = resolveSession(sessionName)
  of "attach", "kill":
    if sessionName.len == 0:
      die(mode & ": session name required")
  of "ls":
    discard
  else:
    die("unknown command: " & mode & ". " & UsageHint)

  let cfg = toConfig(opts)

  case mode
  of "daemon":
    try:
      runDaemon(sessionName, cmd, cfg)
    except CatchableError:
      die(getCurrentExceptionMsg())
  of "attach":
    try:
      runClient(sessionName, cfg)
    except CatchableError:
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
      let pid = fork()
      if pid == 0:
        discard execv(exe.cstring, allocCStringArray(args))
        die("exec failed: " & exe)
      var status: cint = 0
      discard waitpid(pid, status, 0)
      if not isActive(sessionName):
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
        if f.endsWith(".sock"):
          echo f.extractFilename.changeFileExt("")
  of "kill":
    if not isActive(sessionName):
      # Daemon is gone; leftover files are stale garbage, clean them
      cleanStale(sessionName)
    let pid = daemonPid(sessionName)
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
