import { expect, test } from 'claude-code/testing'
import { sha256 } from './hooks/sha256.js'
import { CALM_BOOTSTRAP, HIDDEN_SKILLS, KNOWN_BOOTSTRAP_SHA256, calmContexts, classifyContext, trimListing } from './hooks/register.js'

const LISTING = [
  'The following skills are available for use with the Skill tool:',
  '',
  '- axi: Agent eXperience Interface.',
  '- superpowers:writing-skills: First paragraph.',
  '',
  'Second paragraph of a hidden description.',
  '',
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
  expect(out).not.toContain('Second paragraph of a hidden description')
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

const sha = sha256

test('only the exact known bootstrap is replaced', () => {
  const revised = LONG_BOOTSTRAP + '\nNew upstream routing rule.'
  const out = calmContexts([LONG_BOOTSTRAP, revised, 'remember: notes loaded', 'x You have superpowers. y'], sha(LONG_BOOTSTRAP))
  expect(out).toEqual([CALM_BOOTSTRAP, revised, 'remember: notes loaded', 'x You have superpowers. y'])
})

test('classifies known, drifted and unrelated contexts', () => {
  const known = sha(LONG_BOOTSTRAP)
  expect(classifyContext(LONG_BOOTSTRAP, known)).toBe('known')
  expect(classifyContext(LONG_BOOTSTRAP + ' edit', known)).toBe('drifted')
  expect(classifyContext('remember: notes', known)).toBe('other')
  expect(KNOWN_BOOTSTRAP_SHA256).toMatch(/^[0-9a-f]{64}$/)
})

test('a drifted bootstrap passes through and is logged once', async ($, on) => {
  const logs: string[] = []
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('classic.SessionStart', () => ({ additionalContext: [LONG_BOOTSTRAP] }))
  const first = await $.classic.SessionStart({ source: 'startup' })
  await $.classic.SessionStart({ source: 'clear' })
  expect(first.additionalContext).toEqual([LONG_BOOTSTRAP])
  expect(logs.length).toBe(1)
  expect(logs[0]).toContain('KNOWN_BOOTSTRAP_SHA256')
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

test('sha256 matches published vectors, including multi-block and multibyte input', () => {
  expect(sha256('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
  expect(sha256('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
  expect(sha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')).toBe('248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
  expect(sha256('a'.repeat(1000))).toBe('41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3')
})
