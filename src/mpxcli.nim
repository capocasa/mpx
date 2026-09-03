import std/[os, posix]
import mpx/[daemon, client, protocol]

proc usage() =
  echo "Usage:"
  echo "  mpxcli daemon <session> [cmd]   # start daemon"
  echo "  mpxcli attach <session>         # attach to session"
  echo "  mpxcli new <session> [cmd]      # daemon in background + attach"
  echo "  mpxcli relay <host> <session>   # attach via SSH tunnel"
  quit(1)

proc main() =
  if paramCount() < 2:
    usage()
  
  let mode = paramStr(1)
  let sessionName = paramStr(2)
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
  else:
    usage()

when isMainModule:
  main()