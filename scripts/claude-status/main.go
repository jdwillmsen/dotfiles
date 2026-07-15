package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ── ANSI ──────────────────────────────────────────────────────────────────────
const (
	Reset   = "\033[0m"
	Bold    = "\033[1m"
	Dim     = "\033[2m"
	Gray    = "\033[90m"
	Red     = "\033[91m"
	Green   = "\033[92m"
	Yellow  = "\033[93m"
	Blue    = "\033[94m"
	Purple  = "\033[95m"
	Cyan    = "\033[96m"
	BoldRed = "\033[1;91m" // critical threshold
)

// sep divides all segments uniformly.
var sep = "  " + Gray + "│" + Reset + "  "

// osc8 makes text clickable in terminals that support hyperlinks
// (Windows Terminal, iTerm2, Kitty, WezTerm); others render it as plain text.
func osc8(url, text string) string {
	if url == "" {
		return text
	}
	return "\033]8;;" + url + "\033\\" + text + "\033]8;;\033\\"
}

// sec joins non-empty strings with spaces (items within a logical group).
func sec(items ...string) string {
	var out []string
	for _, s := range items {
		if s != "" {
			out = append(out, s)
		}
	}
	return strings.Join(out, "  ")
}

// ── Payload — exact JSON schema from Claude Code docs ─────────────────────────
type Payload struct {
	Cwd           string `json:"cwd"`
	SessionID     string `json:"session_id"`
	SessionName   string `json:"session_name"`
	Version       string `json:"version"`
	ExceedsTokens bool   `json:"exceeds_200k_tokens"`

	Model struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`

	Workspace struct {
		CurrentDir  string   `json:"current_dir"`
		ProjectDir  string   `json:"project_dir"`
		AddedDirs   []string `json:"added_dirs"`
		GitWorktree string   `json:"git_worktree"`
		Repo        *struct {
			Host  string `json:"host"`
			Owner string `json:"owner"`
			Name  string `json:"name"`
		} `json:"repo"`
	} `json:"workspace"`

	Cost struct {
		TotalCostUSD       float64 `json:"total_cost_usd"`
		TotalDurationMS    int64   `json:"total_duration_ms"`
		TotalAPIDurationMS int64   `json:"total_api_duration_ms"`
		TotalLinesAdded    int     `json:"total_lines_added"`
		TotalLinesRemoved  int     `json:"total_lines_removed"`
	} `json:"cost"`

	ContextWindow struct {
		TotalInputTokens  int      `json:"total_input_tokens"`
		TotalOutputTokens int      `json:"total_output_tokens"`
		ContextWindowSize int      `json:"context_window_size"`
		UsedPercentage    *float64 `json:"used_percentage"`
		RemainingPct      *float64 `json:"remaining_percentage"`
		CurrentUsage      *struct {
			InputTokens              int `json:"input_tokens"`
			OutputTokens             int `json:"output_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
		} `json:"current_usage"`
	} `json:"context_window"`

	Effort *struct {
		Level string `json:"level"`
	} `json:"effort"`

	RateLimits *struct {
		FiveHour *struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       int64   `json:"resets_at"`
		} `json:"five_hour"`
		SevenDay *struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       int64   `json:"resets_at"`
		} `json:"seven_day"`
	} `json:"rate_limits"`

	Vim *struct {
		Mode string `json:"mode"`
	} `json:"vim"`

	OutputStyle *struct {
		Name string `json:"name"`
	} `json:"output_style"`

	Agent *struct {
		Name string `json:"name"`
	} `json:"agent"`

	PR *struct {
		Number      int    `json:"number"`
		URL         string `json:"url"`
		ReviewState string `json:"review_state"`
	} `json:"pr"`

	Worktree *struct {
		Name           string `json:"name"`
		Branch         string `json:"branch"`
		OriginalBranch string `json:"original_branch"`
	} `json:"worktree"`
}

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

// ── Git (with 5-second cache keyed on session_id) ────────────────────────────
type gitState struct {
	Branch    string
	Ahead     int
	Behind    int
	Staged    int
	Modified  int
	Untracked int
}

// parsePorcelainV2 extracts branch, ahead/behind, and change counts from
// `git status --porcelain=v2 --branch` output — one subprocess replaces the
// four separate git calls this used to need.
func parsePorcelainV2(out string) gitState {
	var g gitState
	var oid string
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "# branch.oid "):
			oid = strings.TrimPrefix(line, "# branch.oid ")
		case strings.HasPrefix(line, "# branch.head "):
			g.Branch = strings.TrimPrefix(line, "# branch.head ")
		case strings.HasPrefix(line, "# branch.ab "):
			fmt.Sscanf(strings.TrimPrefix(line, "# branch.ab "), "+%d -%d", &g.Ahead, &g.Behind) //nolint:errcheck
		case strings.HasPrefix(line, "1 ") || strings.HasPrefix(line, "2 "):
			// XY field: X = staged state, Y = worktree state; '.' means unchanged
			if len(line) >= 4 {
				if line[2] != '.' {
					g.Staged++
				}
				if line[3] != '.' {
					g.Modified++
				}
			}
		case strings.HasPrefix(line, "u "):
			g.Modified++ // unmerged needs worktree attention
		case strings.HasPrefix(line, "? "):
			g.Untracked++
		}
	}
	if g.Branch == "(detached)" && len(oid) >= 7 {
		g.Branch = oid[:7]
	}
	return g
}

// cachePath must use os.TempDir(): a literal "/tmp" on Windows resolves
// relative to the cwd's drive and silently breaks caching when <drive>:\tmp
// doesn't exist.
func cachePath(sessionID string) string {
	return filepath.Join(os.TempDir(), "claude-status-git-"+sessionID)
}

// encodeGitState serializes for the session cache file; nil (not a git repo)
// becomes an empty-branch sentinel so negative results are cached too.
func encodeGitState(g *gitState) string {
	if g == nil {
		return "|0|0|0|0|0"
	}
	return fmt.Sprintf("%s|%d|%d|%d|%d|%d", g.Branch, g.Ahead, g.Behind, g.Staged, g.Modified, g.Untracked)
}

func decodeGitState(raw string) *gitState {
	parts := strings.Split(raw, "|")
	if len(parts) != 6 || parts[0] == "" {
		return nil
	}
	atoi := func(s string) int { n, _ := strconv.Atoi(s); return n }
	return &gitState{
		Branch: parts[0], Ahead: atoi(parts[1]), Behind: atoi(parts[2]),
		Staged: atoi(parts[3]), Modified: atoi(parts[4]), Untracked: atoi(parts[5]),
	}
}

// cleanStaleCaches removes cache files from sessions older than a day —
// they otherwise accumulate one per session forever.
func cleanStaleCaches(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "claude-status-git-") {
			continue
		}
		if fi, err := e.Info(); err == nil && time.Since(fi.ModTime()) > 24*time.Hour {
			os.Remove(filepath.Join(dir, e.Name())) //nolint:errcheck
		}
	}
}

func getGitState(sessionID string) *gitState {
	cacheFile := cachePath(sessionID)

	if sessionID != "" {
		if fi, err := os.Stat(cacheFile); err == nil && time.Since(fi.ModTime()) < 5*time.Second {
			if raw, err := os.ReadFile(cacheFile); err == nil {
				return decodeGitState(string(raw))
			}
		}
	}

	// --branch always emits "# branch.*" headers inside a repo, so empty
	// output means git failed (not a repo).
	var g *gitState
	if out := run("git", "status", "--porcelain=v2", "--branch"); out != "" {
		st := parsePorcelainV2(out)
		g = &st
	}

	if sessionID != "" {
		os.WriteFile(cacheFile, []byte(encodeGitState(g)), 0600) //nolint:errcheck
		cleanStaleCaches(os.TempDir())                           // only on the slow path, never on cache hits
	}
	return g
}

func run(args ...string) string {
	out, err := exec.Command(args[0], args[1:]...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ── Formatting helpers ────────────────────────────────────────────────────────
var (
	modelRe    = regexp.MustCompile(`^(.+?)-(\d+)-(\d+)(?:-\d+)?$`)
	hasVersion = regexp.MustCompile(`\d+\.\d+`)
)

// modelLabel combines display_name with version parsed from id.
//
//	"claude-sonnet-4-6" + "Sonnet"      →  "Sonnet 4.6"
//	"claude-sonnet-4-6" + "Sonnet 4.6"  →  "Sonnet 4.6"  (no duplicate)
func modelLabel(id, displayName string) string {
	m := strings.TrimPrefix(id, "claude-")
	if ms := modelRe.FindStringSubmatch(m); ms != nil {
		version := ms[2] + "." + ms[3]
		if displayName != "" {
			if hasVersion.MatchString(displayName) {
				return displayName // display_name already includes version
			}
			return displayName + " " + version
		}
		return ms[1] + " " + version
	}
	if displayName != "" {
		return displayName
	}
	return m
}

// pctColor returns a 4-tier color scaled to auto-compact territory.
// Auto-compact fires at ~90% by default, so tiers are anchored there.
func pctColor(pct float64) string {
	switch {
	case pct >= 90:
		return BoldRed // compact imminent
	case pct >= 75:
		return Red
	case pct >= 50:
		return Yellow
	default:
		return Green
	}
}

func bar(pct float64, width int) string {
	filled := int(pct / 100 * float64(width))
	if filled > width {
		filled = width
	}
	return pctColor(pct) + strings.Repeat("█", filled) + Gray + strings.Repeat("░", width-filled) + Reset
}

func fmtDuration(ms int64) string {
	if ms <= 0 {
		return ""
	}
	s := ms / 1000
	m := s / 60
	h := m / 60
	if h > 0 {
		return fmt.Sprintf("%dh%dm", h, m%60)
	}
	if m > 0 {
		return fmt.Sprintf("%dm%ds", m, s%60)
	}
	return fmt.Sprintf("%ds", s)
}

func fmtCost(usd float64) string {
	if usd <= 0 {
		return ""
	}
	if usd < 0.005 {
		return Gray + "<$0.01" + Reset
	}
	color := Yellow
	if usd >= 1.0 {
		color = Red
	}
	return fmt.Sprintf("%s$%.2f%s", color, usd, Reset)
}

// paceDelta compares quota burn against window progress — a raw percentage
// is a weak signal, but "used 80% with half the window left" is actionable.
// Quiet when within ±10pts of pace; ▲ = outrunning the window, ▼ = headroom.
func paceDelta(usedPct float64, resetsAtUnix int64, window time.Duration, now time.Time) string {
	if resetsAtUnix == 0 {
		return ""
	}
	remaining := time.Unix(resetsAtUnix, 0).Sub(now)
	if remaining <= 0 || remaining > window {
		return ""
	}
	elapsedPct := (1 - remaining.Seconds()/window.Seconds()) * 100
	delta := usedPct - elapsedPct
	switch {
	case delta >= 10:
		return Red + "▲" + Reset
	case delta <= -10:
		return Green + "▼" + Reset
	default:
		return ""
	}
}

// fmtResetsAt shows WHEN a rate limit resets + HOW LONG until then.
// The countdown color combines usage and time-to-reset:
//
//	high usage + reset soon  → green  (relief coming)
//	high usage + reset far   → red    (constrained for a while)
//	low usage                → gray   (not relevant)
func fmtResetsAt(unixSec int64, usedPct float64) string {
	if unixSec == 0 {
		return ""
	}
	t := time.Unix(unixSec, 0).Local()
	d := time.Until(t)
	if d <= 0 {
		return Green + "↺ now" + Reset
	}

	// Clock string: include day name when reset is >20h away (7-day window)
	var clock string
	if d > 20*time.Hour {
		clock = t.Format("Mon 3pm")
	} else {
		clock = t.Format("3:04pm")
	}

	// Countdown string
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	var countdown string
	switch {
	case h >= 24:
		days := h / 24
		if hrs := h % 24; hrs > 0 {
			countdown = fmt.Sprintf("%dd%dh", days, hrs)
		} else {
			countdown = fmt.Sprintf("%dd", days)
		}
	case h > 0:
		countdown = fmt.Sprintf("%dh%dm", h, m)
	default:
		countdown = fmt.Sprintf("%dm", m)
	}

	// Countdown color: only meaningful when usage is high enough to care
	countdownColor := Gray
	if usedPct >= 75 {
		switch {
		case d <= 30*time.Minute:
			countdownColor = Green // relief imminent
		case d <= time.Hour:
			countdownColor = Yellow // relief soon
		default:
			countdownColor = Red // constrained for a while
		}
	} else if usedPct >= 50 && d <= 30*time.Minute {
		countdownColor = Green // approaching limit but almost reset
	}

	return Gray + "↺ " + Reset + clock + " " + countdownColor + "(" + countdown + ")" + Reset
}

// ── Layout tiers ──────────────────────────────────────────────────────────────
// Claude Code sets COLUMNS before running the script (v2.1.153+); 0 = unknown.
type tier int

const (
	narrow tier = iota // <80 cols: model + branch + context bar only
	normal             // default: two lines, diagnostics hidden
	wide               // ≥140 cols: three lines, giant context bar
)

func layoutTier(cols int) tier {
	switch {
	case cols > 0 && cols < 80:
		return narrow
	case cols >= 140:
		return wide
	default:
		return normal
	}
}

// ── Render ────────────────────────────────────────────────────────────────────
// renderLines builds the status line(s) for the given terminal width.
// verbose forces the diagnostics line even below the wide tier.
func renderLines(p Payload, git *gitState, cols int, verbose bool, fb fallback) []string {
	t := layoutTier(cols)
	showDiag := t == wide || verbose

	cwd := p.Workspace.CurrentDir
	if cwd == "" {
		cwd = p.Cwd
	}
	if cwd == "" {
		cwd, _ = os.Getwd()
	}

	// ── LINE 1 ────────────────────────────────────────────────────────────────
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

	// Section: git context  (⎇ main ⑂wt ⇡2 ⇣1 +1 ~3 ?4 · owner/repo · PR #47 ✓)
	var gitParts []string

	branch, worktreeName := "", ""
	switch {
	case p.Worktree != nil:
		worktreeName = p.Worktree.Name
		branch = p.Worktree.Branch
		if branch == "" && git != nil {
			branch = git.Branch
		}
	case p.Workspace.GitWorktree != "":
		worktreeName = p.Workspace.GitWorktree
		if git != nil {
			branch = git.Branch
		}
	case git != nil:
		branch = git.Branch
	}

	if branch != "" || worktreeName != "" {
		display := branch
		if display == "" {
			display = worktreeName
		}
		b := Cyan + "⎇ " + display + Reset
		if worktreeName != "" {
			b += " " + Gray + "⑂" + worktreeName + Reset
		}
		if git != nil {
			if git.Ahead > 0 {
				b += " " + Cyan + "⇡" + strconv.Itoa(git.Ahead) + Reset
			}
			if git.Behind > 0 {
				b += " " + Purple + "⇣" + strconv.Itoa(git.Behind) + Reset
			}
			if git.Staged > 0 {
				b += " " + Green + "+" + strconv.Itoa(git.Staged) + Reset
			}
			if git.Modified > 0 {
				b += " " + Yellow + "~" + strconv.Itoa(git.Modified) + Reset
			}
			if git.Untracked > 0 {
				b += " " + Gray + "?" + strconv.Itoa(git.Untracked) + Reset
			}
		}
		gitParts = append(gitParts, b)
	}

	if t != narrow {
		repo := p.Workspace.Repo
		if repo != nil && repo.Name != "" {
			url := "https://" + repo.Host + "/" + repo.Owner + "/" + repo.Name
			gitParts = append(gitParts, Blue+osc8(url, repo.Owner+"/"+repo.Name)+Reset)
		} else if project := filepath.Base(cwd); project != "" && project != "." {
			gitParts = append(gitParts, Blue+project+Reset)
		}

		if p.PR != nil {
			s := Cyan + osc8(p.PR.URL, fmt.Sprintf("PR #%d", p.PR.Number)) + Reset
			switch p.PR.ReviewState {
			case "approved":
				s += " " + Green + "✓" + Reset
			case "changes_requested":
				s += " " + Red + "✗" + Reset
			case "pending":
				s += " " + Yellow + "⟳" + Reset
			case "draft":
				s += " " + Gray + "draft" + Reset
			}
			gitParts = append(gitParts, s)
		}

		// Lines added/removed by Claude this session belong with git context
		added, removed := p.Cost.TotalLinesAdded, p.Cost.TotalLinesRemoved
		if (added > 0 || removed > 0) && git != nil {
			var diff string
			if added > 0 {
				diff += Green + "+" + strconv.Itoa(added) + Reset
			}
			if removed > 0 {
				diff += " " + Red + "-" + strconv.Itoa(removed) + Reset
			}
			gitParts = append(gitParts, strings.TrimSpace(diff))
		}
	}

	secGit := strings.Join(gitParts, sep)

	// Section: cost  ($0.04  5m12s  agent: x)
	secCost := ""
	if t != narrow {
		var costParts []string
		if cs := fmtCost(p.Cost.TotalCostUSD); cs != "" {
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

	// ── LINE 2 ────────────────────────────────────────────────────────────────
	// Section: context window
	// used_percentage = (input + cache tokens) / context_window_size — excludes output tokens.
	// Auto-compact fires at ~90% (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to change).
	// Note: Claude Code has a known bug where 1M-context models may report
	// context_window_size=200000, making used_percentage appear inflated.
	ctxBarWidth := 10
	switch t {
	case narrow:
		ctxBarWidth = 8
	case wide:
		ctxBarWidth = 24 // shape reads faster than numbers from peripheral vision
	}
	var secCtx string
	if p.ContextWindow.UsedPercentage != nil {
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

	// Section: rate limits  (5h ███░ 38%▲ ↺ 3:45pm (2h30m) · 7d ████░ 61% ↺ Thu 9am (1d14h))
	secRate := ""
	if t != narrow && p.RateLimits != nil {
		now := time.Now()
		var rateParts []string
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

	secVer := ""
	if t == wide && p.Version != "" {
		secVer = Gray + "cc " + p.Version + Reset
	}

	lines := []string{
		joinSections(secModel, secGit, secCost),
		joinSections(secCtx, secRate, secVer),
	}

	// ── LINE 3 (wide or verbose only — diagnostics, not glanceable) ──────────
	if showDiag {
		var cacheParts []string
		if cu := p.ContextWindow.CurrentUsage; cu != nil {
			fresh := cu.InputTokens
			written := cu.CacheCreationInputTokens
			cached := cu.CacheReadInputTokens
			if totalIn := fresh + written + cached; totalIn > 0 {
				hitPct := float64(cached) / float64(totalIn) * 100
				hitColor := Green
				if hitPct < 30 {
					hitColor = Yellow
				}
				cacheParts = append(cacheParts, fmt.Sprintf("%scache%s %s%.0f%% hit%s", Gray, Reset, hitColor, hitPct, Reset))
				if cached > 0 {
					cacheParts = append(cacheParts, fmt.Sprintf("%s%dk read%s", Gray, cached/1000, Reset))
				}
				if written > 0 {
					cacheParts = append(cacheParts, fmt.Sprintf("%s%dk written%s", Gray, written/1000, Reset))
				}
				if fresh > 0 {
					cacheParts = append(cacheParts, fmt.Sprintf("%s%dk fresh%s", Gray, fresh/1000, Reset))
				}
			}
		}
		secCache := strings.Join(cacheParts, "  ")

		var tokenParts []string
		if out := p.ContextWindow.TotalOutputTokens; out > 0 {
			tokenParts = append(tokenParts, fmt.Sprintf("%s↑%s %s%dk out%s", Cyan, Reset, Gray, out/1000, Reset))
		}
		if p.Cost.TotalDurationMS > 0 && p.Cost.TotalAPIDurationMS > 0 {
			apiPct := float64(p.Cost.TotalAPIDurationMS) / float64(p.Cost.TotalDurationMS) * 100
			tokenParts = append(tokenParts, fmt.Sprintf("%sapi %.0f%%%s", Gray, apiPct, Reset))
		}
		secTokens := strings.Join(tokenParts, "  ")

		secSession := ""
		if p.SessionName != "" {
			secSession = Dim + p.SessionName + Reset
		}

		lines = append(lines, joinSections(secCache, secTokens, secSession))
	}

	// Drop empty lines while preserving order
	var out []string
	for _, l := range lines {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// joinSections joins non-empty sections with sep.
func joinSections(sections ...string) string {
	var out []string
	for _, s := range sections {
		if s != "" {
			out = append(out, s)
		}
	}
	return strings.Join(out, sep)
}

// ── Subagent rows (settings.subagentStatusLine, invoked as -subagents) ────────
type subTask struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	Status      string `json:"status"`
	Description string `json:"description"`
	Label       string `json:"label"`
	StartTime   int64  `json:"startTime"` // epoch ms
	TokenCount  int    `json:"tokenCount"`
}

type subagentInput struct {
	Columns int       `json:"columns"`
	Tasks   []subTask `json:"tasks"`
}

var ansiSeq = regexp.MustCompile(`\033(\[[0-9;]*m|\]8;;[^\033]*\033\\)`)

func visibleLen(s string) int {
	return len([]rune(ansiSeq.ReplaceAllString(s, "")))
}

func statusGlyph(status string) string {
	switch status {
	case "running":
		return Cyan + "⟳" + Reset
	case "completed", "success", "done":
		return Green + "✓" + Reset
	case "failed", "error":
		return Red + "✗" + Reset
	default:
		return Gray + "·" + Reset
	}
}

func fmtTokens(n int) string {
	if n <= 0 {
		return ""
	}
	if n < 1000 {
		return strconv.Itoa(n)
	}
	return strconv.Itoa(n/1000) + "k"
}

// renderSubagentRow mirrors the main statusline's visual language:
// glyph + bold name + gray description, tokens and elapsed trailing.
// Description absorbs all truncation so the operational fields survive
// narrow panels.
func renderSubagentRow(t subTask, cols int, now time.Time) string {
	if cols <= 0 {
		cols = 80
	}

	head := statusGlyph(t.Status) + " " + Bold + t.Name + Reset

	var tail string
	if tk := fmtTokens(t.TokenCount); tk != "" {
		tail += "  " + Gray + tk + Reset
	}
	if t.StartTime > 0 {
		if d := now.Sub(time.UnixMilli(t.StartTime)); d > 0 {
			tail += "  " + Gray + fmtDuration(d.Milliseconds()) + Reset
		}
	}

	desc := t.Description
	if desc == "" {
		desc = t.Label
	}
	if desc != "" {
		budget := cols - visibleLen(head) - visibleLen(tail) - 2
		if r := []rune(desc); len(r) > budget {
			if budget < 1 {
				budget = 1
			}
			desc = string(r[:budget-1]) + "…"
		}
		return head + "  " + Gray + desc + Reset + tail
	}
	return head + tail
}

func renderSubagentOverrides(in subagentInput, now time.Time) []string {
	lines := make([]string, 0, len(in.Tasks))
	for _, t := range in.Tasks {
		row := struct {
			ID      string `json:"id"`
			Content string `json:"content"`
		}{t.ID, renderSubagentRow(t, in.Columns, now)}
		b, err := json.Marshal(row)
		if err != nil {
			continue
		}
		lines = append(lines, string(b))
	}
	return lines
}

// ── Main ──────────────────────────────────────────────────────────────────────
func main() {
	if len(os.Args) > 1 && os.Args[1] == "-subagents" {
		var in subagentInput
		json.NewDecoder(os.Stdin).Decode(&in) //nolint:errcheck
		for _, line := range renderSubagentOverrides(in, time.Now()) {
			fmt.Println(line)
		}
		return
	}

	var p Payload
	json.NewDecoder(os.Stdin).Decode(&p) //nolint:errcheck

	cols, _ := strconv.Atoi(os.Getenv("COLUMNS"))
	verbose := os.Getenv("CLAUDE_STATUS_VERBOSE") == "1"

	fb := parseFallback()
	for _, line := range renderLines(p, getGitState(p.SessionID), cols, verbose, fb) {
		fmt.Println(line)
	}
}
