# mpx example: full session flow
#
# Run with: nimble example

import std/[os, osproc, strutils, posix]

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

# Verify socket exists (fileExists doesn't work for sockets on some systems)
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

# Default session name: no name = cwd basename, then a counter
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

# Cleanup
cleanup()
echo "example: all passed"
