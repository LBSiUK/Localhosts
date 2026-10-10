---
name: localhosts
description: Use whenever you start a dev server, preview server or anything else that listens on a localhost port, and before you open a localhost URL in a browser. Lists the server in the Localhosts menu bar app (open it, stop it, jump to your Terminal tab) and lets you reuse a server that is already running instead of starting a duplicate.
---

# Localhosts

The user runs a menu bar app, Localhosts, that lists every server on their Mac under the
Claude session that started it. It finds servers you start from Bash by itself. This skill keeps
the list readable and stops duplicate servers piling up.

## Before you start a server

Run `localhosts list`. If a server for the same folder is already running (yours or another
session's), use it and give the user its URL instead of starting another. Rows marked
`this session` are yours.

## Starting one

1. Start it with the Bash tool's `run_in_background: true`. `&` and `nohup` work too. Do not
   clear the environment (`env -i`): the app reads `CLAUDE_PID` from it to find your tab.
2. Once it is listening, give it a label the user will recognise:

   ```
   localhosts add <port> --label "<project>: <what it serves>"
   ```

   `add` waits up to 15 s for the port to open. Options:
   - `--path /admin` when the useful page is not `/`
   - `--stop-cmd "docker compose stop <service>"` for a Docker container. Run `add` from the
     compose folder, because the stop command runs there. Without one the app won't stop a
     Colima port, since Colima's one forwarder carries every container's ports.

## Opening a localhost URL

Nothing extra to do for a server you started. If the port is not in `localhosts list`,
nothing is serving it: start the server first.

## When you're done

Leave running anything the user may still want to look at. Stop servers you started only for a
quick check with `localhosts stop <port>`, which stops the whole process group (npm, node,
workers). Never stop a server another session owns unless the user asks.

If `localhosts` is not on PATH, the same commands work as
`/Applications/Localhosts.app/Contents/MacOS/Localhosts list|add|stop`.
