# Agent running in a container/VM/remote host

`core/agent-status.sh` normally calls `tmux` directly, in the same
process as the hook that invoked it. That only works when the hook
runs in the same OS kernel the tmux server is in. It breaks whenever
the agent itself runs somewhere else — a devcontainer, Docker
(especially Docker Desktop for Mac/Windows, where containers run in a
separate Linux VM with its own kernel), WSL2 (across two different
distros), an SSH session to a remote host, or a CI/sandbox runner —
because the tmux server's Unix socket is a kernel object, not just a
file: even if the socket file is visible from the other side via a
shared filesystem (e.g. a bind mount or virtiofs), `connect()` to it
from a different kernel fails with `no server running on <path>`.

The fix is a second transport, `file`, that avoids touching tmux from
inside the container/VM/remote host at all.

## The three variables, and which ones are static vs. per-run

- `TMUX_AGENT_STATUS_TRANSPORT=file` and
  `TMUX_AGENT_STATUS_BRIDGE_FILE=<path>` are static per project/container
  — they don't change between runs, so they're fine to bake into the
  container's environment once (`containerEnv` in `devcontainer.json`,
  a `docker run -e`, an image's `ENV`, etc). `<path>` must resolve to
  the same file from both sides, so it needs to live under a directory
  that's actually shared between the two environments (bind mount,
  `sshfs`, NFS, a Windows drive mounted into every WSL2 distro, ...) —
  unlike the tmux socket, a plain file's *bytes* do cross a shared
  filesystem fine, only the live socket connection doesn't.
- `TMUX_PANE` identifies *which pane* to update, and that's only known
  at the moment you start the agent in a specific tmux pane — it is
  **not** a project constant. Baking a value like `%3` into
  `containerEnv`/a Dockerfile works once, for whichever pane happened
  to have that id when you wrote it, and silently goes stale the
  moment you open the container from a different pane or session (it
  will happily relay status onto the *wrong* pane, or a pane that no
  longer exists). Pass it fresh on every launch instead, from
  whatever's starting the command in the remote environment — see the
  per-tool patterns below. Never as a static `containerEnv`/`remoteEnv`
  entry.

With `transport=file` set, `agent-status.sh` appends a line describing
the transition to the bridge file instead of calling `tmux` — no tmux
binary or socket access is needed on the container/VM/remote side at
all.

## Starting the relay (once, on the host)

On the host — where tmux actually runs — start the relay, which tails
the bridge file and replays each line into tmux exactly as
`agent-status.sh` would have done directly:

```tmux
run-shell '~/.tmux/plugins/tmux-agent-status/core/agent-status-bridge-watch.sh ~/.cache/tmux-agent-status/bridge-file &'
```

Point it at the same path the other side writes to (from the host's
side of the shared filesystem). It's safe to leave this line in
`.tmux.conf` and have it re-fire on every reload — a pid file keeps it
to one running watcher per bridge file — and safe to restart, since it
checkpoints how much of the file it's already processed
(`<bridge-file>.offset`) instead of replaying old lines.

`transport`/`bridge_file` can also be set as `.tmux.conf`/config-file
options instead of env vars (picked up as a fallback when the env var
isn't set and `tmux` is actually reachable) — mainly useful for
testing this transport without a real container.

## Per-environment launch patterns

The common thread: whatever starts the agent process on the other side
needs to inject a *live* `$TMUX_PANE` on every launch. Wrap it once in
your shell config so you never do this by hand.

### devcontainer CLI

```sh
# ~/.zshrc or ~/.bashrc
devcontainer-agent() {
    devcontainer exec --remote-env TMUX_PANE="$TMUX_PANE" --workspace-folder . "$@"
}
# then: devcontainer-agent claude
```

`TMUX_AGENT_STATUS_TRANSPORT`/`TMUX_AGENT_STATUS_BRIDGE_FILE` go in
`devcontainer.json`'s `containerEnv` (static, set once), plus a
`mounts` entry bind-mounting the bridge file's directory between host
and container.

### Plain Docker (no devcontainer CLI)

```sh
docker-agent() {
    docker exec -e TMUX_PANE="$TMUX_PANE" -it mycontainer "$@"
}
```

`TMUX_AGENT_STATUS_TRANSPORT`/`TMUX_AGENT_STATUS_BRIDGE_FILE` are
usually already set via `-e` on `docker run` (when the container was
started) or the image's `ENV` — static, no need to repeat them on
every `exec`. `bridge_file` needs to be under a volume/bind mount.

### SSH to a remote host

SSH itself does **not** give you a shared filesystem — and the
bridge-file transport requires the same file to be visible from both
sides. So this needs one more piece: mount a shared directory between
host and remote host first (`sshfs` in either direction, or NFS,
whatever you already use), then:

```sh
ssh-agent-run() {
    ssh remote-host env \
        TMUX_PANE="$TMUX_PANE" \
        TMUX_AGENT_STATUS_TRANSPORT=file \
        TMUX_AGENT_STATUS_BRIDGE_FILE=/mnt/shared/bridge-file \
        "$@"
}
```

Without that shared mount, records pile up in a file on the remote
machine that the host-side watcher never sees — there's no workaround
for that inside this plugin; a real shared filesystem is a hard
requirement of the `file` transport, not just a convenience.

### WSL2 (agent in a different distro than tmux)

Each WSL2 distro has its own filesystem, not shared with other
distros directly — but every distro can see the Windows drives under
`/mnt/c/...`, which makes for the simplest shared path:

```sh
wsl-agent-run() {
    wsl -d other-distro -- env \
        TMUX_PANE="$TMUX_PANE" \
        TMUX_AGENT_STATUS_TRANSPORT=file \
        TMUX_AGENT_STATUS_BRIDGE_FILE=/mnt/c/Users/you/.cache/tmux-agent-status/bridge-file \
        "$@"
}
```

If tmux and the agent run in the *same* WSL2 distro, none of this is
needed — same kernel, same filesystem, `direct` transport just works.
