# mpx example: full session flow
#
# Run with: nimble example

import std/[os, osproc, strutils, posix, strtabs]

putEnv("XDG_RUNTIME_DIR", "/tmp")

const
  Session = "example"
  RuntimeDir = "/tmp"

proc cleanup() =
  discard execCmd("pkill -f 'mpx daemon " & Session & "' 2>/dev/null")
  removeFile(RuntimeDir / "mpx" / Session & ".sock")

cleanup()

# Start daemon in background, detached
let daemon = startProcess("./mpx", args=["daemon", Session, "/bin/cat"],
                          options={poDaemon})
sleep(2000)  # Give daemon more time to create socket

# Check if daemon is alive
if not daemon.running:
  echo "example: daemon failed to start"
  quit(1)

# Verify socket exists (fileExists doesn't work on sockets on some systems)
var sockInfo: Stat
doAssert lstat(RuntimeDir / "mpx" / Session & ".sock", sockInfo) == 0, "socket not created"
echo "example: daemon started, socket exists"

# Attach a client, send input, capture output
let (output, _) = execCmdEx("(echo 'hello from example'; sleep 1) | timeout 3 ./mpx attach " & Session)
doAssert "hello from example" in output, "expected echo in output, got: " & output
echo "example: client attach and echo verified"

# Verify snapshot on second attach (should contain previous output)
let (snap, _) = execCmdEx("timeout 2 ./mpx attach " & Session & " < /dev/null")
doAssert "hello from example" in snap, "snapshot missing previous output: " & snap
echo "example: snapshot on reattach verified"

# Session ends when the contained program exits (here: cat sees EOF)
let (bye, _) = execCmdEx("printf 'bye\\n'; sleep 1 | timeout 3 ./mpx attach " & Session)
doAssert "bye" in bye, "expected echo of bye, got: " & bye
var dead = false
for i in 1..20:
  if not fileExists(RuntimeDir / "mpx" / Session & ".sock"):
    dead = true
    break
  sleep(250)
doAssert dead, "daemon outlived child process"
echo "example: session ends with child exit verified"

# Default session name: no name = dir basename, then a counter
let bin = getCurrentDir() / "mpx"
let workdir = getTempDir() / "mpx_example_cwd"
removeDir(workdir)
createDir(workdir)
discard startProcess(bin, args=["daemon", "/bin/cat"],
                     workingDir=workdir, options={poDaemon})
proc lsContains(name: string): bool =
  let (outp, _) = execCmdEx(bin & " ls")
  outp.contains(name)
var named = false
for i in 1..40:
  if lsContains("mpx_example_cwd"):
    named = true
    break
  sleep(250)
doAssert named, "session named after cwd missing from mpx ls"
echo "example: default session named after cwd verified"

# Second session in the same dir gets the counter suffix
discard startProcess(bin, args=["daemon", "/bin/cat"],
                     workingDir=workdir, options={poDaemon})
var counted = false
for i in 1..40:
  if lsContains("mpx_example_cwd0"):
    counted = true
    break
  sleep(250)
doAssert counted, "counter-suffixed session mpx_example_cwd0 missing from mpx ls"
echo "example: counter suffix on name collision verified"

discard execCmd("pkill -f 'mpx daemon /bin/cat' 2>/dev/null")
removeDir(workdir)

# Config: listen = host:port adds a TCP listener next to the unix socket.
# Daemon-side and client-side dirs are deliberately different so the client
# can only reach the session over TCP.
let cfgDir = getTempDir() / "mpx_example_config"
let daemonRt = getTempDir() / "mpx_example_rt"
let clientRt = getTempDir() / "mpx_example_rt_empty"
let dataDir = getTempDir() / "mpx_example_data"
removeDir(cfgDir)
removeDir(daemonRt)
removeDir(clientRt)
createDir(cfgDir / "mpx")
createDir(daemonRt)
createDir(clientRt)
writeFile(cfgDir / "mpx" / "config", "listen = 127.0.0.1:4590\nlog = true\n")

discard startProcess(bin, args=["daemon", "tcpdemo", "/bin/cat"],
                     env={"XDG_CONFIG_HOME": cfgDir,
                          "XDG_RUNTIME_DIR": daemonRt,
                          "XDG_DATA_HOME": dataDir}.newStringTable,
                     options={poDaemon})
var tcpUp = false
for i in 1..40:
  for f in walkFiles(dataDir / "mpx" / "*.log"):
    if "listening on tcp" in readFile(f):
      tcpUp = true
  if tcpUp:
    break
  sleep(250)
doAssert tcpUp, "daemon never logged its tcp listener"
echo "example: config file enables tcp listener verified"

# Attach with the session socket hidden from the client: goes over TCP
let (tcpOut, _) = execCmdEx("(echo 'hello over tcp'; sleep 1) | timeout 3 env XDG_CONFIG_HOME=" &
                            cfgDir & " XDG_RUNTIME_DIR=" & clientRt & " " & bin & " attach tcpdemo")
doAssert "hello over tcp" in tcpOut, "tcp attach failed, got: " & tcpOut
echo "example: tcp attach by session name verified"

# Wrong session name is rejected
let (errOut, exitCode) = execCmdEx("(echo x; sleep 1) | timeout 3 env XDG_CONFIG_HOME=" &
                                   cfgDir & " XDG_RUNTIME_DIR=" & clientRt & " " & bin &
                                   " attach nosuchsession")
doAssert exitCode != 0, "wrong session name should fail, got: " & errOut
echo "example: wrong session name rejected verified"

discard execCmd("pkill -f 'mpx daemon tcpdemo' 2>/dev/null")
removeDir(cfgDir)
removeDir(daemonRt)
removeDir(clientRt)

# Config file must not exist by default (no state written unless asked for)
doAssert not fileExists(cfgDir), "example config cleanup failed"

cleanup()
echo "example: all passed"
