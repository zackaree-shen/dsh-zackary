/**
 * Assembled-app regression for the concurrent-writer refusal: resuming a
 * session whose artifact another process then advances fails loud through the
 * real Loader composition, and the refusal the product user sees names the
 * session instead of silently repeating committed sequence numbers.
 * @module session-write-conflict-snapshot
 */

import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import { LOADER_SMOKE_TEST_TIMEOUT_MS, runLoaderSmoke } from '@deepseek-ai/dsh-loader-smoke'
import SessionStore, {
  SESSION_FORMAT_VERSION,
  SessionId,
  type SessionEvent,
  type SessionHeader,
} from '@deepseek-ai/dsh-session'
import JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import { describe, expect, it } from 'vitest'

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'workspace-context-resume-snapshots/offline-edit')
const replayFixture = join(fixtureDir, 'replay.jsonl')
const replayOverride = join(fixtureDir, 'replay.override.json')
const configPath = fileURLToPath(new URL('../session-write-conflict.cordis.snapshot.yml', import.meta.url))
const binScript = fileURLToPath(new URL('./fixtures/headless-driver.ts', import.meta.url))
const tsconfigPath = fileURLToPath(new URL('../../../tsconfig.json', import.meta.url))
// The fixture in the shared config resumes exactly this id.
const sessionId = SessionId('session-write-conflict')

/** Persist one closed-turn session for the fixture to resume. */
async function seedSession(root: string, cwd: string): Promise<void> {
  const ctx = new Context()
  await ctx.plugin(SessionStore)
  await ctx.plugin(JsonlSessionPersistence, { root, compression: 'none' })
  const meta: SessionHeader = { version: SESSION_FORMAT_VERSION, id: sessionId, createdAt: 1, cwd }
  const events: SessionEvent[] = [
    { type: 'turn/start', seq: 0, time: 1, data: { turn: 1 } },
    { type: 'turn/end', seq: 1, time: 2, data: { turn: 1, reason: { kind: 'completed' } } },
  ]
  try {
    await ctx.sessionPersistence.create(meta)
    await ctx.sessionPersistence.append(sessionId, events)
  } finally {
    await ctx.fiber.dispose()
  }
}

describe('concurrent-writer refusal through the assembled app', () => {
  it('fails loud when another writer advanced the resumed session artifact', async () => {
    const result = await runLoaderSmoke({
      label: 'concurrent-writer refusal',
      tempDirPrefix: 'dsh-write-conflict-',
      binScript,
      libBinScript: binScript,
      configPath,
      binArgs: [configPath, 'Report what happened.'],
      tsconfigPath,
      env: { DSH_SNAPSHOT_FILE: replayFixture, DSH_SNAPSHOT_OVERRIDE: replayOverride },
      expectedExitCode: 1,
      prepare: async (runCwd) => {
        await seedSession(join(runCwd, '.sessions'), runCwd)
      },
    })
    // Exact byte counts depend on which prefix the resumed writer had flushed, so
    // the assertion pins the stable refusal text and its named subject.
    expect(result.stderr).toContain(`session "${sessionId}" changed on disk since this writer observed it`)
    expect(result.stderr).toContain('another process is writing this session')
    expect(result.stderr).toContain('would repeat sequence numbers it already committed')
  }, LOADER_SMOKE_TEST_TIMEOUT_MS)
})
