# Agent Note: Refuse a session-artifact append that no longer continues the observed extent

Status: implemented

English | [中文](2026-09-18-session-artifact-concurrent-writer-refusal.zh.md)

## Problem

Two `dsh` processes sharing one `~/.dsh` home loaded the same session and both appended to its `.jsonl.zstd` artifact. One held a live turn waiting on a long tool call; the other resumed the session, found an open turn in the stored prefix, and committed synthetic crash-repair closers at the sequence numbers the live turn was about to use. When the tool returned, the live turn appended its real result at those same numbers, so the committed region contained each of them twice and every reader refused the whole log. A second session in the same home carried the same collision with no crash repair involved: a resume wrote its `session/end-seed` boundary while the live writer's in-memory event count was still behind the artifact. [Postmortem 0005](../../../../docs/postmortem/0005-concurrent-process-writers-duplicated-committed-sequences.md) records both incidents, the recovery, and the guardrails still outstanding.

Exclusion was per process. The coordinator's owner maps refuse only an owner it can observe, `isPreparedSourceCurrent` compares only the revision read while preparing, and the JSONL append path rolled back only its own partial write. A writer whose base predated another writer's batch appended well-formed bytes that no reader could accept, and the only signal was a later refusal of the entire session.

## Decision

The JSONL backend records each artifact's **observed extent** — durable byte length and committed event count — and refuses a durable mutation that no longer continues it, raising `SessionPersistenceConflictError` (exported by `dsh-session-persistence`) before any byte changes. The refusal names the session, both byte lengths, and the consequence: the next events would repeat sequence numbers that are already committed.

Every complete prefix read (`readPrefix`) and every durable write (`materialize`, `appendLines`, `repair`) records the extent. A read records the *committed* event count, not the returned one: a torn final frame's recovered events are re-appended by a repair and are not durable until it runs, so the count must match the sequence base a repair continues from. `repair` re-records the truncated extent after it truncates, which is what lets the recovered events and closers append.

`appendLines` refuses when either field differs, and `repair` refuses when the byte length differs. The event count is checked alongside the byte length because a detached read also observes the artifact: `readFrom` (a projection cache folding a suffix) re-reads the same file, and re-observing another writer's log must not re-arm a stale writer's base. `materialize` records the extent it just published, so the first append of a lazily created session starts from its own bytes.

The assembled composition is pinned by `examples/headless-agent/tests/session-write-conflict.snapshot.ts`: a fixture resumes a seeded session through the public agent service and then advances that artifact from a second backend instance over the same root, and the run fails with the refusal text.

## Alternatives considered

**A read-intent parameter on `PersistenceBackend.loadStored`.** Passing `'adopt'` or `'read'` per call would stop a detached read from re-seeding the base, and that distinction is the reason the event count field exists. Rejected because the count check closes the same hole without widening the coordinator-to-backend contract: every existing `loadStored` call site, including third-party backends and test fakes, would have to name an intent that only one backend honors.

**Comparing the byte length alone.** Rejected: `readFrom` re-seeding the base after a foreign append would make the next stale append compare equal, silently restoring the corruption this change removes.

**A durable per-session lease or lock file.** The fix for processes that deliberately share a session. Deferred: it owns staleness, takeover, refusal copy, and teardown semantics, and no current consumer shares one session between processes. The guard converts the accidental case into a loud refusal first.

**Refusing a second instance per DSH home.** Covers the reported deployment but blocks legitimate multi-instance use (a source build beside an installed build) and does not cover a CLI or ACP writer beside a Web server. See the [postmortem's alternatives](../../../../docs/postmortem/0005-concurrent-process-writers-duplicated-committed-sequences.md).

**Teaching the reader to tolerate a duplicated region.** Rejected: the duplicate is committed data, so neither serving it nor truncating at it is faithful, and truncation would discard every genuine event after it.

## Consequences

A stale writer now fails loud on its next append or truncate repair instead of corrupting the log, and the log it left alone stays readable. The check narrows the race but cannot make an append atomic: a writer that opens the same artifact in the same instant can still append between the size check and this writer's write, so deliberate cross-process sharing still needs a liveness signal outside the log, and the coordinator adds no exclusion of its own. SQLite implements no equivalent guard, so the same class remains unmitigated for that backend.

Package coverage pins the append refusal, the refusal after a detached read re-observes the foreign artifact, and the refused truncate repair that would have discarded another writer's committed turn; each of the three fails when the guard is removed. The assembled scenario pins the product-facing refusal text through the real Loader.
