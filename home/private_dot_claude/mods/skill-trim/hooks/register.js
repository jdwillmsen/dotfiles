// Skills stay registered, so the Skill tool still runs them by name; only the
// listing Claude reads each session drops them.
export const HIDDEN_SKILLS = [
  'atlassian:capture-tasks-from-meeting-notes',
  'atlassian:generate-status-report',
  'atlassian:jira-sprint-dashboard',
  'atlassian:search-company-knowledge',
  'atlassian:spec-to-backlog',
  'atlassian:triage-issue',
  'mattpocock-skills:tdd',
  'mattpocock-skills:prototype',
  'mattpocock-skills:domain-modeling',
  'mattpocock-skills:codebase-design',
  'mattpocock-skills:code-review',
  'mattpocock-skills:wizard',
  'mattpocock-skills:writing-for-agents',
  'superpowers:diagnosing-superpowers',
  'superpowers:writing-skills',
]

import { sha256 } from './sha256.js'

// Fingerprint of the one upstream bootstrap this mod was written against
// (superpowers 6.4.1). Anything else, including a revised bootstrap that still
// opens with SUPERPOWERS_MARKER, passes through so upstream changes are never
// discarded; refresh the hash after reviewing a new upstream version.
export const SUPERPOWERS_MARKER = 'You have superpowers.'
export const KNOWN_BOOTSTRAP_SHA256 = '48ebb41e10d7bb85c74ac04fd685a32c3b32ce789766e4a3ab3ba8a5546fe688'

// Same routing as the upstream bootstrap without the pressure register, which
// measured no better on current models.
export const CALM_BOOTSTRAP = `<skills>
Before you start a task, check the skill list and invoke each skill whose description fits it, plus any skill your partner names. A task that looks simple still gets its matching skill; a plain question needs none, and a quick look or one clarifying question to decide is fine.
When several apply, process skills come first: superpowers:brainstorming before building, superpowers:systematic-debugging before fixing, then implementation skills.
Your partner's instructions (CLAUDE.md, direct requests) take precedence over any skill.
</skills>`

// A description can span several lines and paragraphs, so a hidden entry is
// skipped until the next "- name:" bullet rather than the next blank line.
export function trimListing(text, hidden = HIDDEN_SKILLS) {
  const drop = new Set(hidden)
  const out = []
  let skipping = false
  for (const line of text.split('\n')) {
    const bullet = /^- (\S+?):(?: |$)/.exec(line)
    if (bullet) skipping = drop.has(bullet[1])
    if (!skipping) out.push(line)
  }
  return out.join('\n')
}

export function classifyContext(context, knownSha = KNOWN_BOOTSTRAP_SHA256) {
  if (!context.includes(SUPERPOWERS_MARKER)) return 'other'
  return sha256(context) === knownSha ? 'known' : 'drifted'
}

export function calmContexts(contexts, knownSha = KNOWN_BOOTSTRAP_SHA256) {
  return contexts.map((c) => (classifyContext(c, knownSha) === 'known' ? CALM_BOOTSTRAP : c))
}

export function register(on) {
  let warned = false

  on('prompt.attachment', { type: 'skill_listing' }, async ($, e, next) =>
    next({ ...e, text: trimListing(e.text) }),
  )

  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    if (!result?.additionalContext) return result
    if (!warned && result.additionalContext.some((c) => classifyContext(c) === 'drifted')) {
      warned = true
      $.ui.log('skill-trim: superpowers bootstrap changed upstream; leaving it verbose until KNOWN_BOOTSTRAP_SHA256 is refreshed')
    }
    return { ...result, additionalContext: calmContexts(result.additionalContext) }
  })
}
