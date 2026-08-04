package main

import (
	"os"
	"path/filepath"
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
		{"bidi override", string(rune(0x202E)) + "gnp.exe", "gnp.exe"},
		{"bare C1 introducer", "a" + string(rune(0x9B)) + "Zb", "aZb"},
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
	if got != "[1;" {
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
	}
	for name, p := range cases {
		if cfg := loadJiraConfig(p); cfg != nil {
			t.Errorf("%s: got %+v, want nil (fail closed)", name, cfg)
		}
	}
}

func TestParseTicketKeyRejects(t *testing.T) {
	bad := []string{
		"", "abc-123", "ABC123", "A-1", "ABC-0", "-1", "ABC-",
		"../../../etc/passwd", "ABC-123/../x", "ABC-12345678",
		"ABCDEFGHIJKL-1", "ABC-123 extra",
	}
	for _, s := range bad {
		if got, ok := parseTicketKey(s); ok {
			t.Errorf("parseTicketKey(%q) = %q, true — want reject", s, got)
		}
	}
}

func TestParseTicketKeyAccepts(t *testing.T) {
	good := map[string]string{
		"ABC-123":      "ABC-123",
		"  ABC-123  ":  "ABC-123",
		"AB1-7":        "AB1-7",
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
		"feat/ABC-1-and-JDWLABS-2":         "ABC-1",
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

	if got := resolveTicketKey(root, "feat/DEF-9-thing", cfg); got != "DEF-9" {
		t.Errorf("branch: got %q, want DEF-9", got)
	}
	if err := os.WriteFile(filepath.Join(gd, "claude-jira-ticket"), []byte("ABC-1"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := resolveTicketKey(root, "feat/DEF-9-thing", cfg); got != "ABC-1" {
		t.Errorf("override: got %q, want ABC-1", got)
	}
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

func TestStripTicketKey(t *testing.T) {
	cases := map[string]string{
		"feat/ABC-123-fix-login": "feat/fix-login",
		"ABC-123":                "ABC-123",
		"feat/ABC-123":           "feat",
		"feat/fix-login":         "feat/fix-login",
	}
	for in, want := range cases {
		if got := stripTicketKey(in, "ABC-123"); got != want {
			t.Errorf("stripTicketKey(%q) = %q, want %q", in, got, want)
		}
	}
}
