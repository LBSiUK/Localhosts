# Design

## What it's for

Claude Code agents start servers all the time: dev servers, Storybook, preview builds, quick `python -m http.server` checks. They keep running after the agent has moved on, and with several sessions open it gets hard to tell which server belongs to which tab, which are stale, and which are safe to stop.

Localhosts answers three questions in one click: what's running, who started it, and how do I get rid of it or get back to it.

## The list

- **Live sessions** come first, one section each, titled with the session's name and its Terminal tab. Sections are sorted by tab so they stay put between refreshes.
- **Session ended** holds servers whose Claude session has closed. The session's title is shown in the row, and Resume opens it again.
- **Other** holds everything else. It's collapsed by default, so the list stays about your agents.

The list refreshes every two seconds. Rows only change when something actually changed, so nothing flickers.

## Working out who started a server

Claude Code sets `CLAUDE_PID` (the Claude process) and `CLAUDE_CODE_SESSION_ID` in the environment of every command it runs, and child processes inherit them. The app reads a process's environment with `sysctl(KERN_PROCARGS2)`, which works for any process you own.

It checks, in order:

1. the process holding the port
2. its parents, up to launchd
3. the other processes in its process group

The third step matters for Node. `next dev` and `npm exec` rename themselves by writing over their own argument and environment memory, so the process holding the port has nothing left to read. Its parent (`node`, started by `npm run dev`) still has the variables.

If none of them has `CLAUDE_PID`, the app checks whether a parent process *is* Claude, which covers servers started in ways that drop the environment.

A `CLAUDE_PID` only counts as live when that process is still Claude and started before the server. Process IDs get reused, and without that check a recycled ID could point the terminal button at the wrong tab.

When the Claude process has gone but the session ID is known, the server is listed under Session ended.

## Session names and folders

Claude Code keeps each session's transcript in `~/.claude/projects/<project>/<session id>.jsonl`. The title is the newest `custom-title` line (a name you gave the session), or else the newest `ai-title` line. The folder is the first `cwd` field. The app reads only the first 256 KB and the last 2 MB of a transcript, and caches the result for 30 seconds.

## What's hidden

- Listeners from macOS itself: anything under `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin` or `/Library/Apple`.
- Desktop apps in `/Applications` or `~/Applications` (AirPlay, Discord, Spotify and the like), except developer tools bundled inside Xcode.
- Claude itself, and this app.
- `limactl`, Colima's own DNS and networking ports.

A hidden listener still shows up if an agent registered it with `localhosts add`, or if a Claude session started it.

## The registry

`localhosts add` writes one small JSON file per port to `~/Library/Application Support/Localhosts/servers`, so the command and the app never fight over a shared file. Each entry records the label, the page to open, the stop command, the folder `add` was run from, and the session from the environment.

An entry matches a listener on the same port when the process ID and start time both match, or when the listener is in the same process group. The group match keeps the label when a dev server restarts its worker. Entries are deleted once neither the process nor its group is running.

## Stopping

Stopping only the process holding the port often isn't enough: `npm run dev` would just leave a parent behind, and some tools respawn their worker. So `Stopper`:

1. takes the server's whole process group, plus anything those processes started in groups of their own
2. sends SIGTERM to all of them, so they can shut down cleanly
3. waits up to 3 seconds, then sends SIGKILL to anything left

It narrows the target to the server and its children when the group includes Claude, this app, an interactive shell with a terminal, or another user's process. That can happen when a server shares a process group with the shell that launched it, and the check stops a click from taking a Terminal tab down with it.

Each process is identified by its ID *and* start time throughout, so a recycled ID is never signalled.

Special cases:

- **Registered stop command.** If the agent gave one (`--stop-cmd "docker compose stop api"`), Stop runs that with `zsh -lc` in the registered folder instead of sending signals, with a 60-second limit.
- **Docker under Colima.** Colima forwards every container's ports through one `ssh` process. Killing it would cut off every container, so Stop is disabled for those rows unless a stop command was registered.
- **launchd jobs.** Rows for processes launchd keeps alive say "restarts automatically", and the Stop tooltip warns that launchd will start them again.

## Terminal

Terminal's AppleScript dictionary lists each tab's `tty`, and the Claude process's controlling terminal is known from libproc. Go to the Claude terminal selects the matching tab, moves its window to the front and activates Terminal. Resume runs `cd <folder> && <resume command>` with `do script`, which opens a new window.

Both need the Automation permission for Terminal. The app asks for it with `NSAppleEventsUsageDescription`. If it's refused, AppleScript returns error -1743, and the app shows a banner linking to the right pane in System Settings.

## The command and the skill

The app and the `localhosts` command are one binary. When it's started as `localhosts`, or with `list`, `add`, `stop` or `help` as its first argument, it runs the command and exits, without starting the menu bar app. The app links `~/.local/bin/localhosts` to itself each time it opens from `/Applications`, and only replaces a link that already points at a copy of Localhosts.

The skill is bundled in the app and copied to `~/.claude/skills/localhosts/SKILL.md` when it changes. It's written for agents. It asks them to check `localhosts list` before starting anything, which cuts down on duplicate servers more than any amount of cleaning up afterwards.

## Not yet

- Notarised builds and update checks
- Bringing tabs forward in iTerm, Ghostty, and editor terminals
