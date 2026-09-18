/**
 * Loader fixture for the concurrent-writer refusal: it resumes the seeded
 * session through the public agent service and then advances that session's
 * artifact through a SECOND persistence backend over the same root — the
 * deployment shape (two `dsh` processes sharing one home) whose concurrent
 * append duplicated committed sequence numbers.
 * @module session-write-conflict-writer
 */

import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'

/** Fixture plugin name. */
export const name = 'session-write-conflict-writer'
/** The resumed agent must own the artifact before this fixture advances it. */
export const inject = ['agents', 'agentLoop', 'sessionPersistence']

/** The session this scenario seeds, resumes, and then advances as a second writer. */
export const resumedSessionId = SessionId('session-write-conflict')

/**
 * Resume the seeded session, then append one event to its artifact through an
 * independent backend instance.
 * @param ctx - settled Loader context whose persistence root the fixture reopens.
 */
export async function apply(ctx: Context): Promise<void> {
  const handle = await ctx.agents.resume({
    resumeSessionId: resumedSessionId,
    agentOptions: { provider: 'deepseek-official', model: 'deepseek-v4-flash' },
  })
  ctx.effect(() => () => handle.dispose(), 'session-write-conflict-writer.handle')

  // A second Context is a second process in this deployment shape: its own store,
  // its own backend instance, and its own view of the same artifact.
  const other = new Context()
  await other.plugin(SessionStore)
  await other.plugin(JsonlSessionPersistence, {
    root: join(process.cwd(), '.sessions'),
    compression: 'none',
  })
  try {
    const stored = await other.sessionPersistence.load(resumedSessionId)
    await other.sessionPersistence.append(resumedSessionId, [{
      type: 'session/end-seed',
      seq: stored.events.length,
      time: 2,
      data: {},
    }])
  } finally {
    await other.fiber.dispose()
  }
}
