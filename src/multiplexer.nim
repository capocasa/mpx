import std/[os, posix, strutils]
import multiplexer/[daemon, client, protocol]

proc usage() =
  echo "Usage:"
  echo "  multiplexer daemon <session> [cmd]   # start daemon"
  echo "  multiplexer attach <session>         # attach to session"
  echo "  multiplexer new <session> [cmd]      # daemon in background + attach"
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
  else:
    usage()

when isMainModule:
  main()