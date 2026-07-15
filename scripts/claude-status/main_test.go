package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// ── subagent rows ─────────────────────────────────────────────────────────────

func TestSubagentRowRunningShowsNameTokensElapsed(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	task := subTask{
		ID: "t1", Name: "Explore", Status: "running",
		Description: "searching for callers",
		TokenCount:  12400,
		StartTime:   (now.Add(-3 * time.Minute)).UnixMilli(),
	}
	row := stripANSI(renderSubagentRow(task, 120, now))
	for _, want := range []string{"Explore", "searching for callers", "12k", "3m"} {
		if !strings.Contains(row, want) {
			t.Errorf("row %q missing %q", row, want)
		}
	}
}

func TestSubagentRowStatusGlyphs(t *testing.T) {
	now := time.Now()
	cases := []struct{ status, glyph string }{
		{"running", "⟳"},
		{"completed", "✓"},
		{"failed", "✗"},
		{"pending", "·"},
	}
	for _, c := range cases {
		row := stripANSI(renderSubagentRow(subTask{ID: "x", Name: "a", Status: c.status}, 120, now))
		if !strings.Contains(row, c.glyph) {
			t.Errorf("status %s: row %q missing glyph %q", c.status, row, c.glyph)
		}
	}
}

func TestSubagentRowTruncatesToColumns(t *testing.T) {
	task := subTask{
		ID: "t1", Name: "Explore", Status: "running",
		Description: strings.Repeat("long description ", 20),
	}
	row := stripANSI(renderSubagentRow(task, 60, time.Now()))
	if n := len([]rune(row)); n > 60 {
		t.Errorf("visible row length %d exceeds 60 columns", n)
	}
	if !strings.Contains(row, "…") {
		t.Error("truncated description should end with ellipsis")
	}
}

func TestSubagentOverridesEmitJSONLinePerTask(t *testing.T) {
	in := subagentInput{
		Columns: 100,
		Tasks: []subTask{
			{ID: "a1", Name: "Explore", Status: "running"},
			{ID: "b2", Name: "Plan", Status: "completed"},
		},
	}
	lines := renderSubagentOverrides(in, time.Now())
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2", len(lines))
	}
	for i, l := range lines {
		var row struct {
			ID      string `json:"id"`
			Content string `json:"content"`
		}
		if err := json.Unmarshal([]byte(l), &row); err != nil {
			t.Fatalf("line %d not valid JSON: %v", i, err)
		}
		if row.ID == "" || row.Content == "" {
			t.Errorf("line %d missing id/content: %q", i, l)
		}
	}
}

func TestCachePathUsesSystemTempDir(t *testing.T) {
	p := cachePath("abc-123")
	if !strings.HasPrefix(p, os.TempDir()) {
		t.Errorf("cachePath = %q, want prefix %q", p, os.TempDir())
	}
	if !strings.Contains(p, "abc-123") {
		t.Errorf("cachePath = %q, want session id in name", p)
	}
}

func TestGitStateCacheRoundtrip(t *testing.T) {
	g := gitState{Branch: "feat/x", Ahead: 2, Behind: 1, Staged: 3, Modified: 4, Untracked: 5}
	got := decodeGitState(encodeGitState(&g))
	if got == nil || *got != g {
		t.Errorf("roundtrip = %+v, want %+v", got, g)
	}
}

func TestGitStateCacheNotARepoSentinel(t *testing.T) {
	if got := decodeGitState(encodeGitState(nil)); got != nil {
		t.Errorf("nil roundtrip = %+v, want nil", got)
	}
}

func TestCleanStaleCaches(t *testing.T) {
	dir := t.TempDir()
	stale := filepath.Join(dir, "claude-status-git-old")
	fresh := filepath.Join(dir, "claude-status-git-new")
	other := filepath.Join(dir, "unrelated-file")
	for _, f := range []string{stale, fresh, other} {
		if err := os.WriteFile(f, []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-25 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(other, old, old); err != nil {
		t.Fatal(err)
	}

	cleanStaleCaches(dir)

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("stale cache file not removed")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Error("fresh cache file removed")
	}
	if _, err := os.Stat(other); err != nil {
		t.Error("unrelated file removed — must only touch claude-status-git-*")
	}
}

// ── renderLines ───────────────────────────────────────────────────────────────

var ansiRe = regexp.MustCompile(`\033(\[[0-9;]*m|\]8;;[^\033]*\033\\)`)

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

func fullPayload() Payload {
	var p Payload
	p.SessionID = "test"
	p.Version = "2.1.160"
	p.Model.ID = "claude-fable-5"
	p.Model.DisplayName = "Fable"
	p.Workspace.CurrentDir = "F:\\Dev\\proj"
	p.Workspace.Repo = &struct {
		Host  string `json:"host"`
		Owner string `json:"owner"`
		Name  string `json:"name"`
	}{Host: "github.com", Owner: "jdwillmsen", Name: "dotfiles"}
	p.Cost.TotalCostUSD = 0.42
	p.Cost.TotalDurationMS = 300000
	p.Cost.TotalAPIDurationMS = 90000
	pct := 42.0
	p.ContextWindow.UsedPercentage = &pct
	p.ContextWindow.TotalInputTokens = 84000
	p.ContextWindow.TotalOutputTokens = 5000
	p.ContextWindow.ContextWindowSize = 200000
	p.ContextWindow.CurrentUsage = &struct {
		InputTokens              int `json:"input_tokens"`
		OutputTokens             int `json:"output_tokens"`
		CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
		CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	}{InputTokens: 8000, CacheCreationInputTokens: 5000, CacheReadInputTokens: 35000}
	p.RateLimits = &struct {
		FiveHour *struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       int64   `json:"resets_at"`
		} `json:"five_hour"`
		SevenDay *struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       int64   `json:"resets_at"`
		} `json:"seven_day"`
	}{
		FiveHour: &struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       int64   `json:"resets_at"`
		}{UsedPercentage: 38, ResetsAt: time.Now().Add(2 * time.Hour).Unix()},
	}
	return p
}

func testGit() *gitState {
	return &gitState{Branch: "main", Ahead: 2, Behind: 1, Staged: 1, Modified: 3, Untracked: 4}
}

func TestRenderNarrowDropsRepoCostAndExtras(t *testing.T) {
	lines := renderLines(fullPayload(), testGit(), 60, false, fallback{})
	if len(lines) > 2 {
		t.Fatalf("narrow: got %d lines, want ≤2", len(lines))
	}
	joined := stripANSI(strings.Join(lines, "\n"))
	if strings.Contains(joined, "dotfiles") {
		t.Error("narrow: repo name should be dropped")
	}
	if strings.Contains(joined, "$0.42") {
		t.Error("narrow: cost should be dropped")
	}
	if !strings.Contains(joined, "main") {
		t.Error("narrow: branch missing")
	}
}

func TestRenderNormalTwoLinesNoCacheStats(t *testing.T) {
	lines := renderLines(fullPayload(), testGit(), 110, false, fallback{})
	if len(lines) != 2 {
		t.Fatalf("normal: got %d lines, want 2", len(lines))
	}
	joined := stripANSI(strings.Join(lines, "\n"))
	if strings.Contains(joined, "cache") {
		t.Error("normal: cache stats belong to wide/verbose only")
	}
	if !strings.Contains(joined, "jdwillmsen/dotfiles") {
		t.Error("normal: repo missing")
	}
	if !strings.Contains(joined, "5h") {
		t.Error("normal: rate limits missing")
	}
}

func TestRenderVerboseForcesThirdLine(t *testing.T) {
	lines := renderLines(fullPayload(), testGit(), 110, true, fallback{})
	if len(lines) != 3 {
		t.Fatalf("verbose: got %d lines, want 3", len(lines))
	}
	if !strings.Contains(stripANSI(lines[2]), "cache") {
		t.Error("verbose: cache stats missing on line 3")
	}
}

func TestRenderWideThreeLinesGiantBar(t *testing.T) {
	lines := renderLines(fullPayload(), testGit(), 180, false, fallback{})
	if len(lines) != 3 {
		t.Fatalf("wide: got %d lines, want 3", len(lines))
	}
	bar := stripANSI(lines[1])
	cells := strings.Count(bar, "█") + strings.Count(bar, "░")
	if cells < 20 {
		t.Errorf("wide: context bar has %d cells, want ≥20", cells)
	}
}

func TestRenderUnknownColumnsBehavesAsNormal(t *testing.T) {
	lines := renderLines(fullPayload(), testGit(), 0, false, fallback{})
	if len(lines) != 2 {
		t.Fatalf("cols=0: got %d lines, want 2 (normal tier)", len(lines))
	}
}

func TestRenderGitAheadBehindUntracked(t *testing.T) {
	joined := stripANSI(strings.Join(renderLines(fullPayload(), testGit(), 110, false, fallback{}), "\n"))
	for _, want := range []string{"⇡2", "⇣1", "+1", "~3", "?4"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in %q", want, joined)
		}
	}
}

func TestRenderPRIsHyperlinked(t *testing.T) {
	p := fullPayload()
	p.PR = &struct {
		Number      int    `json:"number"`
		URL         string `json:"url"`
		ReviewState string `json:"review_state"`
	}{Number: 9, URL: "https://github.com/jdwillmsen/dotfiles/pull/9", ReviewState: "approved"}
	joined := strings.Join(renderLines(p, testGit(), 110, false, fallback{}), "\n")
	if !strings.Contains(joined, "\033]8;;https://github.com/jdwillmsen/dotfiles/pull/9") {
		t.Error("PR number not OSC 8 linked")
	}
}

func TestRenderExceeds200kWarning(t *testing.T) {
	p := fullPayload()
	p.ExceedsTokens = true
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fallback{}), "\n"))
	if !strings.Contains(joined, ">200k") {
		t.Error("exceeds_200k_tokens warning missing")
	}
}

func TestRenderOutputStyleShownExceptDefault(t *testing.T) {
	p := fullPayload()
	p.OutputStyle = &struct {
		Name string `json:"name"`
	}{Name: "caveman"}
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fallback{}), "\n"))
	if !strings.Contains(joined, "caveman") {
		t.Error("output style missing")
	}

	p.OutputStyle.Name = "default"
	joined = stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fallback{}), "\n"))
	if strings.Contains(joined, "default") {
		t.Error("default output style should be hidden")
	}
}

func TestRenderVimMode(t *testing.T) {
	p := fullPayload()
	p.Vim = &struct {
		Mode string `json:"mode"`
	}{Mode: "insert"}
	joined := stripANSI(strings.Join(renderLines(p, testGit(), 110, false, fallback{}), "\n"))
	if !strings.Contains(joined, "[i]") {
		t.Error("vim mode indicator missing")
	}
}

func TestRenderNoEmoji(t *testing.T) {
	joined := strings.Join(renderLines(fullPayload(), testGit(), 180, true, fallback{}), "\n")
	for _, emoji := range []string{"📁", "💾", "📝", "⏱"} {
		if strings.Contains(joined, emoji) {
			t.Errorf("emoji %q still present — single-width glyphs only", emoji)
		}
	}
}

func TestOsc8WrapsTextInHyperlink(t *testing.T) {
	got := osc8("https://github.com/o/r", "o/r")
	want := "\033]8;;https://github.com/o/r\033\\o/r\033]8;;\033\\"
	if got != want {
		t.Errorf("osc8 = %q, want %q", got, want)
	}
}

func TestOsc8EmptyURLReturnsPlainText(t *testing.T) {
	if got := osc8("", "text"); got != "text" {
		t.Errorf("osc8 = %q, want plain text when no URL", got)
	}
}

func TestPaceDelta(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	// 5h window, resets in 2.5h → 50% elapsed
	resetsAt := now.Add(150 * time.Minute).Unix()

	cases := []struct {
		name string
		used float64
		want string // glyph expected in output, "" = no output
	}{
		{"burning faster than window", 80, "▲"},
		{"well under pace", 20, "▼"},
		{"on pace stays quiet", 55, ""},
	}
	for _, c := range cases {
		got := paceDelta(c.used, resetsAt, 5*time.Hour, now)
		if c.want == "" && got != "" {
			t.Errorf("%s: got %q, want empty", c.name, got)
		}
		if c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: got %q, want contains %q", c.name, got, c.want)
		}
	}
}

func TestPaceDeltaNoResetTime(t *testing.T) {
	if got := paceDelta(80, 0, 5*time.Hour, time.Now()); got != "" {
		t.Errorf("got %q, want empty when resets_at missing", got)
	}
}

func TestParsePorcelainV2(t *testing.T) {
	out := "# branch.oid 1234567890abcdef1234567890abcdef12345678\n" +
		"# branch.head main\n" +
		"# branch.upstream origin/main\n" +
		"# branch.ab +2 -1\n" +
		"1 M. N... 100644 100644 100644 aaaa bbbb staged.go\n" +
		"1 .M N... 100644 100644 100644 aaaa bbbb modified.go\n" +
		"1 MM N... 100644 100644 100644 aaaa bbbb both.go\n" +
		"2 R. N... 100644 100644 100644 aaaa bbbb R100 new.go\told.go\n" +
		"? untracked.txt\n" +
		"? another.txt\n"

	g := parsePorcelainV2(out)

	if g.Branch != "main" {
		t.Errorf("Branch = %q, want main", g.Branch)
	}
	if g.Ahead != 2 || g.Behind != 1 {
		t.Errorf("Ahead/Behind = %d/%d, want 2/1", g.Ahead, g.Behind)
	}
	// staged: M., MM, R. → 3; modified: .M, MM → 2
	if g.Staged != 3 {
		t.Errorf("Staged = %d, want 3", g.Staged)
	}
	if g.Modified != 2 {
		t.Errorf("Modified = %d, want 2", g.Modified)
	}
	if g.Untracked != 2 {
		t.Errorf("Untracked = %d, want 2", g.Untracked)
	}
}

func TestParsePorcelainV2DetachedHead(t *testing.T) {
	out := "# branch.oid 1234567890abcdef1234567890abcdef12345678\n" +
		"# branch.head (detached)\n"

	g := parsePorcelainV2(out)

	if g.Branch != "1234567" {
		t.Errorf("Branch = %q, want short oid 1234567", g.Branch)
	}
}

func TestParsePorcelainV2CleanRepoNoUpstream(t *testing.T) {
	out := "# branch.oid 1234567890abcdef1234567890abcdef12345678\n" +
		"# branch.head feat/x\n"

	g := parsePorcelainV2(out)

	if g.Branch != "feat/x" {
		t.Errorf("Branch = %q, want feat/x", g.Branch)
	}
	if g.Ahead != 0 || g.Behind != 0 || g.Staged != 0 || g.Modified != 0 || g.Untracked != 0 {
		t.Errorf("counts nonzero on clean repo: %+v", g)
	}
}

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

// ── Fallback model rendering ──────────────────────────────────────────────────

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
