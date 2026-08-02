package main

import (
	"encoding/json"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
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
		case r == 0xFEFF,
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
// the OS opener on ctrl+click, which is how file:// and \host\share get in.
func ticketURL(cfg *jiraConfig, key string) string {
	if cfg == nil || cfg.SiteBase == "" || key == "" {
		return ""
	}
	return cfg.SiteBase + "/browse/" + key
}

var sepRunRe = regexp.MustCompile(`[/_-]{2,}`)

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
