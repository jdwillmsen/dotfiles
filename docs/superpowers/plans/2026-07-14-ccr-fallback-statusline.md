# CCR Fallback-Aware Statusline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-status` render the real CCR fallback backend (model, reasoning, context window, cost, rate limits) instead of Claude Code's misleading native labels, driven by env vars the picker stamps.

**Architecture:** The picker (`~/.claude-code-router/pick.sh`) exports three env vars before launching `claude`; the Go binary parses them into a `fallback` struct in `main()` and passes it to the pure `renderLines` function. Every fallback branch is a no-op when the struct is zero, so native `claude` and the shared opencode statusline are untouched.

**Tech Stack:** Go (stdlib only), Bash + Node one-liners in the picker.

## Global Constraints

- Work only in the worktree: `F:/Dev/projects/personal/dotfiles/.worktrees/ccr-statusline` (branch `feat/ccr-statusline`). Never touch dotfiles `main`.
- Go files: `scripts/claude-status/main.go`, `scripts/claude-status/main_test.go`. Module is stdlib-only — add no dependencies.
- Picker `~/.claude-code-router/pick.sh` is NOT in the repo — edit in place, no commit.
- `renderLines` must stay a pure function (no env reads inside); env is parsed only in `main()`.
- Fallback detection signal: `CCR_ACTIVE_ROUTE != ""`. Native/opencode sessions never set it.
- Single-width glyphs only (no emoji) — matches `TestRenderNoEmoji`.
- Build/deploy: `cd scripts/claude-status && go build -o "$HOME/.local/bin/claude-status" .`
- Run tests: `cd scripts/claude-status && go test ./...`

---

### Task 1: Verify-first — prove env inheritance (manual gate, throwaway probe)

The whole design assumes the statusLine subprocess inherits the session's env. This is undocumented. Prove it before building. The current picker already exports `ANTHROPIC_BASE_URL`, so probe for that — if it arrives, every future `CCR_*` var will too.

**Files:**
- Modify (temporarily): `scripts/claude-status/main.go` — top of `main()`

- [ ] **Step 1: Add a temporary probe at the very top of `main()`**

Insert as the first statements inside `func main() {` (before the `-subagents` check):

```go
	// TEMP env-inheritance probe — removed in Task 1 step 6.
	if base := os.Getenv("ANTHROPIC_BASE_URL"); base != "" {
		f, _ := os.OpenFile(filepath.Join(os.TempDir(), "claude-status-envprobe.log"),
			os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if f != nil {
			fmt.Fprintf(f, "ANTHROPIC_BASE_URL=%s CCR_ACTIVE_ROUTE=%q\n", base, os.Getenv("CCR_ACTIVE_ROUTE"))
			f.Close()
		}
	}
```

- [ ] **Step 2: Build and deploy**

Run: `cd F:/Dev/projects/personal/dotfiles/.worktrees/ccr-statusline/scripts/claude-status && go build -o "$HOME/.local/bin/claude-status" .`
Expected: builds clean, no output.

- [ ] **Step 3: Delete any stale probe log**

Run: `rm -f "$(cygpath -u "$TEMP" 2>/dev/null || echo /tmp)"/claude-status-envprobe.log`
(Best-effort; ignore errors.)

- [ ] **Step 4: MANUAL — user launches a fallback session**

Ask the user to run `ccrpick`, pick `1`, send one message (e.g. `hi`), then exit. This triggers ≥1 statusline invocation under the CCR env.

- [ ] **Step 5: Confirm the probe log exists and contains the base URL**

Run: `cat "$(cygpath -u "$TEMP" 2>/dev/null || echo /tmp)"/claude-status-envprobe.log`
Expected: at least one line `ANTHROPIC_BASE_URL=http://127.0.0.1:3456 CCR_ACTIVE_ROUTE=...`.
- If present → env inheritance CONFIRMED. Proceed.
- If the file is missing/empty → env is NOT inherited. STOP and revisit the design (marker-file fallback plan in the spec). Do not continue.

- [ ] **Step 6: Remove the probe block, rebuild**

Delete the block added in Step 1. Rebuild: `cd scripts/claude-status && go build -o "$HOME/.local/bin/claude-status" .`
No commit — the probe was throwaway.

---

### Task 2: `fallback` struct + `parseFallback` + plumb into `renderLines`

**Files:**
- Modify: `scripts/claude-status/main.go`
- Test: `scripts/claude-status/main_test.go`

**Interfaces:**
- Produces: `type fallback struct { Route, Provider, Model string; CtxWindow int; Reasoning bool }`; `func parseFallback() fallback`; new signature `func renderLines(p Payload, git *gitState, cols int, verbose bool, fb fallback) []string`.

- [ ] **Step 1: Write the failing test**

Add to `main_test.go`:

```go
func TestParseFallbackNativeWhenNoEnv(t *testing.T) {
	t.Setenv("CCR_ACTIVE_ROUTE", "")
	if fb := parseFallback(); fb.Route != "" {
		t.Errorf("native: want zero fallback, got %+v", fb)
	}
}

func TestParseFallbackSplitsRouteAndFlags(t *testing.T) {
	t.Setenv("CCR_ACTIVE_ROUTE", "nvidia,deepseek-ai/deepseek-v4-pro")
	t.Setenv("CCR_CTX_WINDOW", "128000")
	t.Setenv("CCR_REASONING", "off")
	fb := parseFallback()
	if fb.Provider != "nvidia" {
		t.Errorf("Provider = %q, want nvidia", fb.Provider)
	}
	if fb.Model != "deepseek-v4-pro" {
		t.Errorf("Model = %q, want deepseek-v4-pro (vendor prefix stripped)", fb.Model)
	}
	if fb.CtxWindow != 128000 {
		t.Errorf("CtxWindow = %d, want 128000", fb.CtxWindow)
	}
	if fb.Reasoning {
		t.Error("Reasoning should be false when CCR_REASONING=off")
	}
}

func TestParseFallbackKeepsModelWithoutSlash(t *testing.T) {
	t.Setenv("CCR_ACTIVE_ROUTE", "ollama,gpt-oss:20b")
	t.Setenv("CCR_CTX_WINDOW", "")
	t.Setenv("CCR_REASONING", "on")
	fb := parseFallback()
	if fb.Model != "gpt-oss:20b" {
		t.Errorf("Model = %q, want gpt-oss:20b", fb.Model)
	}
	if fb.CtxWindow != 0 {
		t.Errorf("CtxWindow = %d, want 0 when unset", fb.CtxWindow)
	}
	if !fb.Reasoning {
		t.Error("Reasoning should be true when CCR_REASONING=on")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run TestParseFallback`
Expected: FAIL — `undefined: parseFallback` / `undefined: fallback`.

- [ ] **Step 3: Add the struct and parser**

Add to `main.go` (after the `Payload` type block, before the Git section):

```go
// ── CCR fallback (out-of-band, from env stamped by pick.sh) ──────────────────
// The Claude Code payload can't reveal a proxied backend, so a CCR fallback
// session's real route/window/reasoning arrive via env. Zero value = native.
type fallback struct {
	Route     string // raw CCR_ACTIVE_ROUTE, "" = native session
	Provider  string // "nvidia"
	Model     string // display model, vendor prefix stripped: "deepseek-v4-pro"
	CtxWindow int    // real context window in tokens, 0 = unknown
	Reasoning bool   // route actually reasons (not stripped)
}

func parseFallback() fallback {
	route := os.Getenv("CCR_ACTIVE_ROUTE")
	if route == "" {
		return fallback{}
	}
	fb := fallback{Route: route, Reasoning: os.Getenv("CCR_REASONING") == "on"}
	if i := strings.IndexByte(route, ','); i >= 0 {
		fb.Provider, fb.Model = route[:i], route[i+1:]
	} else {
		fb.Model = route
	}
	if i := strings.LastIndexByte(fb.Model, '/'); i >= 0 {
		fb.Model = fb.Model[i+1:]
	}
	fb.CtxWindow, _ = strconv.Atoi(os.Getenv("CCR_CTX_WINDOW"))
	return fb
}
```

- [ ] **Step 4: Change `renderLines` signature and thread `fb` through `main`**

Change the signature line in `main.go`:
```go
func renderLines(p Payload, git *gitState, cols int, verbose bool, fb fallback) []string {
```

In `main()`, change the render call to:
```go
	fb := parseFallback()
	for _, line := range renderLines(p, getGitState(p.SessionID), cols, verbose, fb) {
		fmt.Println(line)
	}
```

- [ ] **Step 5: Update all existing `renderLines` call sites in tests**

In `main_test.go`, every existing `renderLines(...)` call takes 4 args — append `, fallback{}` to each. Call sites are in these tests: `TestRenderNarrowDropsRepoCostAndExtras`, `TestRenderNormalTwoLinesNoCacheStats`, `TestRenderVerboseForcesThirdLine`, `TestRenderWideThreeLinesGiantBar`, `TestRenderUnknownColumnsBehavesAsNormal`, `TestRenderGitAheadBehindUntracked`, `TestRenderPRIsHyperlinked`, `TestRenderExceeds200kWarning`, `TestRenderOutputStyleShownExceptDefault` (2 calls), `TestRenderVimMode`, `TestRenderNoEmoji`.

Example transformation:
```go
// before
lines := renderLines(fullPayload(), testGit(), 60, false)
// after
lines := renderLines(fullPayload(), testGit(), 60, false, fallback{})
```

- [ ] **Step 6: Run all tests to verify pass**

Run: `cd scripts/claude-status && go test ./...`
Expected: PASS (existing render tests unchanged behavior with zero fallback; parseFallback tests green).

- [ ] **Step 7: Commit**

```bash
cd F:/Dev/projects/personal/dotfiles/.worktrees/ccr-statusline
git add scripts/claude-status/main.go scripts/claude-status/main_test.go
git commit -m "feat(claude-status): fallback struct + env parser, plumbed into renderLines

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Model segment — ⚡ real model + conditional reasoning

**Files:**
- Modify: `scripts/claude-status/main.go` (the `secModel` block, ~lines 467-481)
- Test: `scripts/claude-status/main_test.go`

**Interfaces:**
- Consumes: `fallback` from Task 2.

- [ ] **Step 1: Write the failing test**

Add a fallback payload helper and tests to `main_test.go`:

```go
func fbNvidia() fallback {
	return fallback{Route: "nvidia,deepseek-ai/deepseek-v4-pro", Provider: "nvidia", Model: "deepseek-v4-pro", CtxWindow: 0, Reasoning: false}
}

func TestRenderFallbackModelReplacesLabel(t *testing.T) {
	p := fullPayload()
	p.Effort = &struct {
		Level string `json:"level"`
	}{Level: "high"}
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fbNvidia()), "\n"))
	if !strings.Contains(joined, "⚡ deepseek-v4-pro") {
		t.Errorf("fallback model label missing ⚡/model in %q", joined)
	}
	if !strings.Contains(joined, "nvidia") {
		t.Error("fallback provider missing")
	}
	if strings.Contains(joined, "Fable") || strings.Contains(joined, "⬡") {
		t.Error("native label must not appear in fallback")
	}
	if strings.Contains(joined, "high") {
		t.Error("reasoning hidden when Reasoning=false (stripped route)")
	}
}

func TestRenderFallbackShowsReasoningWhenOn(t *testing.T) {
	p := fullPayload()
	p.Effort = &struct {
		Level string `json:"level"`
	}{Level: "high"}
	fb := fbNvidia()
	fb.Reasoning = true
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fb), "\n"))
	if !strings.Contains(joined, "high") {
		t.Error("reasoning shown when Reasoning=true (e.g. gpt-oss)")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run TestRenderFallbackModel`
Expected: FAIL — output still shows `⬡ Fable`, no `⚡`.

- [ ] **Step 3: Rewrite the `secModel` block**

Replace the existing `secModel` block (the `if label := modelLabel(...)` block) with:

```go
	// Section: model — native shows ⬡ <label>; CCR fallback shows ⚡ <real model>.
	var secModel string
	vimPrefix := ""
	if p.Vim != nil && p.Vim.Mode != "" {
		vimPrefix = Gray + "[" + strings.ToLower(p.Vim.Mode[:1]) + "]" + Reset + " "
	}
	outputStyle := ""
	if p.OutputStyle != nil && p.OutputStyle.Name != "" && p.OutputStyle.Name != "default" {
		outputStyle = "  " + Dim + p.OutputStyle.Name + Reset
	}
	switch {
	case fb.Route != "":
		s := vimPrefix + Yellow + Bold + "⚡ " + fb.Model + Reset
		if fb.Provider != "" {
			s += "  " + Dim + fb.Provider + Reset
		}
		if fb.Reasoning && p.Effort != nil && p.Effort.Level != "" {
			s += "  " + Gray + p.Effort.Level + Reset
		}
		secModel = s + outputStyle
	default:
		if label := modelLabel(p.Model.ID, p.Model.DisplayName); label != "" {
			s := vimPrefix + Purple + Bold + "⬡ " + label + Reset
			if p.Effort != nil && p.Effort.Level != "" {
				s += "  " + Gray + p.Effort.Level + Reset
			}
			secModel = s + outputStyle
		}
	}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd scripts/claude-status && go test ./...`
Expected: PASS (new fallback tests + all native render tests still green — native path behaves identically).

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/main.go scripts/claude-status/main_test.go
git commit -m "feat(claude-status): ⚡ real model + conditional reasoning in fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Context window — real denominator or tokens-only

**Files:**
- Modify: `scripts/claude-status/main.go` (the `secCtx` block, ~lines 601-619)
- Test: `scripts/claude-status/main_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestRenderFallbackKnownWindowUsesRealDenominator(t *testing.T) {
	p := fullPayload()
	p.ContextWindow.TotalInputTokens = 15000
	fb := fbNvidia()
	fb.CtxWindow = 128000 // e.g. an OpenRouter/vLLM route that reported a window
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fb), "\n"))
	if !strings.Contains(joined, "15k/128k") {
		t.Errorf("want real denominator 15k/128k in %q", joined)
	}
	if strings.Contains(joined, "/200k") {
		t.Error("must not use Opus's 200k window in fallback")
	}
}

func TestRenderFallbackUnknownWindowShowsTokensOnly(t *testing.T) {
	p := fullPayload()
	p.ContextWindow.TotalInputTokens = 15000
	fb := fbNvidia() // CtxWindow 0 = unknown (NVIDIA)
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fb), "\n"))
	if !strings.Contains(joined, "15k in") {
		t.Errorf("want tokens-only 'ctx 15k in' in %q", joined)
	}
	if strings.Contains(joined, "/200k") || strings.Contains(joined, "/128k") {
		t.Error("no denominator when window unknown")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run TestRenderFallback...Window`
Expected: FAIL — still shows `84k/200k` from the native path.

- [ ] **Step 3: Add the fallback branch to the `secCtx` block**

Replace the `var secCtx string` block (the `if p.ContextWindow.UsedPercentage != nil {...}`) with:

```go
	var secCtx string
	switch {
	case fb.Route != "":
		usedK := p.ContextWindow.TotalInputTokens / 1000
		if fb.CtxWindow > 0 {
			pct := float64(p.ContextWindow.TotalInputTokens) / float64(fb.CtxWindow) * 100
			secCtx = sec(
				fmt.Sprintf("ctx %s %s%.0f%%%s", bar(pct, ctxBarWidth), pctColor(pct), pct, Reset),
				fmt.Sprintf("%s%dk/%dk%s", Gray, usedK, fb.CtxWindow/1000, Reset),
			)
		} else {
			// window unknown (NVIDIA reports none) — show usage, no fake denominator
			secCtx = fmt.Sprintf("ctx %s%dk in%s", Gray, usedK, Reset)
		}
	case p.ContextWindow.UsedPercentage != nil:
		pct := *p.ContextWindow.UsedPercentage
		usedK := p.ContextWindow.TotalInputTokens / 1000
		totalK := p.ContextWindow.ContextWindowSize / 1000
		suffix := ""
		if pct >= 90 {
			suffix = "  " + BoldRed + "⚡ compact" + Reset
		} else if pct >= 85 {
			suffix = "  " + Red + "⚡ soon" + Reset
		}
		if p.ExceedsTokens {
			suffix += "  " + BoldRed + "⚠ >200k" + Reset
		}
		secCtx = sec(
			fmt.Sprintf("ctx %s %s%.0f%%%s", bar(pct, ctxBarWidth), pctColor(pct), pct, Reset),
			fmt.Sprintf("%s%dk/%dk%s", Gray, usedK, totalK, Reset),
		) + suffix
	}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd scripts/claude-status && go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/main.go scripts/claude-status/main_test.go
git commit -m "feat(claude-status): fallback context window (real denom or tokens-only)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Cost → FREE, rate limits → minimized

**Files:**
- Modify: `scripts/claude-status/main.go` (the `secCost` block ~lines 573-586 and `secRate` block ~lines 622-643)
- Test: `scripts/claude-status/main_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestRenderFallbackCostIsFree(t *testing.T) {
	joined := stripANSI(strings.Join(renderLines(fullPayload(), testGit(), 110, false, fbNvidia()), "\n"))
	if !strings.Contains(joined, "FREE") {
		t.Errorf("fallback cost should show FREE in %q", joined)
	}
	if strings.Contains(joined, "$0.42") {
		t.Error("no dollar cost in fallback")
	}
}

func TestRenderFallbackRateLimitsMinimized(t *testing.T) {
	joined := stripANSI(strings.Join(renderLines(fullPayload(), testGit(), 110, false, fbNvidia()), "\n"))
	if !strings.Contains(joined, "5h") || !strings.Contains(joined, "↺") {
		t.Errorf("fallback should keep 5h reset info in %q", joined)
	}
	// minimized = no progress-bar cells in the rate section
	rateLine := ""
	for _, l := range strings.Split(joined, "\n") {
		if strings.Contains(l, "5h") {
			rateLine = l
		}
	}
	if strings.ContainsAny(rateLine, "█░") {
		t.Errorf("minimized rate limits must have no bar cells: %q", rateLine)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run TestRenderFallback`
Expected: FAIL — cost shows `$0.42`, rate line still has `█`/`░`.

- [ ] **Step 3: Add fallback branch to `secCost`**

Replace the `secCost` block with:

```go
	// Section: cost — native shows $; fallback shows FREE (free/local routes).
	secCost := ""
	if t != narrow {
		var costParts []string
		if fb.Route != "" {
			costParts = append(costParts, Green+"FREE"+Reset)
		} else if cs := fmtCost(p.Cost.TotalCostUSD); cs != "" {
			costParts = append(costParts, cs)
		}
		if ds := fmtDuration(p.Cost.TotalDurationMS); ds != "" {
			costParts = append(costParts, Gray+ds+Reset)
		}
		if p.Agent != nil && p.Agent.Name != "" {
			costParts = append(costParts, Gray+"agent: "+Reset+p.Agent.Name)
		}
		secCost = strings.Join(costParts, "  ")
	}
```

- [ ] **Step 4: Add fallback branch to `secRate`**

Replace the `secRate` block with:

```go
	// Section: rate limits — native shows full bars; fallback minimizes to
	// pct + unlock time (Max quota isn't moving while you're on free routes).
	secRate := ""
	if t != narrow && p.RateLimits != nil {
		now := time.Now()
		var rateParts []string
		if fb.Route != "" {
			if fh := p.RateLimits.FiveHour; fh != nil {
				rateParts = append(rateParts, fmt.Sprintf("5h %s%.0f%%%s  %s",
					pctColor(fh.UsedPercentage), fh.UsedPercentage, Reset,
					fmtResetsAt(fh.ResetsAt, fh.UsedPercentage)))
			}
			if sd := p.RateLimits.SevenDay; sd != nil {
				rateParts = append(rateParts, fmt.Sprintf("7d %s%.0f%%%s  %s",
					pctColor(sd.UsedPercentage), sd.UsedPercentage, Reset,
					fmtResetsAt(sd.ResetsAt, sd.UsedPercentage)))
			}
			secRate = strings.Join(rateParts, sep)
		} else {
			if fh := p.RateLimits.FiveHour; fh != nil {
				rateParts = append(rateParts,
					fmt.Sprintf("5h %s %s%.0f%%%s%s  %s",
						bar(fh.UsedPercentage, 8),
						pctColor(fh.UsedPercentage), fh.UsedPercentage, Reset,
						paceDelta(fh.UsedPercentage, fh.ResetsAt, 5*time.Hour, now),
						fmtResetsAt(fh.ResetsAt, fh.UsedPercentage)))
			}
			if sd := p.RateLimits.SevenDay; sd != nil {
				rateParts = append(rateParts,
					fmt.Sprintf("7d %s %s%.0f%%%s%s  %s",
						bar(sd.UsedPercentage, 8),
						pctColor(sd.UsedPercentage), sd.UsedPercentage, Reset,
						paceDelta(sd.UsedPercentage, sd.ResetsAt, 7*24*time.Hour, now),
						fmtResetsAt(sd.ResetsAt, sd.UsedPercentage)))
			}
			secRate = strings.Join(rateParts, sep)
		}
	}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd scripts/claude-status && go test ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/claude-status/main.go scripts/claude-status/main_test.go
git commit -m "feat(claude-status): FREE cost tag + minimized rate limits in fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Picker stamps the env vars

**Files:**
- Modify (in place, not in repo): `~/.claude-code-router/pick.sh`

- [ ] **Step 1: Add the env-stamping block to pick.sh**

In `~/.claude-code-router/pick.sh`, immediately BEFORE the launch block (`echo "  → launching Claude Code on: $sel"`), insert:

```bash
# ── Stamp fallback state for the statusline (read by claude-status) ───────────
provider="${sel%%,*}"
model="${sel#*,}"

# Reasoning: off when this provider strips it (strip-reasoning transformer).
reason="on"
if ( cd "$ccrdir" && node -e '
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === process.argv[1]);
  const use = (p && p.transformer && p.transformer.use) || [];
  process.exit(use.includes("strip-reasoning") ? 0 : 1);
' "$provider" ); then reason="off"; fi

# Context window: best-effort live query of the provider's /v1/models.
# OpenRouter reports context_length, vLLM reports max_model_len; NVIDIA reports
# neither → empty → statusline shows tokens-only.
ctxwin="$( cd "$ccrdir" && node -e '
  const http = require("http"), https = require("https");
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === process.argv[1]);
  const model = process.argv[2];
  if (!p) process.exit(0);
  const base = p.api_base_url.replace(/\/chat\/completions$/, "").replace(/\/+$/, "");
  const url = base + "/models";
  const keyRef = (p.api_key || "").replace(/^\$/, "");
  const auth = (keyRef && process.env[keyRef]) ? process.env[keyRef] : (p.api_key || "");
  const lib = url.startsWith("https") ? https : http;
  const req = lib.get(url, { headers: auth ? { Authorization: "Bearer " + auth } : {}, timeout: 4000 }, res => {
    let b = ""; res.on("data", d => b += d); res.on("end", () => {
      try {
        const m = (JSON.parse(b).data || []).find(x => x.id === model);
        const w = m && (m.context_length || m.max_model_len);
        if (w) process.stdout.write(String(w));
      } catch (e) {}
      process.exit(0);
    });
  });
  req.on("error", () => process.exit(0));
  req.on("timeout", () => { req.destroy(); process.exit(0); });
' "$provider" "$model" 2>/dev/null )"

export CCR_ACTIVE_ROUTE="$sel"
export CCR_REASONING="$reason"
[ -n "$ctxwin" ] && export CCR_CTX_WINDOW="$ctxwin"
```

- [ ] **Step 2: Syntax-check the picker**

Run: `bash -n ~/.claude-code-router/pick.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 3: Dry-verify the stamping logic outside the picker**

Run (mimics the picker's two node blocks for the NVIDIA route):
```bash
cd ~/.claude-code-router && node -e '
  const c=require("./config.json");
  const p=c.Providers.find(p=>p.name==="nvidia");
  console.log("strip-reasoning?", (p.transformer.use||[]).includes("strip-reasoning"));
'
```
Expected: `strip-reasoning? true` (→ `CCR_REASONING=off` for NVIDIA).

No commit — pick.sh is not in the repo.

---

### Task 7: End-to-end verification + finalize branch

**Files:**
- Modify: `scripts/claude-status/main.go` — none new; final build only.

- [ ] **Step 1: Full test suite green**

Run: `cd F:/Dev/projects/personal/dotfiles/.worktrees/ccr-statusline/scripts/claude-status && go test ./... && go vet ./...`
Expected: PASS, no vet warnings.

- [ ] **Step 2: Build + deploy the binary**

Run: `cd scripts/claude-status && go build -o "$HOME/.local/bin/claude-status" .`
Expected: clean build.

- [ ] **Step 3: MANUAL — fallback session visual check**

Ask the user to run `ccrpick`, pick `1` (NVIDIA), send a message. The statusline should show:
- `⚡ deepseek-v4-pro  nvidia` (not `⬡ Opus 4.8`)
- no reasoning word (stripped route)
- `ctx <N>k in` (no bar — NVIDIA window unknown)
- `FREE` (no `$`)
- `5h …% ↺…` minimized (no bar cells)

- [ ] **Step 4: MANUAL — native session regression check**

Ask the user to run plain `claude` in any repo. The statusline must look exactly as before: `⬡ <model>  <effort>`, real cost, full `5h ███ …` bars. If anything changed in native mode, STOP and fix the offending fallback branch's `fb.Route != ""` gate.

- [ ] **Step 5: Stage the aliases change and confirm the branch diff**

```bash
cd F:/Dev/projects/personal/dotfiles/.worktrees/ccr-statusline
git add home/dot_config/shell/aliases.sh
git commit -m "feat(shell): add ccrpick alias for the CCR fallback picker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git log --oneline origin/main..HEAD
```
Expected: the design doc, plan, the four `feat(claude-status)` commits, and the alias commit.

- [ ] **Step 6: Hand off to shipping**

The branch is ready. Ship via the `no-mistakes` pipeline (review → PR → CI) per repo policy. Do not merge to main directly.

---

## Notes for the implementer

- `t.Setenv` (Go 1.17+) auto-restores env after each test — safe for the `parseFallback` tests.
- The `sep` variable (`  │  `) and `sec()` helper already exist in `main.go`; reuse them, don't redefine.
- `Yellow`, `Green`, `Dim`, `Gray`, `Purple`, `Bold`, `Reset` constants already exist.
- Do not read env inside `renderLines` — only `main()` calls `parseFallback()`. This keeps every render test hermetic.
