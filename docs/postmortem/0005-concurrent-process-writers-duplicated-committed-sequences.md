# Post-mortem 0005: Concurrent processes duplicated a session log's committed sequences

English | [中文](0005-concurrent-process-writers-duplicated-committed-sequences.zh.md)

Status: resolved (append-time extent guard in the JSONL backend; cross-process liveness still outstanding)

## Executive summary

Two `dsh web` servers sharing one `~/.dsh` home loaded the same session and both appended to its log. One held a live turn waiting on a long `pwsh` call; the other found an open turn in the stored prefix, synthesized crash-repair closers, and committed them at the sequence numbers the live turn was about to use. When the tool returned, the live turn appended its real result at those same four sequence numbers, so the committed region contained each of them twice and the reader refused the whole artifact: the session could no longer be resumed, and its remaining 11,078 genuine events became unreachable through every product reader. Per-process ownership tracking, a prepare-time revision check, and an append path that rolls back only its own partial writes left no code able to observe the other writer, and no test drove two processes against one session. The lasting lesson is that a session artifact needs a liveness or ownership signal outside the log before any writer appends to it; until one exists, two entry points on one session corrupt it silently.

## Summary

The JSONL backend appends one logical batch per commit, each batch as an independent checksummed Zstandard frame, and every reader concatenates frames, requires contiguous `seq` values, and refuses a discontinuity inside the committed region (`format.ts:362` in `dsh-session-persistence-jsonl`). Crash recovery therefore has a narrow job: when a stored prefix ends with an open turn, [`interruptedTurnClosers`](../../packages/core/session/src/repair.ts) synthesizes the missing `tool/result`, `step/end`, and `turn/end`, numbered from the last stored event's `seq + 1`, and [`commitPrepared`](../../packages/session/session-persistence/src/coordinator.ts) commits them through `commitRepair`.

Every one of those decisions is scoped to one process. Ownership lives in the coordinator's in-memory maps, so `commitPrepared` refuses only a second owner it can see, and `isPreparedSourceCurrent` compares only the revision read while preparing. [`appendLines`](../../packages/session/session-persistence-jsonl/src/index.ts) opens the log in append mode and rolls back a partial write of its own batch, but never asks whether another writer extended the file since this owner's cursor.

Repair numbering is what made the two writers collide. A repair derives its first `seq` from the stored prefix it loaded, and a live writer's next `seq` is its in-memory event count, which for the same prefix is the same number. Each writer was correct in isolation; together they wrote the same sequences twice.

The reader's refusal is the designed behavior, and the gap was already recorded: [session.md](../subsystems/session.md) states that tolerating concurrent writers needs a liveness signal beyond the log, the [end-seed boundary note](../../.agents/notes/implemented/architecture/2026-07-30-session-end-seed-log-boundary.md) repeats that a boundary is not a liveness signal about other writers, and the [continuable-subagent note](../../.agents/notes/implemented/feature/2026-07-28-continuable-subagent-conversations.md) records that the process-local ownership graph does not coordinate two harness processes. No signal was built because the failure had no observed instance.

## Impact

The affected session (`Install dsh web UI plugins`, `session-fec7b85f-358a-4984-80a6-846800e8091c`) became unusable. The GUI reported `internal: resume failed for session "…": Error: corrupt session log: seq gap in committed region at line 3788 (expected 68382, got 68378)` from [`agent-lookup.ts`](../../packages/api/remotes/src/agent-lookup.ts), history load failed with the same scanner refusal, and the transcript the user was reading stopped advancing.

No event bytes were lost, and the damage was confined to four duplicated sequences. Availability was the whole cost: every reader starts at the duplicate, so 11,078 intact later events (seq 68378–79855), including the tool result the live turn was waiting for, were unreachable from the GUI, the CLI, and any SDK client.

The reproduction cost is ordinary desktop usage rather than an exotic deployment: any two entry points that share a home, whether two Web ports or a Web server beside a CLI or ACP writer, reach it by opening the same session.

## Evidence

The artifact was `~/.dsh/sessions/--C-selfDIr-Tools-dsh-dsh-zackary--/session-fec7b85f-358a-4984-80a6-846800e8091c/session.jsonl.zstd`: 1,219,286 bytes, 2,244 Zstandard frames, 4,397 records, highest logical `seq` 79,855. Decoding every frame in order gives one contiguous prefix up to `seq 68381` and then a second branch that restarts at `seq 68378` and runs contiguously to the end.

| seq | event | time | writer |
| --- | --- | --- | --- |
| 68377 | `tool/call` `pwsh` `call_00_ET_HHsHjR42OHhZxH9G5iSe8184` | 1789703626817 | live turn |
| 68378 | `tool/result`, msgId `interrupted-tool-result-…-68378`, error `TOOL_OUTCOME_UNKNOWN` | 1789703626817 | crash repair |
| 68379 | `step/end` turn 2 step 76 | 1789703626817 | crash repair |
| 68380 | `turn/end` turn 2 `{kind:"interrupted"}` | 1789703626817 | crash repair |
| 68381 | `session/end-seed` | 1789703635837 | repair's seeded `Session` |
| 68378 | `tool/result`, real result of the same call | 1789703664192 | live turn |
| 68379 | `step/end` turn 2 step 76 | 1789703664194 | live turn |
| 68380 | `step/start` turn 2 step 77 | 1789703664242 | live turn |
| 68381–79855 | `assistant/chunk` and later events to the log tail | — | live turn |

The repair block landed 9.0 seconds after the tool call, while the tool was still running, and the real result arrived 37.4 seconds after it. Frame 1917 carries the three closers, frame 1918 the `session/end-seed` marker, and frame 1919 the real `tool/result` with its `step/end` — so each writer's contribution is a whole frame, and the overlap is visible at frame granularity without decoding.

Scanning the artifact with the backend's own `SessionLogScanner` reproduces the product error exactly: `corrupt session log: seq gap in committed region at line 3788 (expected 68382, got 68378)`. That line number is the scanner's event-row counter, which excludes the header record; the offending record sits on physical line 3789.

Two processes were running against this home when the artifacts were inspected: `@deepseek-ai/dsh/lib/bin.js web --port 43120` (installed build) and `node --import tsx/esm apps/cli/src/bin.ts web --port 43123` (the source build whose window reported the failure). The artifact alone cannot attribute a frame to a PID, so the pairing is the observed configuration, not proof of which port wrote which frame.

A second session in the same home carries the same collision with no crash repair involved. `session-da0c4819-1b86-44b0-a791-4c5494a47578` (cwd `C:\workDir\Download\C++简历`, 1,151 frames, highest `seq` 45,845) records its creation facts as `seq` 0–2, then `session/end-seed` at `seq` 3 another 129 seconds later — the seed boundary of a `Session` a second process constructed from that stored prefix — and then `agent/inbox/spliced` at `seq` 3 as well, 239 seconds after the marker, from the live session whose in-memory event count was still three. The two collisions are 17.8 minutes apart, and this one happened first.

## Timeline

- A live turn on one process logs `tool/call` for a long-running `pwsh` command and awaits its result.
- 9.0 seconds later, a second process loads the same session, finds an open turn, commits the synthesized closers and its seed boundary, and thereby advances the durable log past the live writer's cursor.
- 37.4 seconds after the call, the live turn appends the real `tool/result` at `seq 68378` and continues the turn to `seq 79855`, using sequence numbers that are already taken.
- A later resume scans the artifact, stops the preserved prefix at the duplicate, and refuses it; the GUI surfaces the refusal as a failed model operation and a failed history load.
- Recovery dropped the two fabricated frames, and the artifact scanned clean on the backend's own reader.

## Root cause

Ownership is per process. The coordinator's `states` and `live` maps, its `already has a live persistence owner` refusal, and its prepared-source revision check all describe writers inside one process, and no mechanism lets a process discover that another process owns the session.

Repair numbering assumes the stored prefix is the newest state. `interruptedTurnClosers` derives closers from what it loaded, which is sound only while no other writer has advanced that prefix; the live writer's event count reaches the same value independently.

The collision does not require crash repair. Constructing a `Session` from a stored prefix also writes that seed's `session/end-seed` boundary at the next `seq`, which collides with a live writer still counting from the same prefix; the second affected session duplicates on that boundary alone.

The append path cannot detect a foreign writer. `appendLines` verifies only its own write, and a batch appended at a stale sequence base is well-formed bytes that the reader can only reject later.

No gate covers the configuration. All persistence suites drive one coordinator per process, because there is no cross-process mechanism for them to assert, and the deployment shape that produced this incident — two instances of the same product on one home — has no warning, lock, or documented prohibition.

## Recovery

Dropping frames 1917 and 1918 removed only fabricated events. Each frame decodes independently, so the repair needed neither recompression nor renumbering, and every `sourceEventSeqs` reference in the surviving events still names the sequence it recorded.

The rebuilt artifact passes the backend's own `SessionLogScanner` and Zstandard frame decoder: 2,242 frames, 79,856 events, contiguous sequences 0–79855, and a committed prefix equal to the whole file, so no torn tail remains. It ends on `step/start`, so the next load appends ordinary crash closers for that open step.

The original bytes remain beside the artifact as `session.jsonl.zstd.corrupt-20260918-115823.bak`. Discovery matches only `*.jsonl` and `*.jsonl.zstd`, so the backup is invisible to `list()` and to resume.

A second artifact, `session-da0c4819-…`, was repaired the same way by dropping its duplicated seed-boundary frame, and its original bytes are preserved as `session.jsonl.zstd.corrupt-20260918-114024.bak`. Its remaining 45,846 events are contiguous from `seq` 0 to 45,845, and the log ends on a closed `turn/end`, so no closers are due. A scan of all 52 session artifacts under this home, 3,462,225 events, reports no refusal and no torn tail.

This recovery repairs two artifacts. It does not prevent recurrence, which the guardrails below own.

## Guardrails added

The JSONL backend now refuses a durable mutation whose artifact no longer continues the extent its writer observed, raising `SessionPersistenceConflictError` before any byte changes ([Agent Note](../../.agents/notes/implemented/bug-fix/2026-09-18-session-artifact-concurrent-writer-refusal.md)). Three package tests pin the append refusal, the refusal after a detached read re-observes the foreign artifact, and the refused truncate repair that would have discarded another writer's committed turn; a keyless assembled scenario pins the product-facing refusal text. The remaining options below are outstanding, and deliberate cross-process sharing still needs one of them.

- **Append-time extent guard (shipped).** Each complete read and every durable write records the artifact's byte length and committed event count, and an append or truncate repair that no longer continues that extent is refused with a conflict error. Backend-local, and it turns silent corruption into a loud failure; it does not let a second process work on the session, only stop damaging it.
- **Session claim with liveness.** One owner record per session (process identity plus a heartbeat or start time, with stale takeover after a crash) gives real cross-process exclusion for every entry point, at the cost of owning staleness, takeover, and teardown semantics.
- **Instance guard per home.** Refusing a second session-writing entry point on one home covers the reported configuration cheaply, but blocks legitimate multi-instance use and does not cover mixed Web, CLI, and ACP writers.
- **Reader-side tolerance.** Advancing the preserved prefix past a duplicated region would serve history that never happened in that order, and truncating at it would discard 11,078 genuine events; the refusal is correct and the defect is upstream. A deliberate recovery operation for a duplicated committed region is a separate product decision, not a reader default.

## Lessons

- A per-process lock is not exclusion once one artifact can have several writers; a log that can only be appended needs a signal outside itself before the first append.
- Deterministic recovery is unsound without liveness. Synthesizing closers from a stored prefix asserts that the turn ended, which is true of a crash and false of a live writer still holding it.
- Correcting the artifact after the fact needs a documented reader-independent path. The scanner's refusal preserves truth but strands the work behind it, so recovery depends on knowing the physical frame layout.
- A configuration with no guard and no warning is a defect surface. Two entry points on one home look supported, and nothing in the product said otherwise until a session became unreadable.
