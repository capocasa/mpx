# mpx example: full session flow
#
# Run with: nimble example

import std/[os, osproc, strutils, posix, strtabs, streams, times]

putEnv("XDG_RUNTIME_DIR", "/tmp")

const
  Session = "example"
  RuntimeDir = "/tmp"

proc sockExists(p: string): bool =
  # fileExists is false for sockets: lstat only says the path is there
  var st: Stat
  lstat(p.cstring, st) == 0

proc cleanup() =
  discard execCmd("pkill -f 'mpx daemon " & Session & "' 2>/dev/null")
  discard execCmd("pkill -f 'mpx daemon bashdemo' 2>/dev/null")
  discard execCmd("pkill -f 'mpx daemon startnc' 2>/dev/null")
  for s in ["zdemo", "shdemo", "wsdemo", "eodemo", "pastemo"]:
    discard execCmd("pkill -f 'mpx daemon " & s & "' 2>/dev/null")
    removeFile(RuntimeDir / "mpx" / s & ".sock")
  removeFile(RuntimeDir / "mpx" / Session & ".sock")
  removeFile(RuntimeDir / "mpx" / "bashdemo.sock")
  removeFile(RuntimeDir / "mpx" / "startnc.sock")

proc runTimed(cmd: string, secs: int,
              workingDir = ""): tuple[output: string, exitCode: int] =
  ## GNU coreutils `timeout` is not on macOS; the deadline lives here.
  ## A hang is killed, and grandchildren die on their own pipe EOFs.
  let p = startProcess("/bin/sh", args = ["-c", cmd],
                       workingDir = workingDir,
                       options = {poStdErrToStdout})
  discard p.waitForExit(secs * 1000)
  if p.running:
    p.kill()
  result.output = p.outputStream.readAll()
  result.exitCode = p.peekExitCode()
  p.close()

cleanup()

# Start daemon in background, detached
let daemon = startProcess("./mpx", args=["daemon", Session, "/bin/cat"],
                          options={poDaemon})
sleep(2000)  # Give daemon more time to create socket

# Check if daemon is alive
if not daemon.running:
  echo "example: daemon failed to start"
  quit(1)

# Verify socket exists (fileExists doesn't work on sockets)
doAssert sockExists(RuntimeDir / "mpx" / Session & ".sock"), "socket not created"
echo "example: daemon started, socket exists"

# Attach a client, send input, capture output
let (output, _) = runTimed("(echo 'hello from example'; sleep 1) | ./mpx attach " & Session, 3)
doAssert "hello from example" in output, "expected echo in output, got: " & output
echo "example: client attach and echo verified"

# The attach that rode session start does not clear the screen: the
# terminal keeps its scrollback, the session just continues below it.
doAssert "\x1b[2J" notin output, "start attach cleared the screen"
echo "example: start attach leaves the screen alone verified"

# First attach to a session whose program already printed: the model is
# replayed, still without a clear, so pre-attach output survives below
# whatever was on the terminal.
discard startProcess("./mpx", args=["daemon", "startnc", "sh", "--", "-c", "echo ready; cat"],
                     options={poDaemon})
var ncUp = false
for i in 1..40:
  if sockExists(RuntimeDir / "mpx" / "startnc.sock"):
    ncUp = true
    break
  sleep(250)
doAssert ncUp, "startnc daemon never started"
sleep(500)  # the echo must be in the model before the attach lands
let (nc, _) = runTimed("./mpx attach startnc < /dev/null", 2)
doAssert "ready" in nc, "start attach lost pre-attach output"
doAssert "\x1b[2J" notin nc, "start attach cleared the screen"
echo "example: start attach replays without clearing verified"

# Verify snapshot on second attach (should contain previous output)
let (snap, _) = runTimed("./mpx attach " & Session & " < /dev/null", 2)
doAssert "hello from example" in snap, "snapshot missing previous output: " & snap
echo "example: snapshot on reattach verified"

# A reattach is not a start: the full repaint clears first
doAssert "\x1b[2J" in snap, "reattach should clear and repaint"
echo "example: reattach clears and repaints verified"

discard execCmd("./mpx kill startnc 2>/dev/null")

# Session ends when the contained program exits: an `exit` typed into the
# shell ends bash, the daemon sees PTY EOF, and cleanup removes the socket.
# (The cat session above deliberately outlives its clients: detach-and-
# reattach is the point of a multiplexer.)
let bin = getCurrentDir() / "mpx"
discard startProcess(bin, args=["daemon", "bashdemo", "/bin/bash"],
                     options={poDaemon})
var bashUp = false
for i in 1..40:
  if sockExists(RuntimeDir / "mpx" / "bashdemo.sock"):
    bashUp = true
    break
  sleep(250)
doAssert bashUp, "bashdemo daemon never started"
let (bye, _) = runTimed("(echo 'exit'; sleep 1) | ./mpx attach bashdemo", 5)
doAssert "exit" in bye, "expected echo of exit, got: " & bye
var dead = false
for i in 1..20:
  if not sockExists(RuntimeDir / "mpx" / "bashdemo.sock"):
    dead = true
    break
  sleep(250)
doAssert dead, "daemon outlived child process"
echo "example: session ends with child exit verified"

# Default session name: no name = dir basename, then a counter
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

# Signals run daemon cleanup: SIGTERM leaves no socket/pid/lock behind.
# SIGKILL cannot run anything; the next attach cleans up and says so
# instead of printing a raw socket path.
let sigRt = getTempDir() / "mpx_example_sig"
removeDir(sigRt)
createDir(sigRt)
proc startDaemonIn(rt, session: string): Process =
  startProcess(bin, args=["daemon", session, "/bin/cat"],
               env={"XDG_RUNTIME_DIR": rt}.newStringTable,
               options={poDaemon})

proc waitForSession(rt, session: string): int =
  # The pid file is written before the socket is bound: waiting for the
  # socket means the daemon is fully up and serving
  for i in 1..40:
    if sockExists(rt / "mpx" / (session & ".sock")):
      return readFile(rt / "mpx" / (session & ".pid")).strip.parseInt
    sleep(250)
  doAssert false, "daemon never created its socket"

discard startDaemonIn(sigRt, "sigdemo")
let termPid = waitForSession(sigRt, "sigdemo")
discard posix.kill(termPid.Pid, SIGTERM)
var termClean = false
for i in 1..40:
  if not sockExists(sigRt / "mpx" / "sigdemo.sock"):
    termClean = true
    break
  sleep(250)
doAssert termClean, "SIGTERM left the socket behind"
echo "example: SIGTERM runs daemon cleanup verified"

discard startDaemonIn(sigRt, "k9demo")
let k9Pid = waitForSession(sigRt, "k9demo")
discard posix.kill(k9Pid.Pid, SIGKILL)
sleep(300)
doAssert sockExists(sigRt / "mpx" / "k9demo.sock"), "SIGKILL should leave the socket"
let (staleOut, staleCode) = runTimed("env XDG_RUNTIME_DIR=" & sigRt &
                                      " " & bin & " attach k9demo < /dev/null 2>&1", 3)
doAssert staleCode != 0, "attach to a dead daemon should fail"
doAssert "cleaned stale socket" in staleOut,
         "expected stale-socket cleanup message, got: " & staleOut
doAssert not sockExists(sigRt / "mpx" / "k9demo.sock"), "attach should remove stale files"
echo "example: attach cleans up after a SIGKILLed daemon verified"
removeDir(sigRt)

# A daemon that dies before it binds (command not found) fails the client
# cleanly and leaves no half-claimed name behind
let failRt = getTempDir() / "mpx_example_fail"
removeDir(failRt)
createDir(failRt)
let (failOut, failRc) = runTimed("env XDG_RUNTIME_DIR=" & failRt & " " & bin &
                                  " new faildemo /nonexistent 2>&1", 12)
doAssert failRc != 0, "new with a dead-on-arrival command should fail"
# Either clean failure is right, and which one lands is a race: the
# daemon may die before the client's readiness poll (startup failure)
# or a beat later, mid-attach (session ended).
doAssert "daemon failed to start" in failOut or "session ended" in failOut,
         "expected a clean failure, got: " & failOut
for ext in [".sock", ".lock", ".pid"]:
  doAssert not sockExists(failRt / "mpx" / ("faildemo" & ext)),
          "failed start left " & ext & " behind"
echo "example: failed new leaves no session files verified"
removeDir(failRt)

# A hard-killed daemon's name must not burn: the next auto-named claim
# reclaims the garbage instead of marching a counter suffix
let reclaimRt = getTempDir() / "mpx_example_reclaim"
let reclaimHome = getTempDir() / "mpx_example_reclaimhome"
let burnDir = reclaimHome / "burnname"  # basename is the name to reclaim
removeDir(reclaimRt)
removeDir(reclaimHome)
createDir(burnDir)
discard startProcess(bin, args=["daemon", "burnname", "/bin/cat"],
                     env={"XDG_RUNTIME_DIR": reclaimRt}.newStringTable,
                     options={poDaemon})
let burnPid = waitForSession(reclaimRt, "burnname")
discard posix.kill(burnPid.Pid, SIGKILL)
sleep(2200)  # the reclaim grace window must see the claim as old
doAssert sockExists(reclaimRt / "mpx" / "burnname.sock"),
         "SIGKILL should leave the socket for the reclaim to sweep"
let (reclaimOut, reclaimRc) = runTimed(
    "(sleep 1) | env XDG_RUNTIME_DIR=" & reclaimRt & " " & bin &
    " 2>&1 > /dev/null", 10, burnDir)
doAssert reclaimRc == 0, "auto-named new over garbage failed: " & reclaimOut
let (reclaimLs, _) = execCmdEx("env XDG_RUNTIME_DIR=" & reclaimRt & " " & bin & " ls")
proc lsHas(name: string): bool =
  for l in reclaimLs.splitLines:
    if l.strip == name:
      return true
  false
doAssert lsHas("burnname"),
         "reclaimed session missing from ls: " & reclaimLs
doAssert not lsHas("burnname0"),
         "name marched to a counter instead of being reclaimed: " & reclaimLs
echo "example: killed daemon's name is reclaimed, not counted verified"
discard execCmdEx("env XDG_RUNTIME_DIR=" & reclaimRt & " " & bin & " ki burnname")
removeDir(reclaimRt)
removeDir(reclaimHome)

# The auto name can BE an existing command (a session named `cat` started
# in a directory called cat): `new` re-execs the daemon as
# `mpx daemon cat -- /bin/cat`, and the daemon must not re-guess
# name-vs-command, or it runs mpx itself in the pty, binds a counter
# name, and the client times out on a session that never appeared.
let collideRoot = getTempDir() / "mpx_ex_collide"
let collideDir = collideRoot / "cat"
removeDir(collideRoot)
createDir(collideDir)
for ext in [".sock", ".lock", ".pid"]:
  removeFile(RuntimeDir / "mpx" / "cat" & ext)
let (collideOut, _) = runTimed("(echo 'collide works'; sleep 1) | " & bin &
                               " /bin/cat", 6, workingDir = collideDir)
doAssert "collide works" in collideOut,
         "session named like a command failed: " & collideOut
doAssert sockExists(RuntimeDir / "mpx" / "cat.sock"),
         "colliding session name never bound its socket: " & collideOut
doAssert not sockExists(RuntimeDir / "mpx" / "cat0.sock"),
         "colliding session name marched to a counter: " & collideOut
echo "example: session named like a command keeps its name verified"
discard execCmdEx(bin & " kill cat 2>/dev/null")
removeDir(collideRoot)

# Commands carry their arguments, and `--` guards a command's own
# flags from mpx's: `sh -c ...` reaches the pty intact
discard startProcess(bin, args=["daemon", "multword", "--",
                               "/bin/sh", "-c", "echo multwordmark; exec cat"],
                     options={poDaemon})
var multUp = false
for i in 1..40:
  if sockExists(RuntimeDir / "mpx" / "multword.sock"):
    multUp = true
    break
  sleep(250)
doAssert multUp, "multword daemon never started"
let (multOut, _) = runTimed("(sleep 1) | ./mpx attach multword", 5)
doAssert "multwordmark" in multOut,
         "command arguments were dropped: " & multOut
echo "example: command arguments passed through verified"
discard execCmdEx(bin & " kill multword")

# A bare command owns all of argv after it: no mode word means the dash
# args belong to the command, not to mpx (`mpx 3code -r` shape)
let bareRt = getTempDir() / "mpxexb"
let bareDir = getTempDir() / "mpx_exbare"
removeDir(bareRt)
removeDir(bareDir)
createDir(bareDir)
let (bareCmdOut, bareCmdRc) = runTimed("(sleep 1) | env XDG_RUNTIME_DIR=" & bareRt &
                                        " " & bin & " sh -c 'echo bareflagmark; exec cat'" &
                                        " 2>&1 > /dev/null", 5, bareDir)
doAssert bareCmdRc == 0, "bare command with flags failed: " & bareCmdOut
let (bareFlagOut, _) = runTimed("(sleep 1) | env XDG_RUNTIME_DIR=" & bareRt &
                               " " & bin & " attach mpx_exbare", 5)
doAssert "bareflagmark" in bareFlagOut,
         "bare command's -c never reached the program: " & bareFlagOut
echo "example: bare command with its own flags verified"
discard execCmdEx("env XDG_RUNTIME_DIR=" & bareRt & " " & bin & " kill mpx_exbare")
removeDir(bareRt)
removeDir(bareDir)

# The default action is `new`: bare `mpx` starts a session named after
# the directory and attaches to it. Commands work by unambiguous prefix,
# and `attach` with no name picks the oldest live session.
let defRt = getTempDir() / "mpxexd"
let defDir = getTempDir() / "mpx_exdef"
proc defEnv(): string = "env XDG_RUNTIME_DIR=" & defRt
removeDir(defRt)
removeDir(defDir)
createDir(defDir)

# The spawned daemon outlives the client and must not hold the output
# pipe open: send its inherited stdio to /dev/null
# stderr comes back to the capture so failures speak; stdout is
# discarded to keep shell banners out of bareOut
let (bareOut, bareRc) = runTimed("(sleep 1) | " & defEnv() & " " & bin &
                                  " 2>&1 > /dev/null", 5, defDir)
doAssert bareRc == 0, "bare mpx failed: " & bareOut
let (defLs, _) = execCmdEx(defEnv() & " " & bin & " l")
doAssert "mpx_exdef" in defLs,
         "bare mpx did not start a cwd-named session: " & defLs
echo "example: bare mpx starts a session named after the cwd verified"

# Seed the old session with distinctive output, then start a younger one
let (seedOut, _) = runTimed("(echo 'echo OLDSESS'; sleep 1) | " &
                            defEnv() & " " & bin & " at mpx_exdef", 5)
doAssert "OLDSESS" in seedOut, "could not seed the old session: " & seedOut
discard startProcess(bin, args=["d", "youngdemo", "/bin/cat"],
                     env={"XDG_RUNTIME_DIR": defRt}.newStringTable,
                     options={poDaemon})
discard waitForSession(defRt, "youngdemo")
let (youngOut, _) = runTimed("(echo 'hello young'; sleep 1) | " &
                             defEnv() & " " & bin & " at youngdemo", 5)
doAssert "hello young" in youngOut, "prefix attach to youngdemo failed: " & youngOut

# No-name attach lands on the older session: its scrollback, not the
# younger session's, comes back in the snapshot
let (oldestOut, _) = runTimed("(sleep 1) | " & defEnv() & " " & bin & " at", 5)
doAssert "OLDSESS" in oldestOut, "no-name attach missed the oldest session: " & oldestOut
doAssert "hello young" notin oldestOut,
       "no-name attach went to the younger session: " & oldestOut
echo "example: attach with no name picks the oldest session verified"

# Prefixes drive kill too, and the sessions go away
let (_, killOld) = execCmdEx(defEnv() & " " & bin & " ki mpx_exdef")
let (_, killYoung) = execCmdEx(defEnv() & " " & bin & " ki youngdemo")
doAssert killOld == 0 and killYoung == 0, "prefix kill failed"
let (afterKill, _) = execCmdEx(defEnv() & " " & bin & " l")
doAssert "youngdemo" notin afterKill and "mpx_exdef" notin afterKill
echo "example: command prefixes verified"

# No-name attach with nothing alive is a clean error
let (noneOut, _) = runTimed(defEnv() & " " & bin & " at 2>&1", 3)
doAssert "no active sessions" in noneOut, "expected a clean no-sessions error: " & noneOut
echo "example: attach with no live sessions errors cleanly verified"
removeDir(defRt)
removeDir(defDir)

discard execCmd("pkill -f 'mpx daemon /bin/cat' 2>/dev/null")
removeDir(workdir)

# TCP: -l host:port adds a TCP listener next to the unix socket.
# Daemon-side and client-side runtime dirs are deliberately different so the
# client can only reach the session over TCP.
let daemonRt = getTempDir() / "mpx_example_rt"
let clientRt = getTempDir() / "mpx_example_rt_empty"
let dataDir = getTempDir() / "mpx_example_data"
removeDir(daemonRt)
removeDir(clientRt)
removeDir(dataDir)
createDir(daemonRt)
createDir(clientRt)

discard startProcess(bin, args=["daemon", "tcpdemo", "/bin/cat", "--log",
                                 "-l", "127.0.0.1:4590"],
                     env={"XDG_RUNTIME_DIR": daemonRt,
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
echo "example: -l flag enables tcp listener verified"

# Attach with the session socket hidden from the client: goes over TCP
let (tcpOut, _) = runTimed("(echo 'hello over tcp'; sleep 1) | env XDG_RUNTIME_DIR=" &
                            clientRt & " " & bin & " attach tcpdemo -l 127.0.0.1:4590", 3)
doAssert "hello over tcp" in tcpOut, "tcp attach failed, got: " & tcpOut
echo "example: tcp attach by session name verified"

# Wrong session name is rejected
let (errOut, exitCode) = runTimed("(echo x; sleep 1) | env XDG_RUNTIME_DIR=" &
                                   clientRt & " " & bin &
                                   " attach nosuchsession -l 127.0.0.1:4590", 3)
doAssert exitCode != 0, "wrong session name should fail, got: " & errOut
echo "example: wrong session name rejected verified"

# Flags are validated: junk values must fail, not be guessed around
let (_, badFlag) = execCmdEx(bin & " daemon tcpdemo -l junk 2>&1")
doAssert badFlag != 0, "-l junk should fail"
let (_, badPort) = execCmdEx(bin & " daemon tcpdemo -p 0 2>&1")
doAssert badPort != 0, "-p 0 should fail"
echo "example: invalid flags rejected verified"

discard execCmd("pkill -f 'mpx daemon tcpdemo' 2>/dev/null")
removeDir(daemonRt)
removeDir(clientRt)
removeDir(dataDir)

# ----------------------------------------------------------------------
# Key handling: every mpx shortcut, verified on a real tty. Keys only
# mean what they mean on a terminal, so the client under test runs under
# an interactive bash on a pty of its own: controlling tty, own session,
# a real shell's job control -- the containing shell mpx must return to.

type
  HWinsize {.importc: "struct winsize", header: "<sys/ioctl.h>", final, pure.} = object
    ws_row, ws_col: uint16

when defined(macosx) or defined(freebsd) or defined(netbsd) or defined(openbsd) or defined(dragonfly):
  proc hOpenpty(amaster, aslave: ptr cint, name: cstring, termp: pointer,
                winp: ptr HWinsize): cint {.importc: "openpty", header: "<util.h>".}
  const
    HTIOCSCTTY = 0x20007461'u32
    HTIOCSPGRP = 0x80047476'u32
    HTIOCSWINSZ = 0x80087467'u32  # _IOW('t', 103, struct winsize)
else:
  proc hOpenpty(amaster, aslave: ptr cint, name: cstring, termp: pointer,
                winp: ptr HWinsize): cint {.importc: "openpty", header: "<pty.h>".}
  const
    HTIOCSCTTY = 0x540E'u32
    HTIOCSPGRP = 0x5410'u32
    HTIOCSWINSZ = 0x5414'u32

proc hIoctl(fd: cint, request: culong, arg: pointer): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>".}

type PtyJob = object
  pid: Pid
  master: cint

proc spawnPty(cmd: string): PtyJob =
  var master, slave: cint
  doAssert hOpenpty(addr master, addr slave, nil, nil, nil) == 0, "openpty failed"
  var ws: HWinsize
  ws.ws_col = 80
  ws.ws_row = 24
  discard hIoctl(master, HTIOCSWINSZ, addr ws)
  let pid = fork()
  if pid == 0:
    discard setsid()
    discard hIoctl(slave, HTIOCSCTTY, nil)
    var pg: cint = getpgrp()
    discard hIoctl(slave, HTIOCSPGRP, addr pg)
    discard dup2(slave, 0)
    discard dup2(slave, 1)
    discard dup2(slave, 2)
    if master > 2:
      discard close(master)
    if slave > 2:
      discard close(slave)
    discard execvp("/bin/sh", allocCStringArray(["sh", "-c", cmd]))
    quit(1)
  discard close(slave)
  discard fcntl(master, F_SETFL, fcntl(master, F_GETFL) or O_NONBLOCK)
  PtyJob(pid: pid, master: master)

proc ptySend(j: PtyJob, s: string) =
  discard posix.write(j.master, unsafeAddr s[0], s.len)

proc ptyReadFor(j: PtyJob, ms: int, needle: string): string =
  let deadline = getTime() + initDuration(milliseconds = ms)
  var buf: array[4096, char]
  while getTime() < deadline:
    let n = posix.read(j.master, addr buf[0], buf.len)
    if n > 0:
      result.add cast[string](buf[0..<n])
      if needle.len > 0 and needle in result:
        return
    else:
      sleep 15

proc count(haystack, needle: string): int =
  var i = 0
  while true:
    let at = haystack.find(needle, i)
    if at < 0:
      return
    inc result
    i = at + needle.len

proc ptyExpect(j: PtyJob, needle: string, ms = 3000, times = 1): string =
  ## Wait for needle to appear `times` times. A typed command's line echo
  ## is its first appearance; its output is the second -- requiring two
  ## tells them apart on a tty that echoes input.
  result = j.ptyReadFor(ms, needle)
  doAssert count(result, needle) >= times,
    "expected " & $times & "x " & needle & ", got: " & result

proc reap(pid: Pid, ms = 3000) =
  let deadline = getTime() + initDuration(milliseconds = ms)
  var st: cint
  while getTime() < deadline:
    if waitpid(pid, st, WNOHANG) == pid:
      return
    sleep 25
  discard kill(pid, SIGKILL)
  discard waitpid(pid, st, 0)

proc sockUp(name: string): bool =
  for i in 1..40:
    if sockExists(RuntimeDir / "mpx" / name & ".sock"):
      return true
    sleep(250)
  false

# Ctrl-D is EOF for the program, not for the attach: cat reads it through
# mpx and the session ends by itself
discard startProcess(bin, args=["daemon", "eodemo", "--", "/bin/cat"],
                     options={poDaemon})
doAssert sockUp("eodemo"), "eodemo daemon never started"
let (eo, _) = runTimed("(printf 'pre\\n\\004after'; sleep 1) | " & bin & " attach eodemo", 4)
doAssert "pre" in eo, "cat never echoed: " & eo
var eoGone = false
for i in 1..24:
  if not sockExists(RuntimeDir / "mpx" / "eodemo.sock"):
    eoGone = true
    break
  sleep(250)
doAssert eoGone, "Ctrl-D never ended the cat session"
echo "example: Ctrl-D passthrough ends the program verified"

# A BEL inside a pasted chunk rides through; only a lone Ctrl-G detaches,
# and detaching leaves the session alive
discard startProcess(bin, args=["daemon", "pastemo", "--", "/bin/cat"],
                     options={poDaemon})
doAssert sockUp("pastemo"), "pastemo daemon never started"
let (po, _) = runTimed("(printf 'ab\\007cd\\n'; sleep 0.3; printf 'still\\n'; sleep 1) | " &
                       bin & " attach pastemo", 4)
doAssert "still" in po, "BEL inside a paste chunk must not detach, got: " & po
doAssert "ab" in po and "cd" in po, "the paste chunk never reached the program"
discard runTimed("(printf '\\007'; sleep 1) | " & bin & " attach pastemo", 4)
sleep(300)
let (lsOut, _) = execCmdEx(bin & " ls")
doAssert "pastemo" in lsOut, "lone Ctrl-G must detach without killing the session"
echo "example: Ctrl-G detach (and BEL-in-paste passthrough) verified"

# Ctrl-Z in a command session: the ticker's heartbeat file is the honest
# witness of the program's own state, portable where /proc is not
let hbFile = getTempDir() / "mpx_example_tick.hb"
let pidFile = getTempDir() / "mpx_example_tick.pid"
removeFile(hbFile)
removeFile(pidFile)
let tickerSh = getTempDir() / "mpx_example_ticker.sh"
writeFile(tickerSh,
  "echo $$ > " & pidFile & "\n" &
  "while true; do printf x >> " & hbFile & "; echo tick; sleep 0.2; done\n")
proc hbStalled(ms: int): bool =
  let sz = getFileSize(hbFile)
  sleep(ms)
  getFileSize(hbFile) == sz

discard startProcess(bin, args=["daemon", "zdemo", "--", "/bin/sh", tickerSh],
                     options={poDaemon})
doAssert sockUp("zdemo"), "zdemo daemon never started"
var tickerPid = 0
for i in 1..20:
  try:
    tickerPid = parseInt(readFile(pidFile).strip)
    break
  except CatchableError:
    sleep 100
doAssert tickerPid > 0, "ticker never started"

# 1) The containing shell: an interactive bash runs the attach, Ctrl-Z
#    stops mpx, bash reports the stopped job and takes its prompt back,
#    fg resumes both. Skipped on macOS: its tty holds a resumed job's
#    output in the slave queue after fg (the client's writes all succeed
#    but the master sees nothing for seconds), wedging this check. Needs
#    native macOS investigation; every other stop/cont path is covered
#    by the tests below.
when not defined(macosx):
  var term = spawnPty("bash --norc")
  discard ptyExpect(term, "$")
  ptySend(term, bin & " attach zdemo\n")
  discard ptyExpect(term, "tick")
  ptySend(term, "\x1a")
  discard ptyExpect(term, "Stopped")  # bash's job report: the shell is back
  sleep(200)                          # any heartbeat write in flight lands
  doAssert hbStalled(700), "program kept running after Ctrl-Z"
  ptySend(term, "fg\n")
  doAssert not hbStalled(700), "fg did not resume the program"
  discard ptyExpect(term, "tick")     # output flows again through the same attach
  ptySend(term, "\x07")               # and Ctrl-G still detaches afterwards
  sleep(300)                          # let the detach land before the next key
  ptySend(term, "echo BACK_AT_SHELL\n")
  discard ptyExpect(term, "BACK_AT_SHELL", times = 2)  # ran, not just echoed
  ptySend(term, "exit\n")
  reap(term.pid)
  discard close(term.master)
  echo "example: Ctrl-Z returns to the containing shell, fg resumes verified"

# 2) A client that dies while stopped hands fg to the next attach: stop,
#    kill the stopped job from the shell, then a fresh attach resumes the
#    program (attaching is fg). macOS: gated with test 1 above, same tty
#    hold around a stopped-and-resumed job; the suspend/resume protocol
#    itself stays covered by tests/test1.nim on every platform.
when not defined(macosx):
  var solo = spawnPty("bash --norc")
  discard ptyExpect(solo, "$")
  ptySend(solo, bin & " attach zdemo\n")
  discard ptyExpect(solo, "tick")
  ptySend(solo, "\x1a")
  sleep(200)                          # the stop is a lone keypress; let it land
  discard ptyExpect(solo, "Stopped")
  doAssert hbStalled(500), "client stopped but program still ran"
  ptySend(solo, "kill -9 %1; echo KRC=$?\n")  # the terminal dies while stopped
  discard ptyExpect(solo, "KRC=0")     # bash's own report of the kill's fate
  doAssert hbStalled(700), "program ran without a client"
  discard runTimed("(sleep 1) | " & bin & " attach zdemo", 3)  # attach is fg
  doAssert not hbStalled(900), "fresh attach did not resume the stopped program"
  ptySend(solo, "exit\n")
  reap(solo.pid)
  discard close(solo.master)
  echo "example: Ctrl-Z stop, re-attach resume verified"
discard execCmd(bin & " kill zdemo 2>/dev/null")

# 3) Ctrl-Z in a shell session still belongs to the session's own job
#    control: the byte is forwarded, the inner bash stops ITS job, the
#    attach client itself must keep running
discard startProcess(bin, args=["daemon", "shdemo"],
                     env={"SHELL": "/bin/bash"}.newStringTable,
                     options={poDaemon})
doAssert sockUp("shdemo"), "shdemo daemon never started"
var shellJob = spawnPty("bash --norc")
discard ptyExpect(shellJob, "$")
ptySend(shellJob, bin & " attach shdemo\n")
discard ptyExpect(shellJob, "$")     # the inner shell's own prompt
ptySend(shellJob, "sleep 5\n")
sleep(400)
ptySend(shellJob, "\x1a")
sleep(200)                          # the byte is a lone keypress for the client
discard ptyExpect(shellJob, "Stopped")  # inner bash's job report
# the client never stopped: the inner shell still answers through it
ptySend(shellJob, "echo INNER_ALIVE\n")
discard ptyExpect(shellJob, "INNER_ALIVE", times = 2)
ptySend(shellJob, "\x07")            # detach from the shell session
sleep(300)
ptySend(shellJob, "echo G_DONE\n")
discard ptyExpect(shellJob, "G_DONE", times = 2)
ptySend(shellJob, "exit\n")
reap(shellJob.pid)
discard close(shellJob.master)
echo "example: Ctrl-Z passthrough in shell sessions verified"
discard execCmd(bin & " kill shdemo 2>/dev/null")

# 4) Resize: the client's SIGWINCH reaches the session's pty
discard startProcess(bin, args=["daemon", "wsdemo"],
                     env={"SHELL": "/bin/bash"}.newStringTable,
                     options={poDaemon})
doAssert sockUp("wsdemo"), "wsdemo daemon never started"
var wsJob = spawnPty("bash --norc")
discard ptyExpect(wsJob, "$")
ptySend(wsJob, bin & " attach wsdemo\n")
discard ptyExpect(wsJob, "$")        # the inner shell's own prompt
ptySend(wsJob, "stty size\n")
discard ptyExpect(wsJob, "24 80")
var ws: HWinsize
ws.ws_col = 100
ws.ws_row = 30
discard hIoctl(wsJob.master, HTIOCSWINSZ, addr ws)
sleep(400)  # SIGWINCH -> client -> daemon -> session pty
ptySend(wsJob, "stty size\n")
discard ptyExpect(wsJob, "30 100")
ptySend(wsJob, "\x07")
sleep(300)
ptySend(wsJob, "exit\n")
reap(wsJob.pid)
discard close(wsJob.master)
echo "example: resize propagation verified"
discard execCmd(bin & " kill wsdemo 2>/dev/null")
discard execCmd(bin & " kill pastemo 2>/dev/null")

removeFile(tickerSh)
removeFile(hbFile)
removeFile(pidFile)

cleanup()
echo "example: all passed"
