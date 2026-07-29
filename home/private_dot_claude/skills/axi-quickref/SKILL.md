---
name: axi-quickref
description: >
  Fast reference card for AXI (Agent eXperience Interface) — the 10 ergonomic principles for
  CLIs that agents run via shell. Use for a quick check when building/reviewing an agent-facing
  CLI. For full scaffolding, TOON details, and examples, defer to the `axi` skill.
---

# AXI Quick Reference

AXI = **Agent eXperience Interface**: design standards for CLI tools autonomous agents drive via shell.
Benchmarked ahead of both raw CLI and MCP on success, cost, duration, and turns.

> Full guidance, TOON spec links, and worked examples live in the **`axi`** skill (`~/.agents/skills/axi`).
> This card is the fast checklist. Source: https://axi.md · https://github.com/kunchenguid/axi

## The 10 principles

### Efficiency
1. **Token-efficient output** — [TOON](https://toonformat.dev/) on stdout (~40% fewer tokens than JSON). Convert at the output boundary; keep internal logic on JSON.
2. **Minimal default schemas** — 3–4 fields per list item; more via `--fields`.
3. **Content truncation** — cap large text, append size hint: `(truncated, N chars total — use --full)`.

### Robustness
4. **Pre-computed aggregates** — return `totalCount`, inline CI/status summaries, combined ops → kill round-trips.
5. **Definitive empty states** — explicit zero-result message, never silent empty output.
6. **Structured errors & exit codes** — idempotent mutations; structured errors to **stdout**; never prompt interactively; `0` ok / `1` err.

### Discoverability
7. **Ambient context** — setup command installs into session hooks/plugins so state is visible before the agent acts; ship a SKILL.md.
8. **Content first** — no-args prints live actionable data (+ exec path + one-line description), not help text.
9. **Contextual disclosure** — append `help[]` next-step command templates; carry disambiguating flags, use `<id>` placeholders.
10. **Consistent help** — every subcommand has a concise `--help` fallback.

## Reference implementations
- GitHub: `npx -y gh-axi`
- Browser: `npx -y chrome-devtools-axi`
- Scaffold a new one / full guidelines: `npx skills add kunchenguid/axi` (installs the `axi` skill)
