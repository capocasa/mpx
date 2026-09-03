# mpx

Transparent terminal multiplexer. Your terminal emulator (Ghostty, etc.) talks
directly to the shell. mpx just owns the PTY and forwards bytes. No re-rendering,
no escape sequence mangling, no scrollback theft.

## Install

```sh
nimble install
```

This installs two binaries: `multiplexer` (library + full CLI) and `mpx` (unixy
short command).

## Local usage

```sh
# Start a session named "main" running your shell
mpx new main

# Session names are optional. No name = next free number (1, 2, 3, ...)
mpx new            # shell in session "1"
mpx new htop       # htop in session "2"

# Re-running `mpx new <name>` on an active session just attaches to it
mpx new main

# Or start daemon separately, then attach
mpx daemon main
mpx attach main

# List sessions
mpx ls

# Detach: Ctrl+D

# Kill a session
mpx kill main
```

## systemd

Copy `mpx@.service` to `~/.config/systemd/user/` (create the dir if needed):

```sh
mkdir -p ~/.config/systemd/user
cp mpx@.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

Then:

```sh
# Start session "main" as a service
systemctl --user start mpx@main

# Attach to it
mpx attach main

# Enable at login
systemctl --user enable mpx@main
```

The `%i` in the unit file is the session name. `mpx@main` = session "main".

## Remote usage

On the remote host, start a daemon:

```sh
mpx daemon work
```

On your local machine, attach via SSH tunnel:

```sh
mpx relay remotehost work
```

This forks `ssh -N -L /tmp/mpx_relay_work.sock:/run/user/1000/mpx/work.sock remotehost`
and attaches to the forwarded socket. Requires key-based SSH auth (no password prompt).

To stop, detach with Ctrl+D. The SSH tunnel dies with the client.

## How it works

- **Daemon** owns the PTY master, forwards bytes verbatim in both directions.
- **Clients** are dumb terminals. They send input, receive output.
- **ttty** runs in parallel as a side cache. Only consulted on attach to render
  the current screen. Never in the data path.
- **Concurrent clients** all see the same output. Only the first (controlling)
  client can send input or resize.
- **Resize** from the controlling client propagates to the PTY and to ttty.

No terminal emulator is reimplemented. Ghostty keeps its scrollback, mouse,
clipboard, font rendering. mpx is invisible.
