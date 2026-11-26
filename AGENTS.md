# T3 Notch: notes for agents

A Swift Package with no dependencies. The UI is SwiftUI inside an AppKit `NSPanel`. Build it with
`make app`, or install and run it with `make install`. Both make **T3 Notch Dev** (bundle id
`dev.t3notch.app.dev`, `BuildInfo.isDev`), which runs beside the release in /Applications and does not
self-update. `make install` quits and replaces only the dev copy.

## Files

- `Sources/T3Notch/RPCClient.swift`: T3's Effect RPC over WebSocket, with JSON serialization.
- `Sources/T3Notch/Store.swift`: the state. Covers the shell and thread streams, which thread prompts go
  to, sending, approvals, and protocol-break handling.
- `Sources/T3Notch/NotchPanel.swift`: the panel, notch geometry, and keyboard shortcuts.
- `Sources/T3Notch/OverlayView.swift`: the SwiftUI view.
- `Sources/T3Notch/Permissions.swift` and `PermissionGuide.swift`: Screen Recording and Accessibility. A
  request resets the app's own TCC entry first (a grant made under another signature shows on but never
  matches), then asks again; the guide card sits by System Settings until both are on. Check the card with
  `--permission-guide [accessibility]`.
- `Sources/T3Notch/Onboarding.swift`: the welcome tour, in the island. Real key presses drive it. A step's
  success is one moment: the keys bottom out and spring back, light spreads from the last key, the island
  stretches, and a note and a trackpad tap land with it. Check a step with `--onboarding [step]`.
  Its Select step takes the tap of `SelectTrigger` and then starts the real select mode; it draws the keys
  from `SelectTrigger.keycaps` and is left out while the tap is off.
- `Sources/T3Notch/BuildInfo.swift`: the T3 version and commit the client was last fixed against.

## The T3 protocol in use

The source of truth is `packages/contracts/src/orchestrationV2.ts` and `rpc.ts` in
github.com/pingdotgg/t3code. Their backpressure rule is in `apps/server/src/terminal/OutputProtocol.ts`.

### Connecting

1. `POST /api/auth/websocket-ticket/rpc` with `Authorization: Bearer <token>`. It returns `{ticket}`.
2. Open `ws://127.0.0.1:<port>/ws?wsTicket=<ticket>&orchestrationProtocol=2`.

### Frames

- **Client to server**:
  - `{"_tag":"Request","id","tag","payload","headers":[]}`
  - `{"_tag":"Ack","requestId"}` after every `Chunk`. Streams stall after 8 un-acked chunks.
  - `{"_tag":"Interrupt","requestId","interruptors":[]}`
  - `{"_tag":"Ping"}`
- **Server to client**:
  - `{"_tag":"Chunk","requestId","values":[...]}`
  - `{"_tag":"Exit","requestId","exit":{"_tag":"Success","value"}|{"_tag":"Failure","cause"}}`
  - `{"_tag":"Pong"}`

### Methods

- `orchestration.subscribeShell` with `{}`.
  - It first sends a `snapshot`. That snapshot has `threads`, `projects` and `archivedThreads`.
  - After that it sends `thread.updated`, `thread.removed`, `project.updated` and `project.removed`.
- `orchestration.subscribeThread` with `{threadId, acceptBoundedSnapshot: true}`.
  - It sends a `snapshot` with a `projection`. The overlay uses `projection.messages`, `projection.runtimeRequests` and `projection.turnItems` from it.
  - After that it sends `event` items. The overlay handles three event types: `message.updated`, `runtime-request.updated` and `turn-item.updated`.
  - Leave out `acceptCompactIds` and `acceptCompactTurnItems`. If you send them, the server switches to an ID-table encoding.
- `orchestration.dispatchCommand` takes one of these commands:
  - `message.dispatch`: `{commandId, threadId, messageId, text, attachments: [], dispatchMode: {type: "queue_after_active"}, createdBy: "user", creationSource: "web"}`.
  - `runtime-request.respond`: `{commandId, threadId, requestId, decision}` for an approval. For a user-input question, send `answers` (by question id) in place of `decision`.
  - `run.interrupt`: `{commandId, threadId, runId}`.

### Which thread is the target

The chat picked in the ⌘K list (`Store.focusedThreadId`, kept in UserDefaults). There is no default;
with none, or once it is archived or deleted, opening the island shows the list. The list follows
T3's sidebar order (`packages/client-runtime/src/state/threadSort.ts`): pinned by `pinOrderKey`, then
active by `activeOrderKey`, then settled or snoozed ones by latest activity. Rows mirror
`apps/web/src/components/sidebar/SidebarThreadRow.tsx` (`ThreadRow.swift`).

## Fixing a protocol break

1. Diff `packages/contracts` between `BuildInfo.builtAgainstT3Commit` and the running T3 version.
2. Fix the client against what changed.
3. Update `BuildInfo.swift`.
4. Run `make install` and confirm that the menu bar shows "Connected".

## Recording the demo

`T3Notch --demo --demo-shots <dir>` (from `.build/release/`) runs a scripted tour on a fake desktop with fake
chats, showing each shortcut as keycaps bottom-right, saves stills to `<dir>`, and quits (~41s). It never
connects to T3. Quit the installed app first, record the screen meanwhile (`screencapture -v -V 46 demo.mov`),
then trim to the fake desktop and encode `docs/demo.mp4` and `docs/demo.gif`. The script is in `Demo.swift`.
