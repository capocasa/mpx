import std/[os, posix, strutils, sequtils]
import mpx/[daemon, client, protocol, session]

const
  Version = staticRead("../mpx.nimble").splitLines.filterIt(it.startsWith("version"))[0].split('=')[1].strip().strip(chars={' ','"'})

proc die(code: int, msg: string) =
  stderr.writeLine "mpx: " & msg
  quit code

proc usage() =
  echo "Usage:"
  echo "  mpx daemon [session] [cmd]   # start daemon (default name: dir basename, ~ in homedir)"
  echo "  mpx attach <session>         # attach to session"
  echo "  mpx new [session] [cmd]      # daemon in background + attach"
  echo "  mpx ls                       # list sessions"
  echo "  mpx kill <session>           # kill daemon and remove socket"
  echo "  mpx --version                # show version"
  quit(2)

proc main() =
  if paramCount() < 1:
    usage()

  if paramStr(1) in ["--version", "-v"]:
    echo "mpx " & Version
    quit(0)

  let mode = paramStr(1)
  var sessionName = if paramCount() > 1: paramStr(2) else: ""
  var cmd = if paramCount() > 2: paramStr(3) else: getEnv("SHELL", "/bin/sh")

  case mode
  of "daemon", "new":
    # Disambiguate: one argument that is an existing command is the command,
    # not a session name. `mpx new htop` runs htop in an auto-numbered session.
    if sessionName.len > 0 and findExe(sessionName).len > 0:
      cmd = sessionName
      sessionName = ""
    sessionName = resolveSession(sessionName)
  of "attach", "kill":
    try:
      sessionName = requireSession(sessionName)
    except ValueError:
      usage()
  of "ls":
    discard
  else:
    usage()

  case mode
  of "daemon":
    runDaemon(sessionName, cmd)
  of "attach":
    runClient(sessionName)
  of "new":
    if isActive(sessionName):
      echo "mpx: reusing active session ", sessionName
    else:
      # Fork daemon, then attach
      let pid = fork()
      if pid == 0:
        runDaemon(sessionName, cmd)
        quit(0)
      # Give daemon time to start
      sleep(100)
    runClient(sessionName)
  of "ls":
    # walkDir, not walkFiles: sockets are not regular files
    let dir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp")) / "mpx"
    if dirExists(dir):
      for (_, f) in walkDir(dir):
        if f.endsWith(".sock"):
          echo f.extractFilename.changeFileExt("")
  of "kill":
    removeSocket(sessionName)
    removeLock(sessionName)
    # Kill daemon by matching cmdline
    for f in walkFiles("/proc/[0-9]*/cmdline"):
      try:
        let content = readFile(f)
        if "mpx" in content and "daemon" in content and sessionName in content:
          let pid = f.split('/')[2].parseInt
          discard kill(pid.Pid, SIGTERM)
          echo "killed ", pid
      except:
        discard
  else:
    usage()

when isMainModule:
  main()
