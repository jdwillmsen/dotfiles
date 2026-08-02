# Jira Session Tracking — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the current session's Jira ticket key as a clickable segment in the
statusline, and name sessions after their ticket at launch.

**Architecture:** All resolution logic lands in one new file,
`scripts/claude-status/jira.go`, as pure functions over the statusline payload.
`main.go` calls into it from exactly two places: one line in `renderLines` to
strip the key from the branch display, and one block to append the ticket
segment. No subprocess, no network, no cache, no credential.

**Tech Stack:** Go (stdlib only), bash shell function, chezmoi.

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-08-02-jira-session-tracking-design.md`:

- **No subprocess in the statusline hot path.** `git rev-parse` measured 60 ms
  against an 84 ms cold-start budget. Derive the git dir from the payload.
- **No emoji.** `TestRenderNoEmoji` (`main_test.go:441-448`) asserts
  single-width glyphs only. `visibleLen` counts runes, not display cells.
- **Reject, never repair.** `parseTicketKey` validates; it does not sanitize,
  uppercase-fold, or trim into validity.
- **Fail closed.** Missing or unparseable config ⇒ feature entirely off.
- **Nothing real in tracked files.** Fixtures use `ABC-123` and
  `https://example.atlassian.net` only. No real site host, no real project key.
- **Go stdlib only.** No new module dependencies.
- **All new Go code lives in `jira.go`**, except the two call sites in
  `renderLines` and the `osc8` hardening in `main.go`.

---

### Task 1: Terminal-escape sanitizer

Ships regardless of the Jira feature — it closes existing unsanitized paths
(`p.PR.URL` at `main.go:667`, `p.SessionName` at `main.go:853`, subagent names
at `main.go:936-960`).

**Files:**
- Create: `scripts/claude-status/jira.go`
- Create: `scripts/claude-status/jira_test.go`
- Modify: `scripts/claude-status/main.go:35-40` (harden `osc8`)

**Interfaces:**
- Consumes: nothing.
- Produces: `func safeText(s string, maxRunes int) string`

- [ ] **Step 1: Write the failing test**

Create `scripts/claude-status/jira_test.go`:

```go
package main

import (
	"strings"
	"testing"
)

func TestSafeTextStripsTerminalEscapes(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"osc52 clipboard write", "a\033]52;c;cm0gLXJm\007b", "a]52;c;cm0gLXJmb"},
		{"newline row forgery", "ok\nFORGED", "okFORGED"},
		{"osc8 link swap", "a\033]8;;https://evil\033\\b", "a]8;;https://evil\\b"},
		{"cursor position report", "x\033[6n", "x[6n"},
		{"bidi override", "\u202Egnp.exe", "gnp.exe"},
		{"bare C1 introducer", "a\u009bZb", "aZb"},
		{"carriage return", "real\rfake", "realfake"},
		{"plain text untouched", "fix login retry", "fix login retry"},
	}
	for _, c := range cases {
		got := safeText(c.in, 100)
		if got != c.want {
			t.Errorf("%s: safeText(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
		for _, r := range got {
			if r < 0x20 || r == 0x7F || (r >= 0x80 && r <= 0x9F) {
				t.Errorf("%s: control rune %U survived in %q", c.name, r, got)
			}
		}
	}
}

func TestSafeTextTruncatesAfterStripping(t *testing.T) {
	// The escape must not consume truncation budget.
	got := safeText("\033[1;31mabcdef", 3)
	if got != "[1;31mab"[:3] {
		t.Errorf("got %q, want first 3 runes of the stripped string", got)
	}
}

func TestOSC8RejectsControlRunes(t *testing.T) {
	// A URL carrying an escape must not produce a hyperlink at all.
	got := osc8("https://x/\033]8;;evil", "label")
	if strings.Contains(got, "\033]8;;") {
		t.Errorf("osc8 emitted a hyperlink for a control-bearing URL: %q", got)
	}
	if got != "label" {
		t.Errorf("got %q, want bare %q", got, "label")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run 'SafeText|OSC8' -v`
Expected: FAIL — `undefined: safeText`

- [ ] **Step 3: Write minimal implementation**

Create `scripts/claude-status/jira.go`:

```go
package main

import (
	"strings"
	"unicode"
)

// safeText strips every rune that could steer a terminal, then truncates.
// Externally-sourced text (Jira summaries, PR URLs, session names) reaches the
// statusline verbatim and re-renders every 10s, so an OSC 52 sequence would
// rewrite the system clipboard on a loop. Blocklisting ESC is not enough: BEL
// terminates OSC on many terminals and U+009B/U+009D are bare C1 introducers.
// Truncation happens after stripping so removed escapes don't eat the budget.
func safeText(s string, maxRunes int) string {
	s = strings.ToValidUTF8(s, "")
	var b strings.Builder
	n := 0
	for _, r := range s {
		switch {
		case r < 0x20 || r == 0x7F:
			continue
		case r >= 0x80 && r <= 0x9F:
			continue
		case !unicode.IsPrint(r):
			continue
		case r == '\uFEFF',
			r >= 0x2066 && r <= 0x2069,
			r >= 0x202A && r <= 0x202E,
			r == 0x200E, r == 0x200F:
			continue
		}
		if n == maxRunes {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// hasControl reports whether s carries any rune that could break out of an
// escape sequence it is embedded in.
func hasControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7F || (r >= 0x80 && r <= 0x9F) {
			return true
		}
	}
	return false
}
```

Then harden `osc8` in `main.go:35-40`:

```go
func osc8(url, text string) string {
	if url == "" || hasControl(url) || hasControl(text) {
		return text
	}
	return "\033]8;;" + url + "\033\\" + text + "\033]8;;\033\\"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts/claude-status && go test ./... -v`
Expected: PASS — all 43 existing tests plus the 3 new ones.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/jira.go scripts/claude-status/jira_test.go scripts/claude-status/main.go
git commit -m "fix(statusline): strip terminal escapes from external text

PR URLs, session names, and subagent descriptions reach the terminal
verbatim and re-render every 10s. An OSC 52 sequence in any of them
rewrites the system clipboard on a loop; a newline forges a status row."
```

---

### Task 2: Config loading

**Files:**
- Modify: `scripts/claude-status/jira.go`
- Modify: `scripts/claude-status/jira_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `type jiraConfig struct { SiteBase string; Projects []string }`
  and `func loadJiraConfig(path string) *jiraConfig` (nil ⇒ feature off),
  `func jiraConfigPath() string`

- [ ] **Step 1: Write the failing test**

Append to `jira_test.go`:

```go
func writeCfg(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "claude-jira.json")
	if err := os.WriteFile(p, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadJiraConfigValid(t *testing.T) {
	p := writeCfg(t, `{"siteBase":"https://example.atlassian.net","projects":["ABC","DEF"]}`)
	cfg := loadJiraConfig(p)
	if cfg == nil {
		t.Fatal("got nil, want config")
	}
	if cfg.SiteBase != "https://example.atlassian.net" {
		t.Errorf("siteBase = %q", cfg.SiteBase)
	}
	if len(cfg.Projects) != 2 || cfg.Projects[0] != "ABC" {
		t.Errorf("projects = %v", cfg.Projects)
	}
}

func TestLoadJiraConfigFailsClosed(t *testing.T) {
	cases := map[string]string{
		"missing file":   filepath.Join(t.TempDir(), "nope.json"),
		"malformed json": writeCfg(t, `{"siteBase":`),
		"http not https": writeCfg(t, `{"siteBase":"http://example.atlassian.net"}`),
		"has path":       writeCfg(t, `{"siteBase":"https://example.atlassian.net/x"}`),
		"has userinfo":   writeCfg(t, `{"siteBase":"https://u:p@example.atlassian.net"}`),
		"empty host":     writeCfg(t, `{"siteBase":"https://"}`),
		"control rune":   writeCfg(t, "{\"siteBase\":\"https://e\\u001bvil\"}"),
	}
	for name, p := range cases {
		if cfg := loadJiraConfig(p); cfg != nil {
			t.Errorf("%s: got %+v, want nil (fail closed)", name, cfg)
		}
	}
}
```

Add `"os"`, `"path/filepath"` to the test imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run JiraConfig -v`
Expected: FAIL — `undefined: loadJiraConfig`

- [ ] **Step 3: Write minimal implementation**

Append to `jira.go` (add `"encoding/json"`, `"io"`, `"net/url"`, `"os"`,
`"path/filepath"` to its imports):

```go
// jiraConfig is machine-local and never tracked: the site host identifies the
// company and the project keys name real projects.
type jiraConfig struct {
	SiteBase string   `json:"siteBase"`
	Projects []string `json:"projects"`
}

func jiraConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claude-jira.json")
}

// loadJiraConfig returns nil for anything it cannot fully validate — a machine
// with no Jira gets no segment rather than a broken one.
func loadJiraConfig(path string) *jiraConfig {
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	var cfg jiraConfig
	if err := json.NewDecoder(io.LimitReader(f, 8<<10)).Decode(&cfg); err != nil {
		return nil
	}
	u, err := url.Parse(cfg.SiteBase)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil ||
		u.Path != "" || u.RawQuery != "" || u.Fragment != "" ||
		hasControl(cfg.SiteBase) {
		return nil
	}
	return &cfg
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts/claude-status && go test ./... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/jira.go scripts/claude-status/jira_test.go
git commit -m "feat(statusline): load machine-local Jira config"
```

---

### Task 3: Ticket key validation and branch extraction

**Files:**
- Modify: `scripts/claude-status/jira.go`
- Modify: `scripts/claude-status/jira_test.go`

**Interfaces:**
- Consumes: `jiraConfig` from Task 2.
- Produces: `func parseTicketKey(s string) (string, bool)`,
  `func branchTicketKey(branch string, projects []string) (string, bool)`

- [ ] **Step 1: Write the failing test**

Append to `jira_test.go`:

```go
func TestParseTicketKeyRejects(t *testing.T) {
	bad := []string{
		"", "abc-123", "ABC123", "A-1", "ABC-0", "-1", "ABC-",
		"../../../etc/passwd", "ABC-123/../x", "ABC-12345678",
		"ABCDEFGHIJKL-1", "ABC-123 extra", "ABC-123\n",
	}
	for _, s := range bad {
		if got, ok := parseTicketKey(s); ok {
			t.Errorf("parseTicketKey(%q) = %q, true — want reject", s, got)
		}
	}
}

func TestParseTicketKeyAccepts(t *testing.T) {
	good := map[string]string{
		"ABC-123":     "ABC-123",
		"  ABC-123  ": "ABC-123",
		"AB1-7":       "AB1-7",
		"JDWLABS-4021": "JDWLABS-4021",
	}
	for in, want := range good {
		got, ok := parseTicketKey(in)
		if !ok || got != want {
			t.Errorf("parseTicketKey(%q) = %q, %v — want %q, true", in, got, ok, want)
		}
	}
}

func TestBranchTicketKeyRejectsEncodingTokens(t *testing.T) {
	projects := []string{"ABC", "JDWLABS"}
	bad := []string{
		"feat/UTF-8-normalize", "fix/SHA-256-digest", "chore/HTTP-2-upgrade",
		"feat/AWS-4-signing", "refactor/GH-2-cleanup", "feat/no-key-here",
	}
	for _, b := range bad {
		if got, ok := branchTicketKey(b, projects); ok {
			t.Errorf("branchTicketKey(%q) = %q, true — allowlist must reject", b, got)
		}
	}
}

func TestBranchTicketKeyExtracts(t *testing.T) {
	projects := []string{"ABC", "JDWLABS"}
	cases := map[string]string{
		"feat/JDWLABS-123-fix-login-retry": "JDWLABS-123",
		"fix/abc-7-lowercase":              "ABC-7",
		"ABC-9":                            "ABC-9",
		"chore/ABC-1_underscore":           "ABC-1",
		"feat/ABC-1-and-JDWLABS-2":         "ABC-1", // first match wins, deterministic
	}
	for in, want := range cases {
		got, ok := branchTicketKey(in, projects)
		if !ok || got != want {
			t.Errorf("branchTicketKey(%q) = %q, %v — want %q, true", in, got, ok, want)
		}
	}
}

func TestBranchTicketKeyEmptyAllowlistDisables(t *testing.T) {
	if got, ok := branchTicketKey("feat/ABC-123-x", nil); ok {
		t.Errorf("got %q — empty allowlist must disable branch resolution", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run 'TicketKey' -v`
Expected: FAIL — `undefined: parseTicketKey`

- [ ] **Step 3: Write minimal implementation**

Append to `jira.go` (add `"regexp"`, `"strings"` if not already imported):

```go
// The key becomes a path component downstream, so this is the single gate every
// source passes through. Anchored, and it rejects rather than repairs.
var ticketKeyRe = regexp.MustCompile(`^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6}$`)

func parseTicketKey(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if !ticketKeyRe.MatchString(s) {
		return "", false
	}
	return s, true
}

// Anchored to a separator so it cannot match mid-word. The allowlist — not the
// regex — is what excludes SHA-256, UTF-8, HTTP-2 and friends.
var branchKeyRe = regexp.MustCompile(`(?i)(?:^|[/_-])([a-z][a-z0-9]{1,9}-\d+)(?:$|[/_-])`)

func branchTicketKey(branch string, projects []string) (string, bool) {
	if branch == "" || len(projects) == 0 {
		return "", false
	}
	allowed := make(map[string]bool, len(projects))
	for _, p := range projects {
		allowed[strings.ToUpper(strings.TrimSpace(p))] = true
	}
	for _, m := range branchKeyRe.FindAllStringSubmatch(branch, -1) {
		key, ok := parseTicketKey(strings.ToUpper(m[1]))
		if !ok {
			continue
		}
		if project, _, _ := strings.Cut(key, "-"); allowed[project] {
			return key, true
		}
	}
	return "", false
}
```

> Note: `branchKeyRe` consumes its trailing separator, so overlapping matches in
> `feat/ABC-1-and-JDWLABS-2` are found by `FindAllStringSubmatch` scanning
> forward. The first allowlisted match wins, which is deterministic.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts/claude-status && go test ./... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/jira.go scripts/claude-status/jira_test.go
git commit -m "feat(statusline): parse ticket keys from branch names

The allowlist is load-bearing: an unanchored key regex matches UTF-8,
SHA-256 and HTTP-2, each of which would pin a permanent fake ticket."
```

---

### Task 4: Override file and resolution

**Files:**
- Modify: `scripts/claude-status/jira.go`
- Modify: `scripts/claude-status/jira_test.go`

**Interfaces:**
- Consumes: `parseTicketKey`, `branchTicketKey`, `jiraConfig`.
- Produces: `func gitDirFor(root string) string`,
  `func overrideTicketKey(gitDir string) (string, bool)`,
  `func resolveTicketKey(root, branch string, cfg *jiraConfig) string`,
  `func ticketURL(cfg *jiraConfig, key string) string`

- [ ] **Step 1: Write the failing test**

Append to `jira_test.go`:

```go
func TestGitDirForPlainRepo(t *testing.T) {
	root := t.TempDir()
	gd := filepath.Join(root, ".git")
	if err := os.Mkdir(gd, 0700); err != nil {
		t.Fatal(err)
	}
	if got := gitDirFor(root); got != gd {
		t.Errorf("got %q, want %q", got, gd)
	}
}

func TestGitDirForLinkedWorktree(t *testing.T) {
	// A linked worktree's .git is a FILE pointing at the per-worktree git dir.
	// Per-worktree is the requirement: one worktree is one ticket.
	root := t.TempDir()
	target := filepath.Join(t.TempDir(), ".git", "worktrees", "wt")
	if err := os.MkdirAll(target, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".git"),
		[]byte("gitdir: "+target+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := gitDirFor(root); got != target {
		t.Errorf("got %q, want %q", got, target)
	}
}

func TestGitDirForMissing(t *testing.T) {
	if got := gitDirFor(t.TempDir()); got != "" {
		t.Errorf("got %q, want empty", got)
	}
	if got := gitDirFor(""); got != "" {
		t.Errorf("empty root: got %q, want empty", got)
	}
}

func TestOverrideTicketKey(t *testing.T) {
	gd := t.TempDir()
	if err := os.WriteFile(filepath.Join(gd, "claude-jira-ticket"),
		[]byte("ABC-123\nignored second line\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, ok := overrideTicketKey(gd)
	if !ok || got != "ABC-123" {
		t.Errorf("got %q, %v — want ABC-123, true", got, ok)
	}
}

func TestOverrideTicketKeyRejectsTraversal(t *testing.T) {
	gd := t.TempDir()
	if err := os.WriteFile(filepath.Join(gd, "claude-jira-ticket"),
		[]byte("../../../etc/passwd"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, ok := overrideTicketKey(gd); ok {
		t.Errorf("got %q, true — want reject", got)
	}
}

func TestResolveTicketKeyPrecedence(t *testing.T) {
	cfg := &jiraConfig{SiteBase: "https://example.atlassian.net", Projects: []string{"ABC", "DEF"}}
	root := t.TempDir()
	gd := filepath.Join(root, ".git")
	if err := os.Mkdir(gd, 0700); err != nil {
		t.Fatal(err)
	}

	// Branch only.
	if got := resolveTicketKey(root, "feat/DEF-9-thing", cfg); got != "DEF-9" {
		t.Errorf("branch: got %q, want DEF-9", got)
	}
	// Override beats branch.
	if err := os.WriteFile(filepath.Join(gd, "claude-jira-ticket"), []byte("ABC-1"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := resolveTicketKey(root, "feat/DEF-9-thing", cfg); got != "ABC-1" {
		t.Errorf("override: got %q, want ABC-1", got)
	}
	// Nil config disables everything.
	if got := resolveTicketKey(root, "feat/DEF-9-thing", nil); got != "" {
		t.Errorf("nil cfg: got %q, want empty", got)
	}
}

func TestTicketURL(t *testing.T) {
	cfg := &jiraConfig{SiteBase: "https://example.atlassian.net"}
	if got := ticketURL(cfg, "ABC-123"); got != "https://example.atlassian.net/browse/ABC-123" {
		t.Errorf("got %q", got)
	}
	if got := ticketURL(nil, "ABC-123"); got != "" {
		t.Errorf("nil cfg: got %q, want empty", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run 'GitDir|Override|Resolve|TicketURL' -v`
Expected: FAIL — `undefined: gitDirFor`

- [ ] **Step 3: Write minimal implementation**

Append to `jira.go`:

```go
// gitDirFor resolves the git dir without spawning git: `git rev-parse --git-dir`
// measured 60ms against an 84ms statusline budget. In a linked worktree .git is
// a file holding `gitdir: <abs>`, which points at .git/worktrees/<name> — the
// per-worktree dir, which is what we want. One worktree is one ticket, so an
// override set in one worktree must not leak into another.
func gitDirFor(root string) string {
	if root == "" {
		return ""
	}
	p := filepath.Join(root, ".git")
	fi, err := os.Stat(p)
	if err != nil {
		return ""
	}
	if fi.IsDir() {
		return p
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	target := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "gitdir:"))
	if target == "" {
		return ""
	}
	return filepath.Clean(target)
}

func overrideTicketKey(gitDir string) (string, bool) {
	if gitDir == "" {
		return "", false
	}
	f, err := os.Open(filepath.Join(gitDir, "claude-jira-ticket"))
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 256))
	if err != nil {
		return "", false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return parseTicketKey(line)
}

// resolveTicketKey is a pure function of the payload plus one small file read.
// Order: override file, then branch. Empty string means render nothing.
func resolveTicketKey(root, branch string, cfg *jiraConfig) string {
	if cfg == nil {
		return ""
	}
	if key, ok := overrideTicketKey(gitDirFor(root)); ok {
		return key
	}
	if key, ok := branchTicketKey(branch, cfg.Projects); ok {
		return key
	}
	return ""
}

// ticketURL is derived locally and never taken from data: a supplied URL reaches
// the OS opener on ctrl+click, which is how file:// and \\host\share get in.
func ticketURL(cfg *jiraConfig, key string) string {
	if cfg == nil || cfg.SiteBase == "" || key == "" {
		return ""
	}
	return cfg.SiteBase + "/browse/" + key
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts/claude-status && go test ./... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/jira.go scripts/claude-status/jira_test.go
git commit -m "feat(statusline): resolve the session ticket without spawning git"
```

---

### Task 5: Render the segment

**Files:**
- Modify: `scripts/claude-status/main.go:562-680` (`renderLines`)
- Modify: `scripts/claude-status/jira.go`
- Modify: `scripts/claude-status/main_test.go`

**Interfaces:**
- Consumes: `resolveTicketKey`, `ticketURL`, `loadJiraConfig`, `jiraConfigPath`.
- Produces: `func stripTicketKey(branch, key string) string`; a `jiraCfg` field
  threaded into `renderLines` for testability.

- [ ] **Step 1: Write the failing test**

Append to `main_test.go`:

```go
func jiraPayload() Payload {
	p := fullPayload()
	p.Workspace.GitWorktree = "F:\\Dev\\proj"
	return p
}

func TestRenderTicketSegmentIsHyperlinked(t *testing.T) {
	cfg := &jiraConfig{SiteBase: "https://example.atlassian.net", Projects: []string{"ABC"}}
	git := &gitState{Branch: "feat/ABC-123-fix-login"}
	lines := renderLinesWithJira(jiraPayload(), git, 200, false, fallback{}, cfg)
	joined := strings.Join(lines, "\n")

	if !strings.Contains(joined, "https://example.atlassian.net/browse/ABC-123") {
		t.Errorf("ticket not hyperlinked:\n%s", joined)
	}
	plain := stripANSI(joined)
	if !strings.Contains(plain, "ABC-123") {
		t.Errorf("ticket key missing:\n%s", plain)
	}
	if strings.Count(plain, "ABC-123") != 1 {
		t.Errorf("key rendered %d times, want exactly 1 (stripped from branch):\n%s",
			strings.Count(plain, "ABC-123"), plain)
	}
	if !strings.Contains(plain, "fix-login") {
		t.Errorf("branch remainder lost:\n%s", plain)
	}
}

func TestRenderTicketDroppedAtNarrow(t *testing.T) {
	cfg := &jiraConfig{SiteBase: "https://example.atlassian.net", Projects: []string{"ABC"}}
	git := &gitState{Branch: "feat/ABC-123-fix-login"}
	plain := stripANSI(strings.Join(
		renderLinesWithJira(jiraPayload(), git, 60, false, fallback{}, cfg), "\n"))

	// Narrow drops the segment, so the branch must keep the key — otherwise it
	// vanishes from the statusline entirely.
	if !strings.Contains(plain, "ABC-123") {
		t.Errorf("narrow: key vanished:\n%s", plain)
	}
}

func TestRenderNoTicketWithoutConfig(t *testing.T) {
	git := &gitState{Branch: "feat/ABC-123-fix-login"}
	plain := stripANSI(strings.Join(
		renderLinesWithJira(jiraPayload(), git, 200, false, fallback{}, nil), "\n"))
	if !strings.Contains(plain, "feat/ABC-123-fix-login") {
		t.Errorf("nil cfg must leave the branch untouched:\n%s", plain)
	}
}

func TestStripTicketKey(t *testing.T) {
	cases := map[string]string{
		"feat/ABC-123-fix-login": "feat/fix-login",
		"ABC-123":                "ABC-123", // nothing left over — keep as-is
		"feat/ABC-123":           "feat",
		"feat/fix-login":         "feat/fix-login",
	}
	for in, want := range cases {
		if got := stripTicketKey(in, "ABC-123"); got != want {
			t.Errorf("stripTicketKey(%q) = %q, want %q", in, got, want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts/claude-status && go test ./... -run 'Ticket' -v`
Expected: FAIL — `undefined: renderLinesWithJira`, `undefined: stripTicketKey`

- [ ] **Step 3: Write minimal implementation**

Append to `jira.go`:

```go
// stripTicketKey removes the key from a branch label so the statusline doesn't
// print it twice in adjacent segments. Returns the branch unchanged when
// removing the key would leave nothing.
func stripTicketKey(branch, key string) string {
	if key == "" || !strings.Contains(strings.ToUpper(branch), key) {
		return branch
	}
	i := strings.Index(strings.ToUpper(branch), key)
	out := branch[:i] + branch[i+len(key):]
	// Removing the key leaves adjacent separators ("feat/-fix-login"); collapse
	// each run to its first character rather than to a fixed one, so an
	// underscore-separated branch stays underscore-separated.
	out = sepRunRe.ReplaceAllStringFunc(out, func(m string) string { return m[:1] })
	out = strings.Trim(out, "/_-")
	if out == "" {
		return branch
	}
	return out
}

var sepRunRe = regexp.MustCompile(`[/_-]{2,}`)
```

In `main.go`, rename the existing `renderLines` to `renderLinesWithJira` and add
the `cfg *jiraConfig` parameter, then add a thin wrapper preserving the old
signature for the existing 40+ tests:

```go
func renderLines(p Payload, git *gitState, cols int, verbose bool, fb fallback) []string {
	return renderLinesWithJira(p, git, cols, verbose, fb, loadJiraConfig(jiraConfigPath()))
}

func renderLinesWithJira(p Payload, git *gitState, cols int, verbose bool, fb fallback, cfg *jiraConfig) []string {
```

Inside `renderLinesWithJira`, after the `branch, worktreeName` switch ends
(`main.go:626`) and **before** the `if branch != "" || worktreeName != ""` block:

```go
	root := p.Workspace.GitWorktree
	if root == "" {
		root = cwd
	}
	ticketKey := resolveTicketKey(root, branch, cfg)
	// Narrow drops the ticket segment, so the branch must keep the key there or
	// it disappears from the statusline entirely.
	if ticketKey != "" && t != narrow {
		branch = stripTicketKey(branch, ticketKey)
	}
```

Then inside the `if t != narrow {` block, immediately before the `if p.PR != nil`
block at `main.go:666` — the ticket and the PR are the same work item at two
stages, so they sit together:

```go
		if ticketKey != "" {
			gitParts = append(gitParts,
				Yellow+osc8(ticketURL(cfg, ticketKey), "◈ "+ticketKey)+Reset)
		}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd scripts/claude-status && go test ./... -v && gofmt -l . && go vet ./...`
Expected: PASS, no gofmt output, no vet findings. `TestRenderNoEmoji` must still
pass — `◈` (U+25C8) is BMP and single-width.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-status/jira.go scripts/claude-status/main.go scripts/claude-status/main_test.go
git commit -m "feat(statusline): show the session's Jira ticket

The key moves out of the branch label into its own clickable segment
beside the PR, so total line width is unchanged."
```

---

### Task 6: `cj` launch wrapper

**Files:**
- Modify: `home/dot_config/shell/functions.sh`
- Modify: `docs/shell-helpers.md`

**Interfaces:**
- Consumes: the same resolution order, reimplemented in shell for launch time.
- Produces: `cj` shell function.

- [ ] **Step 1: Read the existing conventions**

Run: `cat home/dot_config/shell/functions.sh && grep -n 'gwta' docs/shell-helpers.md`
Confirm the file is sourced by both bash and zsh and note the documented style
of neighbouring helpers before adding to it.

- [ ] **Step 2: Add the function**

Append to `home/dot_config/shell/functions.sh`:

```bash
# Launch Claude Code named after the current worktree's Jira ticket, so the
# /resume picker and tab title are scannable. Deliberately NOT named `claude`:
# shadowing the real binary breaks `claude agents --json` and recurses.
cj() {
  local cfg="$HOME/.config/claude-jira.json" gitdir key branch projects
  gitdir=$(git rev-parse --git-dir 2>/dev/null) || { command claude "$@"; return; }

  if [ -r "$gitdir/claude-jira-ticket" ]; then
    key=$(head -c 256 "$gitdir/claude-jira-ticket" | head -n 1 | tr -d '[:space:]')
  fi

  if [ -z "$key" ] && [ -r "$cfg" ]; then
    projects=$(python3 -c 'import json,sys
try: print("|".join(json.load(open(sys.argv[1])).get("projects",[])))
except Exception: pass' "$cfg" 2>/dev/null)
    if [ -n "$projects" ]; then
      branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
      key=$(printf '%s' "$branch" | grep -oiE "(^|[/_-])($projects)-[0-9]+" |
            head -n 1 | tr -d '/_' | tr '[:lower:]' '[:upper:]')
    fi
  fi

  case "$key" in
    [A-Z][A-Z0-9]*-[1-9]*) command claude -n "$key" "$@" ;;
    *) command claude "$@" ;;
  esac
}
```

- [ ] **Step 3: Verify it renders and shellchecks**

Run: `bash tests/scripts/test_claude_scripts.sh`
Expected: PASS. If `functions.sh` is not already covered by that harness, run
`shellcheck home/dot_config/shell/functions.sh` directly and fix any findings.

- [ ] **Step 4: Verify behavior manually**

Run, from this worktree:
```bash
source home/dot_config/shell/functions.sh
type cj
```
Expected: the function body prints. Then confirm the no-key path is safe:
`cj --help` should behave exactly like `claude --help`.

- [ ] **Step 5: Document it**

Add to `docs/shell-helpers.md`, in the same table/section style as `gwta`:

```markdown
### `cj`

Launches Claude Code named after the current worktree's Jira ticket, so the
`/resume` picker and terminal tab show `JDWLABS-123` instead of a derived name.
Resolves the key from `$(git rev-parse --git-dir)/claude-jira-ticket`, else from
the branch name gated on the project allowlist in `~/.config/claude-jira.json`.
Falls back to a plain `claude` launch when no key resolves.

Rename mid-session with `/rename`. `gwta` remains the way to create a worktree;
`cj` is run from inside one.
```

- [ ] **Step 6: Commit**

```bash
git add home/dot_config/shell/functions.sh docs/shell-helpers.md
git commit -m "feat(shell): add cj, a ticket-named Claude Code launcher"
```

---

### Task 7: Convention change and distribution

**Files:**
- Modify: `home/private_dot_claude/CLAUDE.md`
- Modify: `home/.chezmoiignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the branch convention**

In `home/private_dot_claude/CLAUDE.md`, the Git section currently reads:

```markdown
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + kebab-case.
```

Replace with:

```markdown
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + ticket key +
  kebab-case — `feat/JDWLABS-123-fix-login-retry`. The key is what the
  statusline and `cj` resolve; omit it only for work with no ticket.
```

- [ ] **Step 2: Carve out the comment rule**

The Code Comments section bans ticket IDs outright. Amend its last sentence:

```markdown
No noise comments, no external references (URLs, names) — traceability goes in
commits/PRs. Ticket IDs stay out of comments; the branch name and PR title are
where they belong.
```

- [ ] **Step 3: Exclude from ephemeral machines**

In `home/.chezmoiignore`, add to the `.isEphemeral` block — a ticket lookup in
CI or a Codespace is pure latency and noise:

```
{{ if .isEphemeral }}
.config/claude-jira.json
{{ end }}
```

Verify the surrounding block's exact template syntax first with
`cat home/.chezmoiignore` and match it rather than assuming.

- [ ] **Step 4: Update the README**

The "Claude Code status line" section shows rendered output that is now stale.
Add the ticket segment to the sample using a **synthetic** key only (`ABC-123`),
and note that the feature is off until `~/.config/claude-jira.json` exists.

- [ ] **Step 5: Verify nothing real leaked**

Run:
```bash
grep -rniE '[a-z0-9-]+\.atlassian\.net' --exclude-dir=.git . | grep -v example
```
Expected: no output. Any hit is a real site host in a tracked file and must be
replaced with `example.atlassian.net`.

- [ ] **Step 6: Full verification**

Run:
```bash
cd scripts/claude-status && go test ./... && gofmt -l . && go vet ./...
cd - && bash tests/scripts/test_claude_scripts.sh
```
Expected: all pass, no gofmt output.

- [ ] **Step 7: Commit**

```bash
git add home/private_dot_claude/CLAUDE.md home/.chezmoiignore README.md
git commit -m "docs: adopt ticket-keyed branches and document the Jira segment"
```

---

## Deferred to Phase 2

Not in this plan; see the spec's Phase 2 section: `claude-status -jira`
cross-session listing via `claude agents --json`, and summary enrichment with
its cache, TTL, tmp+rename write path, and Windows rename retry.

## Pre-existing defects (separate PRs)

Surfaced by review, unrelated to this feature:

- `home/private_dot_claude/hooks/executable_session-summary.sh` is shipped and
  tracked but registered nowhere — dead code. Register or delete it.
- `home/private_dot_claude/modify_settings.json.json.tmpl` merges with
  existing-on-disk winning, and replaces list values wholesale. Once
  `settings.json` holds a `hooks.SessionStart` array, every future dotfiles
  change to it silently no-ops.
