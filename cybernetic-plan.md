# Cybernetic Plan: Multiplexer v0-v2

## Context

Build a terminal multiplexer that is transparent to the terminal emulator (Ghostty is the primary target). Unlike tmux/screen, it must not re-render or interpret the byte stream. It owns the PTY, forwards bytes verbatim, and uses a side VT emulator (`ttty`) only for attach-time screen snapshots. Local clients connect via Unix socket; remote clients via SSH relay (v2). Concurrent attach supported.

## Current State

Not begun. `~/p/multiplexer` is empty. `~/p/ttty` (v0.5.1) exists and provides the VT grid renderer.

## Steps

- [x] 1. Create project skeleton: `multiplexer.nimble`, `src/multiplexer.nim`, `src/multiplexer/`. Add `requires "ttty"` once v1 starts. (Done: nimble init, minimal binary builds and runs.)
- [x] 2. PTY layer: fork/exec a shell on a PTY master. Handle SIGWINCH from controlling client. Raw mode, no line discipline. (Done: src/multiplexer/pty.nim compiles, test_pty.nim verifies echo roundtrip. Manual openpty/winsize declarations needed.)
- [x] 3. Unix socket server in `$XDG_RUNTIME_DIR/mpx/`. Protocol: attach, detach, resize, input, output. One client at first. (Done: daemon.nim + protocol.nim + client.nim, end-to-end verified with /bin/cat roundtrip.)
- [x] 4. Client: connect to socket, put local terminal in raw mode, forward stdin to daemon, stdout from daemon. Restore terminal on exit. (Done: client.nim works, raw mode, EOF handling needs polish but functional.)
- [ ] 5. Integrate `ttty` side cache: daemon feeds all PTY output to `ttty` grid. On attach, render grid to client before live forwarding. (In progress)
- [ ] 6. Multi-client broadcast: daemon forwards output to all attached clients. Input from controlling client only. Resize from controlling client.
- [ ] 7. SSH relay: client mode that connects to remote daemon over SSH. Reuses same protocol.
- [ ] 8. Example directory exercising full flow. `nimble test` drives example end-to-end.
- [ ] 9. Final review: build, test, `git diff`, verify all steps completed.

## Decisions

- **No macros.** Templates and generics only.
- **Daemon is the source of truth.** Clients are dumb terminals.
- **One geometry per session.** Controlling client wins resize; others adapt.
- **No scrollback in v0/v1.** ttty grid is enough for attach snapshot. Scrollback is v2+ if needed.
- **Commit per step.** Short one-liner messages. Stage specific files.