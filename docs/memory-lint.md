# Memory hygiene check

`~/.local/bin/memory-lint` reads Claude Code's auto-memory under
`~/.claude/projects/*/memory` and flags memory that is lost or bloated. It is
read-only: it never edits, moves or deletes a note. Acting on a finding is a
manual step.

## What it flags

| Section | Flags | Why it matters |
|---|---|---|
| `orphans` | A memory dir whose project dir will never be opened again: a T3 scratch thread (`scratch`), a path under `/tmp` or `/var/tmp` (`tmp`), or a path that no longer exists, such as a deleted worktree (`missing`) | Memory loads only for sessions started in that exact directory, so these notes never load again |
| `duplicates` | The same file name in two dirs (`name`), or near-identical text under different names (`content`) | Copies drift apart, and a correction lands in only one of them |
| `long_indexes` | A `MEMORY.md` over 50 lines | The index loads into every session in that dir |

The project path comes from the `cwd` recorded in the dir's transcripts. A dir
with no transcripts is matched against the filesystem instead. Near-identical
means a word-shingle Jaccard score of at least 0.8 between notes in different
dirs. Notes under 20 words are not compared, and neither are two notes in the
same dir. A `name` row shows `n/a` similarity when one side is too short to
compare. Memory dirs with no notes are only counted (`empty_dirs`).

## Running it

```sh
memory-lint                     # the report, in TOON
memory-lint --full              # also list every note in each orphaned dir
memory-lint --json              # the same data as JSON
memory-lint --index-lines 40 --similarity 0.9
```

`MEMORY_LINT_ROOT` overrides the projects dir, and `MEMORY_LINT_TMP_PREFIXES`
(colon-separated) the throwaway path prefixes.

## Fixing what it finds

- **Orphans:** move a note that is still true into the memory dir of the
  stream's grouping folder (`~/projects/<owner>`) and add it to that index.
- **Duplicates:** keep one copy, in the broadest dir whose sessions need it.
- **Long indexes:** one short line per note; fold or delete stale entries.
