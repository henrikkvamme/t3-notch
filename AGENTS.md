# T3 Notch: notes for agents

A Swift Package with no dependencies. The UI is SwiftUI inside an AppKit `NSPanel`. Build it with
`make app`, or install and run it with `make install`.

## Files

- `Sources/T3Notch/RPCClient.swift`: T3's Effect RPC over WebSocket, with JSON serialization.
- `Sources/T3Notch/Store.swift`: the state. Covers the shell and thread streams, which thread prompts go
  to, sending, approvals, and protocol-break handling.
- `Sources/T3Notch/NotchPanel.swift`: the panel, notch geometry, and keyboard shortcuts.
- `Sources/T3Notch/OverlayView.swift`: the SwiftUI view.
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

The ⌘K override, otherwise the top of T3's sidebar (`packages/client-runtime/src/state/threadSort.ts`):

1. Pinned threads (`pinnedAt` set), ordered by `pinOrderKey`. Unkeyed ones come after the keyed ones, newest `createdAt` first.
2. With nothing pinned: active threads (not settled, not snoozed), ordered by `activeOrderKey`. Unkeyed ones come first, newest of `createdAt`/`unsettledAt` first.

Archived, deleted and subagent child threads are skipped.

## Fixing a protocol break

1. Diff `packages/contracts` between `BuildInfo.builtAgainstT3Commit` and the running T3 version.
2. Fix the client against what changed.
3. Update `BuildInfo.swift`.
4. Run `make install` and confirm that the menu bar shows "Connected".
