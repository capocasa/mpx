# multiplexer example: full session flow
#
# Run with: nimble example

import std/[os, osproc, strutils, posix]

putEnv("XDG_RUNTIME_DIR", "/tmp")

const
  Session = "example"
  RuntimeDir = "/tmp"

proc cleanup() =
  discard execCmd("pkill -f 'multiplexer daemon " & Session & "' 2>/dev/null")
  removeFile(RuntimeDir / "mpx" / Session & ".sock")

cleanup()

# Start daemon in background, detached
let daemon = startProcess("./multiplexer", args=["daemon", Session, "/bin/cat"],
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
let (output, _) = execCmdEx("(echo 'hello from example'; sleep 1) | timeout 3 ./multiplexer attach " & Session)
doAssert "hello from example" in output, "expected echo in output, got: " & output
echo "example: client attach and echo verified"

# Verify snapshot on second attach (should contain previous output)
let (snap, _) = execCmdEx("timeout 2 ./multiplexer attach " & Session & " < /dev/null")
doAssert "hello from example" in snap, "snapshot missing previous output"
echo "example: snapshot on reattach verified"

# Cleanup
daemon.terminate()
daemon.close()
cleanup()
echo "example: all passed"