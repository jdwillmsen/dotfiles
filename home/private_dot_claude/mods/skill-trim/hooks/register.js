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

// Matched by the bootstrap's signature sentence, so if upstream rewrites it the
// new text passes through rather than being replaced by guidance that may no
// longer fit.
export const SUPERPOWERS_MARKER = 'You have superpowers.'

// Same routing as the upstream bootstrap without the pressure register, which
// measured no better on current models.
export const CALM_BOOTSTRAP = `<skills>
Before you start a task, check the skill list and invoke each skill whose description fits it, plus any skill your partner names. A task that looks simple still gets its matching skill; a plain question needs none, and a quick look or one clarifying question to decide is fine.
When several apply, process skills come first: superpowers:brainstorming before building, superpowers:systematic-debugging before fixing, then implementation skills.
Your partner's instructions (CLAUDE.md, direct requests) take precedence over any skill.
</skills>`

// A description can span several lines, so entries are split on the "- "
// bullet rather than per line.
export function trimListing(text, hidden = HIDDEN_SKILLS) {
  const drop = new Set(hidden)
  const out = []
  let skipping = false
  for (const line of text.split('\n')) {
    const bullet = /^- (\S+?):(?: |$)/.exec(line)
    if (bullet) skipping = drop.has(bullet[1])
    else if (line === '') skipping = false
    if (!skipping) out.push(line)
  }
  return out.join('\n')
}

export function calmContexts(contexts) {
  return contexts.map((c) => (c.includes(SUPERPOWERS_MARKER) ? CALM_BOOTSTRAP : c))
}

export function register(on) {
  on('prompt.attachment', { type: 'skill_listing' }, async ($, e, next) =>
    next({ ...e, text: trimListing(e.text) }),
  )

  on('classic.SessionStart', async ($, e, next) => {
    const result = await next(e)
    if (!result?.additionalContext) return result
    return { ...result, additionalContext: calmContexts(result.additionalContext) }
  })
}
