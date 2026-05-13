Lightweight bubblewrap wrapper for sandboxing dev tools. Isolates file writes, tmp, and session history per project.

**Main repository:** [codeberg.org/Grauwolf/sandbox-run](https://codeberg.org/Grauwolf/sandbox-run)
| Mirrors: [GitHub](https://github.com/Grauwolf/sandbox-run) · [GitLab](https://gitlab.com/Grauwolf/sandbox-run)

## What It Does

This script creates a lightweight sandbox around commands you run using [bubblewrap](https://github.com/containers/bubblewrap). Your system's installed software (compilers, interpreters, CLI tools) is available inside the sandbox, but only for use. The sandbox cannot modify system files.

For tools that maintain per-user state (like `pnpm` global installs or `pi` agent session history), the script can additionally isolate that state per project, preventing one project's data from leaking into another.

Your project directory gets full read/write access, so the sandboxed tools can actually do their work. A fresh `/tmp` and `/run` are created for each session, and `.env.production` files are blocked by default.

Network access is enabled by default (shared with the host), so tools that need internet connectivity work normally. You can optionally disable networking for extra isolation.

## Installation

Clone the repository and symlink `sandbox-run` into a directory on your PATH:

```bash
git clone https://codeberg.org/Grauwolf/sandbox-run.git ~/.local/src/sandbox-run
ln -s ~/.local/src/sandbox-run/sandbox-run ~/bin/sandbox-run
```

Make sure `~/bin` is in your PATH (add `export PATH="$HOME/bin:$PATH"` to your shell profile if needed).

For transparent sandboxing of specific tools, create additional symlinks:

```bash
ln -s ~/bin/sandbox-run ~/bin/pnpm
ln -s ~/bin/sandbox-run ~/bin/pi
```

**Note:** Don't symlink to `~/.local/bin/`. That directory is sandboxed and maps to `~/.sandbox-run/local/bin/` on the host.

## Requirements

You need bubblewrap installed. For sandboxed D-Bus integrations such as desktop notifications, xdg-dbus-proxy is optional but recommended.

```bash
# Debian/Ubuntu
sudo apt install bubblewrap xdg-dbus-proxy

# openSUSE
sudo zypper install bubblewrap xdg-dbus-proxy
```

## Usage

Run the script from your project directory:

```bash
./sandbox-run <command> [args...]
```

For example:

```bash
./sandbox-run npm run dev
./sandbox-run python script.py
./sandbox-run go build

# Tools with per-user state need their presets enabled:
SANDBOX_RUN_PRESETS_EXTRA=pi sandbox-run pi
```

The current working directory becomes the project root inside the sandbox (with its contents shared).
However, if `SANDBOX_RUN_BWRAP_CHDIR` is set, the command is launched from within that directory.

### Symlink Mode

When invoked via a symlink, `sandbox-run` automatically runs the command matching the symlink name (see [Installation](#installation) for setup). This is useful for tools that are called by other programs; they'll get the sandboxed version transparently.

**Note:** For tools with extra presets, remember to set `SANDBOX_RUN_PRESETS_EXTRA` in your shell profile:

```bash
# ~/.bashrc
export SANDBOX_RUN_PRESETS_EXTRA=pi
```

Package managers work the same way:

```bash
ln -s ~/bin/sandbox-run ~/bin/pnpm

# pnpm now runs sandboxed, with caches/global installs isolated to ~/.sandbox-run/
pnpm install -g some-package   # installs to sandbox, not your system
```

## Docker Support

Enable the docker preset with `SANDBOX_RUN_PRESETS_EXTRA=docker` (or add `docker` to your existing extras).

The script checks for a Docker socket proxy at `127.0.0.1:2375`. If one is running, it uses that. Otherwise it falls back to mounting `/var/run/docker.sock` directly (which is less secure but works out of the box).

For better isolation, you can run a socket proxy like [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy):

```yaml
# docker-compose.yml
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy
    environment:
      CONTAINERS: 1
      EXEC: 1
      POST: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "127.0.0.1:2375:2375"
```

## tmux Support

Enable the tmux preset with `SANDBOX_RUN_PRESETS_EXTRA=tmux` (or add `tmux` to your existing extras).

The preset mounts the tmux socket directory so clients inside the sandbox can connect to a tmux server running on the host.

Socket detection order:

1. `SANDBOX_RUN_TMUX_SOCKET` (explicit override)
2. Current `TMUX` environment variable (when already inside tmux)
3. Common defaults (`/run/tmux/<uid>/default` and `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`)

Examples:

```bash
# Auto-detect + use resolved socket explicitly
SANDBOX_RUN_PRESETS_EXTRA=tmux \
  sandbox-run sh -lc 'tmux -S "$SANDBOX_RUN_TMUX_SOCKET" ls'

# Explicit socket path (most reliable)
SANDBOX_RUN_PRESETS_EXTRA=tmux \
  SANDBOX_RUN_TMUX_SOCKET=/run/tmux/$(id -u)/default \
  sandbox-run sh -lc 'tmux -S "$SANDBOX_RUN_TMUX_SOCKET" attach'
```

## Customization

The script has a few arrays you can edit to adjust what's exposed inside the sandbox:

- `RO_BINDS` contains system paths mounted read-only
- `RW_BINDS` contains paths mounted read-write (tool configs, package managers)
- `DEV_BINDS` contains device paths mounted with device access enabled
- `BLOCKED` lists files that get hidden (bound to `/dev/null`)

### Environment Variables

All configuration uses the `SANDBOX_RUN_` prefix:

| Variable | Description |
|----------|-------------|
| `SANDBOX_RUN_TRACE=1` | Enable debug tracing |
| `SANDBOX_RUN_NO_NET=1` | Disable network access |
| `SANDBOX_RUN_RO_BIND=path:path` | Additional read-only binds |
| `SANDBOX_RUN_RW_BIND=path:path` | Additional read-write binds |
| `SANDBOX_RUN_DEV_BIND=path:path` | Additional device binds |
| `SANDBOX_RUN_BLOCKED=path:path` | Additional paths to block |
| `SANDBOX_RUN_DEFAULT_CMD="cmd"` | Default command if none is given |
| `SANDBOX_RUN_BWRAP_ARGS="args"` | Extra bwrap arguments |
| `SANDBOX_RUN_BWRAP_CHDIR="path"` | Start command in given directory |
| `SANDBOX_RUN_DBUS_TALK=name:name` | Additional D-Bus names to allow via `xdg-dbus-proxy --talk` |
| `SANDBOX_RUN_DBUS_CALL=name=rule:name=rule` | Additional D-Bus method rules via `xdg-dbus-proxy --call` |
| `SANDBOX_RUN_DBUS_BROADCAST=name=rule:name=rule` | Additional D-Bus signal rules via `xdg-dbus-proxy --broadcast` |
| `SANDBOX_RUN_PRESETS=name:name` | Override default presets (see below) |
| `SANDBOX_RUN_PRESETS_EXTRA=name:name` | Add extra presets (see below) |
| `SANDBOX_RUN_TMUX_SOCKET=/path/to/socket` | Override tmux socket path (tmux preset) |
| `SANDBOX_RUN_GIT_TMPDIR=auto\|path` | Parent directory for the temporary clone |

Examples:

```bash
# Run without network
SANDBOX_RUN_NO_NET=1 sandbox-run npm install

# Add extra binds
SANDBOX_RUN_RO_BIND=/opt/tools:/usr/local/share sandbox-run make

# Pass hardware devices such as USB UART adapters into the sandbox.
# udev-created symlinks work too:
# Their host-side targets are resolved before the private /dev is created.
SANDBOX_RUN_DEV_BIND=/dev/ttyNICENAME

# Block additional files
SANDBOX_RUN_BLOCKED=.env.local:.env.development sandbox-run make

# Extra bwrap arguments
SANDBOX_RUN_BWRAP_ARGS="--tmpfs /scratch" sandbox-run python script.py

# Allow local KDE PowerDevil sleep-inhibition calls
export SANDBOX_RUN_DBUS_CALL="org.kde.Solid.PowerManagement.PolicyAgent=org.kde.Solid.PowerManagement.PolicyAgent.AddInhibition@/org/kde/Solid/PowerManagement/PolicyAgent:org.kde.Solid.PowerManagement.PolicyAgent=org.kde.Solid.PowerManagement.PolicyAgent.ReleaseInhibition@/org/kde/Solid/PowerManagement/PolicyAgent"
```

### Presets

Tool-specific setup is organized into presets. Default presets provide common development tooling:

| Preset | Description |
|--------|-------------|
| `npm` | npm/pnpm cache and global installs |
| `python` | uv/pip cache |
| `go` | Go module cache and GOPATH |
| `cargo` | Cargo/Rust home directory |
| `dbus` | D-Bus proxy helpers; enables desktop notifications by default |

Extra presets are opt-in and must be explicitly enabled via `SANDBOX_RUN_PRESETS_EXTRA`:

| Preset | Description |
|--------|-------------|
| `pi` | Pi agent session isolation per project |
| `claude` | Claude Code session isolation per project |
| `opencode` | OpenCode session isolation per project |
| `vibe` | Mistral Vibe session isolation per project |
| `git` | User-global Git config (`$XDG_CONFIG_HOME/git`, `~/.gitconfig`) read-only |
| `git-minimal` | Minimal context for git to allow for proper commit metadata without a complete gitconfig |
| `glab` | GitLab CLI config |
| `forgejo` | Forgejo CLI config |
| `docker` | Docker socket (proxy or direct) |
| `tmux` | tmux host socket access |
| `wayland` | Wayland display + GPU for GUI apps (Chromium, etc.) |
| `audio` | PipeWire/PulseAudio runtime sockets for sound output/input |

Add extra presets with `SANDBOX_RUN_PRESETS_EXTRA`:

```bash
# Enable pi agent preset
SANDBOX_RUN_PRESETS_EXTRA=pi sandbox-run pi

# Enable Wayland for GUI applications
SANDBOX_RUN_PRESETS_EXTRA=wayland sandbox-run chromium

# Enable GUI + audio
SANDBOX_RUN_PRESETS_EXTRA=wayland:audio sandbox-run chromium

# Enable tmux access
SANDBOX_RUN_PRESETS_EXTRA=tmux sandbox-run tmux ls

# Multiple extras
SANDBOX_RUN_PRESETS_EXTRA=pi:wayland:audio sandbox-run pi
```

For persistent configuration, set in your shell profile:

```bash
# ~/.bashrc - always enable your preferred extras
export SANDBOX_RUN_PRESETS_EXTRA=pi
```

For per-project extras (e.g., with direnv):

```bash
# project/.envrc - add wayland for this project
export SANDBOX_RUN_PRESETS_EXTRA="${SANDBOX_RUN_PRESETS_EXTRA}:wayland"
```

Override defaults with `SANDBOX_RUN_PRESETS`:

```bash
# Only npm (no other defaults)
SANDBOX_RUN_PRESETS=npm sandbox-run bash

# No presets (minimal sandbox)
SANDBOX_RUN_PRESETS= sandbox-run ls
```

### Custom Presets

Built-in presets are shipped in the `presets.d/` directory alongside the script. These are sourced automatically.

To add your own presets or override built-in ones, create files in `~/.sandbox-run/presets.d/`. The filename (without `.sh`) becomes the preset name:

```bash
# ~/.sandbox-run/presets.d/my-app.sh
configure_my_app() {
    RO_BINDS+=("/path/to/my-app/readonly")
    RW_BINDS+=("/path/to/my-app/writable")
}
```

User presets in `~/.sandbox-run/presets.d/` are sourced after the built-in ones, so you can override any built-in preset by redefining its function (e.g., create `npm.sh` with your own `configure_npm`).

Presets can request D-Bus proxy permissions with helpers from the built-in `dbus` preset:

```bash
configure_my_app() {
    dbus_talk "org.example.Service"
    dbus_call "org.example.Service=org.example.Interface.Method@/org/example/Object"
}
```

Custom presets are **sourced** (functions defined) but **not auto-loaded**. Enable them explicitly:

```bash
# Per-project via .envrc
export SANDBOX_RUN_PRESETS_EXTRA="${SANDBOX_RUN_PRESETS_EXTRA}:my-app"

# Or one-off
SANDBOX_RUN_PRESETS_EXTRA=my-app sandbox-run some-app
```

## Package Manager Isolation

Package managers (npm, pip/uv, Go, Cargo) are automatically configured to use sandbox-specific directories instead of your host's. This means:

- Global installs don't pollute your host system
- Caches are shared across sandbox sessions (faster rebuilds)
- Each tool's data is isolated from the host

Inside the sandbox, `~/.local` maps to `~/.sandbox-run/local/` on the host. Tools use their default `~/.local` paths:

| Tool | Cache (host) | Data (in sandbox) | Binaries (in sandbox) |
|------|--------------|-------------------|----------------------|
| npm | `~/.sandbox-run/cache/npm` | `~/.local/share/npm` | `~/.local/share/npm/bin` |
| pnpm | `~/.sandbox-run/cache/npm` | `~/.local/share/pnpm` | `~/.local/share/pnpm/bin` |
| uv/pip | `~/.sandbox-run/cache/uv`, `~/.sandbox-run/cache/pip` | `~/.local/share/uv` | `~/.local/bin` |
| Go | `~/.sandbox-run/cache/go/mod` | `~/.local/share/go` | `~/.local/bin` |
| Cargo | (in CARGO_HOME) | `~/.local/share/cargo` | `~/.local/share/cargo/bin` |

The sandbox's PATH includes `~/.local/bin` plus tool-specific bin directories, so globally installed tools are available.

**Note:** Tools must be installed inside the sandbox separately from your host system:

```bash
# Enter sandbox and install tools
./sandbox-run bash

# Then install what you need (use pnpm or npm):
pnpm install -g @mariozechner/pi-coding-agent
pnpm install -g some-cli-tool
uv tool install some-python-tool
```

These installs persist in `~/.sandbox-run/local/` (mounted as `~/.local` inside) across sessions. Once installed, `sandbox-run` automatically finds them:

```bash
# Don't forget to enable the preset for tools that need one
SANDBOX_RUN_PRESETS_EXTRA=pi sandbox-run pi
```

## Data Location

```
~/.sandbox-run/
├── presets.d/                  # user-defined preset overrides
├── sandboxes/<project-hash>/   # per-project (transcripts, history)
├── cache/                      # shared package manager caches
└── local/                      # mounted as ~/.local inside sandbox
    ├── bin/                    # uv tools, go binaries
    └── share/
        ├── npm/                # npm global installs
        ├── pnpm/               # pnpm global installs
        ├── uv/                 # uv tool installs
        ├── go/                 # GOPATH
        └── cargo/              # CARGO_HOME
```

Each project gets its own isolated directory based on a hash of the project path. The `local/` directory is mounted as `~/.local` inside the sandbox, so tools use their default paths.

## AI Use Disclaimer

This codebase has been built with the support of coding agents.

## License

AGPL-3.0. Based on [sandbox-utils/sandbox-run](https://github.com/sandbox-utils/sandbox-run). This fork has been substantially rewritten with modular presets, per-project isolation, and package manager sandboxing.
