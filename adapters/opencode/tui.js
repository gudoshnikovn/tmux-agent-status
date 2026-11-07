// tmux-agent-status: reports this pane's OpenCode session state.
// A TUI plugin, not a server one: OpenCode 2 shares one background server with
// no tty or $TMUX_PANE, and its events cover every pane's sessions.
import { spawn } from "node:child_process"

const REPORTER = "__REPORTER__"

function report(status, message = "") {
  if (!process.env.TMUX_PANE) return
  const args = [status, "--tool", "opencode"]
  if (message) args.push("--message", message)
  try {
    spawn(REPORTER, args, { stdio: "ignore" }).on("error", () => {})
  } catch {}
}

function setup(api) {
  const created = new Map()
  const blockers = new Set()

  const rootOf = (id) => {
    const visited = new Set()
    while (id && !visited.has(id)) {
      visited.add(id)
      const parent = (api.data.session.get(id) ?? created.get(id))?.parentID
      if (!parent) return id
      id = parent
    }
  }
  const selected = () => {
    const route = api.ui.router.current()
    return route.type === "session" ? rootOf(route.sessionID) : undefined
  }

  const finish = (message) => {
    blockers.clear()
    report("done", message)
  }
  const unblock = (id) => {
    if (blockers.delete(id) && blockers.size === 0) report("working")
  }

  // shortcut: a turn running while you browse another session goes unreported until you return; track per-session state if that bites.
  const unsubscribe = api.data.listen(({ details: event }) => {
    const data = event.data
    if (data == null) return
    if (event.type === "session.created") created.set(data.sessionID, { parentID: data.parentID })

    const session = event.type === "form.created" ? data.form.sessionID : data.sessionID
    const root = selected()
    if (!root || rootOf(session) !== root) return

    switch (event.type) {
      case "permission.asked":
        blockers.add(data.id)
        report("waiting", `permission: ${data.permission ?? ""}`)
        break
      case "form.created":
        blockers.add(data.form.id)
        report("waiting", "question")
        break
      case "permission.replied":
        unblock(data.requestID)
        break
      case "form.replied":
      case "form.cancelled":
        unblock(data.id)
        break
      // Subagents run their own executions inside this pane's turn.
      case "session.execution.started":
        if (session === root && blockers.size === 0) report("working")
        break
      case "session.execution.succeeded":
      case "session.execution.interrupted":
        if (session === root) finish()
        break
      case "session.execution.failed":
        if (session === root) finish("error")
        break
    }
  })

  return () => {
    unsubscribe()
    report("clear")
  }
}

export default { id: "tmux-agent-status", setup }
