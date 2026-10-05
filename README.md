# mpx

Transparent terminal multiplexer. Your terminal emulator (Ghostty, etc.) talks
directly to the shell. mpx just owns the PTY and forwards bytes. No re-rendering,
no escape sequence mangling, no scrollback theft.

> **Status: early alpha.** Expect breakage between versions — commands, flags
> and behavior change without notice. Actively developed.

## Install

One-liner (Linux amd64/arm64, macOS universal):

```sh
curl -fsSL https://mpx.capocasa.dev/install | sh
```

Or from source:

```sh
nimble install
```

Both install the `mpx` binary. Windows: not supported (POSIX-only by
nature — PTYs, unix sockets, termios); see the CI matrix for what's built.

## Local usage

```sh
# Start a session named "main" running your shell. `new` is the
# default action, so `mpx main` does the same
mpx new main

# Session names are optional. No name = current directory's name
# ("~" when you're in your homedir), with a counter on collision:
mpx new            # in ~/p/mpx: session "mpx"
mpx new            # again: session "mpx0"
mpx new htop       # htop is a command, so: htop in session "mpx1"

# Re-running `mpx new <name>` on an active session just attaches to it
mpx new main

# Or start daemon separately, then attach (no name: oldest session)
mpx daemon main
mpx attach main
mpx attach

# List sessions
mpx ls

# Prints the name of the session this process is running in (exit 1 if not inside one)
mpx session-name

# Detach: Ctrl-G
#
# One key, no prefix, on the same key on every layout (a German keyboard
# needs Ctrl-AltGr-\ for the old key, which is not a key, it's a finger
# exercise). Ctrl-G collides with almost nothing: readline binds it to
# an abort nobody presses on purpose, and dvtm uses it as its mod key.
# Ctrl-D is NOT a detach key: it is EOF, and it reaches the program so
# shells, REPLs and pagers behave normally.

# Kill a session
mpx kill main

# Any unambiguous command prefix works
mpx n main   # new
mpx a main   # attach
mpx l        # ls
mpx session  # session-name
mpx k main   # kill
```

When the program inside a session exits, the session ends and disappears
from `mpx ls`.

## Options

There is no config file. Everything is a command line flag, on any
subcommand, before or after the other arguments:

```sh
mpx -l 10.0.0.4:4534 daemon work   # same as: mpx daemon work -l 10.0.0.4:4534
```

- `-l, --listen host:port` also exposes the session over TCP. The port is a
  base port: each session daemon takes the first free port at or above it
  (first session 4534, second 4535, ...). Clients scan up from the base
  port and pick their session by name.
- `-p, --port port` TCP base port, overrides the port in `--listen`
- `--log` appends to `$XDG_DATA_HOME/mpx/mpx-YYYY.log`
- `-v, --version`, `-h, --help`

Unknown flags, missing values, and malformed `host:port` are errors, not
guesses. Without `-l`, mpx runs on a unix socket only and logs nothing.

## Remote usage

Run the daemon on the host where the work happens, attach from anywhere
that can reach the TCP port. No SSH involvement, no SSH dependency.

Over wireguard (recommended, the traffic is otherwise unencrypted):

```sh
# On 10.0.0.4
mpx daemon -l 10.0.0.4:4534 work

# On your laptop
mpx attach -l 10.0.0.4:4534 work
```

Or over the LAN, same shape:

```sh
# On 192.168.178.130
mpx daemon -l 192.168.178.130:4534 work

# On the other machine
mpx attach -l 192.168.178.130:4534 work
```

Or forward a port manually through SSH if you must:

```sh
ssh -N -L 4534:127.0.0.1:4534 remotehost &
mpx attach -l 127.0.0.1:4534 work
```

Session names gate TCP access: a client must name the session correctly
to attach, but treat this as convenience, not a security boundary. Keep
the listener on a private interface (wireguard, tailnet, localhost) and
put real authentication in front if you need it.

## How it works

- **Daemon** owns the PTY master, forwards bytes verbatim in both directions.
- **Clients** are dumb terminals. They send input, receive output.
- **ttty** runs in parallel as a side cache. Only consulted on attach to render
  the current screen. Never in the data path.
- **Concurrent clients** all see the same output, and every client can type
  (primaryless: input fans in from whoever is attached; interleaving is the
  humans' problem to coordinate).
- **Resize** from any client propagates to the PTY and to ttty; last one
  wins. Clients follow their local window with SIGWINCH while attached.
- **Attach serves the full model**: the ttty side cache's scrollback (as
  plain text) plus the live screen (with attributes), so a late joiner
  starts with the session history in their own local scrollback.

No terminal emulator is reimplemented. Ghostty keeps its scrollback, mouse,
clipboard, font rendering. mpx is invisible.
