import { expect, test } from 'claude-code/testing'
import { CALM_BOOTSTRAP, HIDDEN_SKILLS, trimListing } from './hooks/register.js'

const LISTING = [
  'The following skills are available for use with the Skill tool:',
  '',
  '- axi: Agent eXperience Interface.',
  '- mattpocock-skills:tdd: Test-driven development.',
  '- claude-api: Reference for the Claude API.',
  'TRIGGER — read BEFORE opening the target file.',
  '- atlassian:triage-issue: Triage bug reports.',
  'A continuation line of a hidden skill.',
  '- superpowers:brainstorming: You MUST use this before any creative work.',
].join('\n')

const LONG_BOOTSTRAP = '<EXTREMELY_IMPORTANT>\nYou have superpowers.\n\nIF A SKILL APPLIES YOU MUST USE IT.\n</EXTREMELY_IMPORTANT>'

test('drops hidden namespaced skills with their continuation lines', () => {
  const out = trimListing(LISTING)
  expect(out).not.toContain('mattpocock-skills:tdd')
  expect(out).not.toContain('atlassian:triage-issue')
  expect(out).not.toContain('continuation line of a hidden skill')
})

test('keeps visible skills and their continuation lines', () => {
  const out = trimListing(LISTING)
  expect(out).toContain('- axi: Agent eXperience Interface.')
  expect(out).toContain('TRIGGER — read BEFORE opening the target file.')
  expect(out).toContain('- superpowers:brainstorming:')
  expect(out).toContain('The following skills are available')
})

test('hides exactly the fifteen agreed skills', () => {
  expect(HIDDEN_SKILLS.length).toBe(15)
})

test('the skill listing reaching Claude is trimmed', async ($, on) => {
  on('prompt.attachment', ($, e) => ({ text: e.text }))
  const r = await $.prompt.attachment({ type: 'skill_listing', text: LISTING, origin: { kind: 'engine' } })
  expect(r.text).not.toContain('mattpocock-skills:tdd')
  expect(r.text).toContain('superpowers:brainstorming')
})

test('other attachments pass through untouched', async ($, on) => {
  on('prompt.attachment', ($, e) => ({ text: e.text }))
  const r = await $.prompt.attachment({ type: 'date', text: LISTING, origin: { kind: 'engine' } })
  expect(r.text).toBe(LISTING)
})

test('the superpowers bootstrap is replaced and other contexts kept', async ($, on) => {
  on('classic.SessionStart', () => ({ additionalContext: [LONG_BOOTSTRAP, 'remember: notes loaded'] }))
  const r = await $.classic.SessionStart({ source: 'startup' })
  expect(r.additionalContext).toEqual([CALM_BOOTSTRAP, 'remember: notes loaded'])
})

test('the calm bootstrap keeps the routing rules and stays small', () => {
  expect(CALM_BOOTSTRAP).toContain('superpowers:brainstorming')
  expect(CALM_BOOTSTRAP).toContain('superpowers:systematic-debugging')
  expect(CALM_BOOTSTRAP).toContain('CLAUDE.md')
  expect(CALM_BOOTSTRAP).not.toMatch(/MUST|EXTREMELY/)
  expect(new TextEncoder().encode(CALM_BOOTSTRAP).length < 600).toBe(true)
})

test('a SessionStart with no context is left alone', async ($, on) => {
  on('classic.SessionStart', () => ({}))
  const r = await $.classic.SessionStart({ source: 'clear' })
  expect(r.additionalContext).toBeUndefined()
})
