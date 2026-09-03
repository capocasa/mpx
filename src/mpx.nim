import std/[os, posix, strutils, sequtils]
import multiplexer/[daemon, client, protocol]

const
  Version = staticRead("../multiplexer.nimble").splitLines.filterIt(it.startsWith("version"))[0].split('=')[1].strip().strip(chars={' ','"'})

proc die(code: int, msg: string) =
  stderr.writeLine "mpx: " & msg
  quit code

proc usage() =
  echo "Usage:"
  echo "  mpx daemon <session> [cmd]   # start daemon"
  echo "  mpx attach <session>         # attach to session"
  echo "  mpx new <session> [cmd]      # daemon in background + attach"
  echo "  mpx relay <host> <session>   # attach via SSH tunnel"
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
  
  if paramStr(1) in ["ls", "kill"]:
    if paramCount() < 2 and paramStr(1) == "kill":
      usage()
  elif paramCount() < 2:
    usage()
  
  let mode = paramStr(1)
  let sessionName = if paramCount() > 1: paramStr(2) else: ""
  let cmd = if paramCount() > 2: paramStr(3) else: getEnv("SHELL", "/bin/sh")
  
  case mode
  of "daemon":
    runDaemon(sessionName, cmd)
  of "attach":
    runClient(sessionName)
  of "new":
    # Fork daemon, then attach
    let pid = fork()
    if pid == 0:
      runDaemon(sessionName, cmd)
      quit(0)
    else:
      # Give daemon time to start
      sleep(100)
      runClient(sessionName)
  of "relay":
    if paramCount() < 3:
      usage()
    let host = paramStr(2)
    let remoteSession = paramStr(3)
    # Create local socket path for forwarded connection
    let localPath = "/tmp/mpx_relay_" & remoteSession & ".sock"
    let remotePath = socketPath(remoteSession)
    # Remove stale socket
    if fileExists(localPath):
      removeFile(localPath)
    # Start SSH tunnel in background
    let tunnelPid = fork()
    if tunnelPid == 0:
      discard execvp("ssh", @["ssh", "-N", "-L", localPath & ":" & remotePath, host].allocCStringArray)
      quit(1)
    # Give tunnel time to establish
    sleep(500)
    # Attach to forwarded socket
    runClientAt(localPath)
    # Cleanup: kill tunnel
    discard kill(tunnelPid, SIGTERM)
    if fileExists(localPath):
      removeFile(localPath)
  of "ls":
    let dir = getEnv("XDG_RUNTIME_DIR", getEnv("TMPDIR", "/tmp")) / "mpx"
    if dirExists(dir):
      for f in walkFiles(dir / "*.sock"):
        echo f.extractFilename.changeFileExt("")
  of "kill":
    removeSocket(sessionName)
    # Kill daemon by matching cmdline
    let pidFile = "/proc"
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
