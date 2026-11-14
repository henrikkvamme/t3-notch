# T3 Notch

A small macOS overlay for [T3 Code](https://github.com/pingdotgg/t3code). Press ⌥Space in any app, and a
bar opens out of the notch. Type a prompt and it goes to the T3 thread you used last. The agent's latest
reply streams in above the input.

## Use

| Key | Action |
| --- | --- |
| ⌥Space | Show or hide the overlay |
| ⏎ | Send (or Accept a pending approval when the input is empty) |
| ⌘⏎ | Accept the approval for this session |
| ⎋ | Decline a pending approval, otherwise close |
| ⌘K | Send the next prompt to another thread |
| ⌘. | Stop the running agent |

- **Target thread**: the thread you most recently opened in T3 or sent a message to.
- **Status dot**: while the overlay is hidden, a dot right of the notch shows the target thread: grey idle, pulsing green running, orange needs you, red failed, blue check for a reply you haven't seen. Click it to open the overlay.
- **Peek**: while an agent runs, hover over the notch to see its reply.
- **Done**: when a run you started here finishes, the reply appears for 8 seconds.
- **Needs you**: when the agent asks for approval or a question, the overlay opens and stays open.

On a screen without a notch, the overlay draws one at the top centre.

## Build

Needs macOS 15+ and Swift 6.

```sh
make install   # builds, copies to ~/Applications, and starts it
```

Turn on **Launch at Login** from the menu bar icon.

## How it talks to T3

The overlay reads `~/.t3/userdata/server-runtime.json` to find the local T3 server. On first run it
gets a token with `t3 auth session issue --label notch-overlay` and keeps it in `~/Library/Application Support/T3Notch/token` (mode 0600). It is a file rather than the Keychain because the app is ad-hoc signed: each rebuild would trigger a Keychain prompt. The token
only has the `orchestration:read` and `orchestration:operate` scopes. To revoke it, remove it in T3.

The overlay then connects to T3's internal WebSocket RPC at `/ws`. This is the same protocol T3's own
UI uses. It is not a public API, so a T3 update can break it. When that happens, the overlay shows
**T3 protocol changed**. Click **Open fix draft in T3** to open a T3 draft prompt in this repo (via the desktop app's `t3code://new` link, so no browser tab). The
draft has the frame log and the T3 versions, so an agent can fix the client.

See [AGENTS.md](AGENTS.md) for how the client is built.
