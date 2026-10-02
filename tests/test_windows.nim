# mpx Windows runtime test: the beck-verified flow, scripted
#
# Run with: nimble test (on Windows)
#
# Requires mpx.exe in the working directory: CI builds it before
# `nimble test`, and the beck deploy drops it next to this binary.
#
# Covers: new cmd (daemon spawn, ConPTY child, TCP listener, .port
# file), attach roundtrip through the vetted TCP path, Ctrl-G detach,
# stdin-EOF detach, snapshot on reattach, default-shell probe, ls,
# kill with file sweep.

import std/[os, osproc, strutils, streams]
import mpx/runtime

const Session = "winsmoke"
const Shell = "winshell"

let Bin = "mpx.exe"

proc runMpx(args: seq[string], chunks: seq[string] = @[],
            closeAfterMs = 0, secs = 30): tuple[output: string, exitCode: int] =
  ## chunks land as separate pipe writes 500ms apart so a lone BEL
  ## reaches the client in its own ReadFile and exercises the real
  ## Ctrl-G detach path. closeAfterMs > 0 holds stdin open after the
  ## chunks, letting snapshots land before EOF ends the client.
  let p = startProcess(Bin, args = args, options = {poStdErrToStdOut})
  for c in chunks:
    sleep(500)
    try:
      p.inputStream.write(c)
      p.inputStream.flush()
    except OSError, IOError:
      # child died before reading stdin; the exitCode assert below
      # carries its stderr
      break
  if closeAfterMs > 0:
    sleep(closeAfterMs)
    p.inputStream.close()
  discard p.waitForExit(secs * 1000)
  if p.running:
    p.kill()
  result.output = p.outputStream.readAll()
  result.exitCode = p.peekExitCode()
  p.close()

const IdOld = "identold"   # dies hard mid-run, port gets re-claimed
const IdNew = "identnew"   # the younger daemon that takes the freed port

# Sweep leftovers from a previous run; kill of a dead session is
# expected to die (stale-file cleanup), the exit code is ignored
for s in [Session, Shell, IdOld, IdNew, "winargs"]:
  discard runMpx(@["kill", s], secs = 15)

# new cmd: daemon spawns detached, client attaches, `echo zkmark`
# roundtrips through the pty, then Ctrl-G (a lone BEL chunk) detaches
let first = runMpx(@["new", Session, "cmd"],
                   chunks = @["echo zkmark\r", "\a"])
doAssert first.exitCode == 0,
  "new+attach roundtrip failed (" & $first.exitCode & "): " & first.output
doAssert "zkmark" in first.output,
  "expected zkmark roundtripped through the pty: " & first.output
echo "test: new cmd, live roundtrip, Ctrl-G detach verified"

# Reattach: the snapshot carries the previous output; stdin EOF with
# no input ends the client
let snap = runMpx(@["attach", Session], closeAfterMs = 1500)
doAssert snap.exitCode == 0, "reattach failed: " & snap.output
doAssert "zkmark" in snap.output,
  "snapshot missing previous output: " & snap.output
echo "test: reattach snapshot verified"

# A session with the default shell (pwsh/powershell/cmd probe)
let shell = runMpx(@["new", Shell], closeAfterMs = 1500)
doAssert shell.exitCode == 0,
  "default-shell session failed: " & shell.output
echo "test: default-shell session verified"

# ls lists both sessions
let lsOut = runMpx(@["ls"], secs = 15)
doAssert Session in lsOut.output and Shell in lsOut.output,
  "ls missing sessions: " & lsOut.output
echo "test: ls lists both sessions"

# Command arguments ride along: `cmd /k echo winargmark` keeps the shell
# alive after echoing, so the mark must come back through the pty
let argOut = runMpx(@["new", "winargs", "cmd", "/k", "echo", "winargmark"],
                    chunks = @["\a"])
doAssert argOut.exitCode == 0, "new with command args failed: " & argOut.output
doAssert "winargmark" in argOut.output,
  "command arguments were dropped: " & argOut.output
echo "test: command arguments passed through verified"

# Identity: a hard-killed daemon's stale .port names a port the next
# daemon re-claims in the base-port scan. ls and attach must not be
# fooled into seeing the dead session behind the younger daemon.
let startOld = runMpx(@["new", IdOld, "cmd"], chunks = @["\a"])
doAssert startOld.exitCode == 0, "identity setup failed: " & startOld.output
let oldPid = readFile(mpxDir() / (IdOld & ".pid")).strip.parseInt
let tk = execCmdEx("taskkill /F /PID " & $oldPid)
doAssert tk.output.len > 0 and "SUCCESS" in tk.output.toUpperAscii,
  "taskkill of the old daemon failed: " & tk.output
sleep(1000)  # let the port go free before the next daemon scans
let startNew = runMpx(@["new", IdNew, "cmd"], chunks = @["\a"])
doAssert startNew.exitCode == 0, "younger session failed: " & startNew.output
doAssert fileExists(mpxDir() / (IdOld & ".port")),
  "identity test needs the stale .port to still exist"
let idLs = runMpx(@["ls"], secs = 15)
doAssert IdNew in idLs.output, "ls missing the live session: " & idLs.output
doAssert IdOld notin idLs.output,
  "stale .port resurrected a dead session in ls: " & idLs.output
let idAtt = runMpx(@["attach", IdOld], closeAfterMs = 1000)
doAssert idAtt.exitCode != 0, "attach to a dead session must fail"
doAssert "cleaned stale" in idAtt.output,
  "expected stale-file cleanup on attach, got: " & idAtt.output
doAssert not fileExists(mpxDir() / (IdOld & ".port")),
  "attach should have swept the stale .port"
echo "test: stale .port identity verified (ls, attach)"

# kill sweeps processes and files
for s in [Session, Shell, IdNew, "winargs"]:
  let k = runMpx(@["kill", s], secs = 20)
  doAssert k.exitCode == 0, "kill " & s & " failed: " & k.output
  doAssert not fileExists(mpxDir() / (s & ".port")),
    s & " .port file survived kill"
  doAssert not fileExists(mpxDir() / (s & ".pid")),
    s & " .pid file survived kill"
echo "test: kill and file sweep verified"

echo "ALL WINDOWS TESTS PASSED"
