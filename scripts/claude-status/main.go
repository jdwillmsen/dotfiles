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
	Cwd          string `json:"cwd"`
	SessionID    string `json:"session_id"`
	SessionName  string `json:"session_name"`
	Version      string `json:"version"`
	ExceedsTokens bool  `json:"exceeds_200k_tokens"`

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

	Thinking *struct {
		Enabled bool `json:"enabled"`
	} `json:"thinking"`

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

// ── Git (with 5-second cache keyed on session_id) ────────────────────────────
type gitState struct {
	Branch   string
	Staged   int
	Modified int
}

func getGitState(sessionID string) *gitState {
	cacheFile := fmt.Sprintf("/tmp/claude-status-git-%s", sessionID)

	if sessionID != "" {
		if fi, err := os.Stat(cacheFile); err == nil && time.Since(fi.ModTime()) < 5*time.Second {
			if raw, err := os.ReadFile(cacheFile); err == nil {
				parts := strings.SplitN(string(raw), "|", 3)
				if len(parts) == 3 {
					staged, _ := strconv.Atoi(parts[1])
					modified, _ := strconv.Atoi(parts[2])
					if parts[0] == "" {
						return nil
					}
					return &gitState{Branch: parts[0], Staged: staged, Modified: modified}
				}
			}
		}
	}

	if run("git", "rev-parse", "--git-dir") == "" {
		if sessionID != "" {
			os.WriteFile(cacheFile, []byte("||"), 0600)
		}
		return nil
	}

	branch := run("git", "branch", "--show-current")
	if branch == "" {
		branch = run("git", "rev-parse", "--short", "HEAD")
	}

	staged := countLines(run("git", "diff", "--cached", "--numstat"))
	modified := countLines(run("git", "diff", "--numstat"))

	if sessionID != "" {
		os.WriteFile(cacheFile, []byte(fmt.Sprintf("%s|%d|%d", branch, staged, modified)), 0600)
	}
	return &gitState{Branch: branch, Staged: staged, Modified: modified}
}

func countLines(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	return len(strings.Split(s, "\n"))
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
//   "claude-sonnet-4-6" + "Sonnet"      →  "Sonnet 4.6"
//   "claude-sonnet-4-6" + "Sonnet 4.6"  →  "Sonnet 4.6"  (no duplicate)
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

// fmtResetsAt shows WHEN a rate limit resets + HOW LONG until then.
// The countdown color combines usage and time-to-reset:
//   high usage + reset soon  → green  (relief coming)
//   high usage + reset far   → red    (constrained for a while)
//   low usage                → gray   (not relevant)
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

// ── Main ──────────────────────────────────────────────────────────────────────
func main() {
	var p Payload
	json.NewDecoder(os.Stdin).Decode(&p) //nolint:errcheck

	cwd := p.Workspace.CurrentDir
	if cwd == "" {
		cwd = p.Cwd
	}
	if cwd == "" {
		cwd, _ = os.Getwd()
	}

	git := getGitState(p.SessionID)

	// ── LINE 1 ────────────────────────────────────────────────────────────────
	// Section: model  (⬡ Sonnet 4.6  high  💭)
	var secModel string
	if label := modelLabel(p.Model.ID, p.Model.DisplayName); label != "" {
		s := Purple + Bold + "⬡ " + label + Reset
		if p.Effort != nil && p.Effort.Level != "" {
			s += "  " + Gray + p.Effort.Level + Reset
		}
		if p.Thinking != nil && p.Thinking.Enabled {
			s += "  " + Cyan + "💭" + Reset
		}
		secModel = s
	}

	// Section: git context  (⎇ main +2~3 · 📁 owner/repo · PR #47 ✓)
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
			if git.Staged > 0 {
				b += " " + Green + "+" + strconv.Itoa(git.Staged) + Reset
			}
			if git.Modified > 0 {
				b += " " + Yellow + "~" + strconv.Itoa(git.Modified) + Reset
			}
		}
		gitParts = append(gitParts, b)
	}

	repo := p.Workspace.Repo
	if repo != nil && repo.Name != "" {
		gitParts = append(gitParts, Blue+"📁 "+repo.Owner+"/"+repo.Name+Reset)
	} else if project := filepath.Base(cwd); project != "" && project != "." {
		gitParts = append(gitParts, Blue+"📁 "+project+Reset)
	}

	if p.PR != nil {
		s := fmt.Sprintf("%sPR #%d%s", Cyan, p.PR.Number, Reset)
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

	secGit := strings.Join(gitParts, sep)

	// Section: cost  ($0.04  ⏱ 5m12s)
	var costParts []string
	if cs := fmtCost(p.Cost.TotalCostUSD); cs != "" {
		costParts = append(costParts, cs)
	}
	if ds := fmtDuration(p.Cost.TotalDurationMS); ds != "" {
		costParts = append(costParts, Gray+"⏱ "+Reset+ds)
	}
	secCost := strings.Join(costParts, "  ")

	// Agent (appended to cost section)
	if p.Agent != nil && p.Agent.Name != "" {
		if secCost != "" {
			secCost += "  "
		}
		secCost += Gray + "agent: " + Reset + p.Agent.Name
	}

	// ── LINE 2 ────────────────────────────────────────────────────────────────
	// Section: context window
	// used_percentage = (input + cache tokens) / context_window_size — excludes output tokens.
	// Auto-compact fires at ~90% (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE to change).
	// Note: Claude Code has a known bug where 1M-context models may report
	// context_window_size=200000, making used_percentage appear inflated.
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
		secCtx = sec(
			fmt.Sprintf("ctx %s %s%.0f%%%s", bar(pct, 10), pctColor(pct), pct, Reset),
			fmt.Sprintf("%s%dk/%dk%s", Gray, usedK, totalK, Reset),
		) + suffix
	}

	// Section: rate limits  (5h ███░ 38% ↺ 3:45pm (2h30m) · 7d ████░ 61% ↺ Thu 9am (1d14h))
	var rateParts []string
	if p.RateLimits != nil {
		if fh := p.RateLimits.FiveHour; fh != nil {
			rateParts = append(rateParts,
				fmt.Sprintf("5h %s %s%.0f%%%s  %s",
					bar(fh.UsedPercentage, 8),
					pctColor(fh.UsedPercentage), fh.UsedPercentage, Reset,
					fmtResetsAt(fh.ResetsAt, fh.UsedPercentage)))
		}
		if sd := p.RateLimits.SevenDay; sd != nil {
			rateParts = append(rateParts,
				fmt.Sprintf("7d %s %s%.0f%%%s  %s",
					bar(sd.UsedPercentage, 8),
					pctColor(sd.UsedPercentage), sd.UsedPercentage, Reset,
					fmtResetsAt(sd.ResetsAt, sd.UsedPercentage)))
		}
	}
	secRate := strings.Join(rateParts, sep)

	secVer := ""
	if p.Version != "" {
		secVer = Gray + "cc " + p.Version + Reset
	}

	// ── LINE 3 ────────────────────────────────────────────────────────────────
	// Section: cache  (💾 73% hit · 35k cached · 5k written · 8k fresh)
	var cacheParts []string
	cu := p.ContextWindow.CurrentUsage
	if cu != nil {
		fresh := cu.InputTokens
		written := cu.CacheCreationInputTokens
		cached := cu.CacheReadInputTokens
		totalIn := fresh + written + cached
		if totalIn > 0 {
			hitPct := float64(cached) / float64(totalIn) * 100
			hitColor := Green
			if hitPct < 30 {
				hitColor = Yellow
			}
			cacheParts = append(cacheParts, fmt.Sprintf("💾 %s%.0f%% hit%s", hitColor, hitPct, Reset))
			if cached > 0 {
				cacheParts = append(cacheParts, fmt.Sprintf("%s%dk cached%s", Gray, cached/1000, Reset))
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

	// Section: tokens  (↑ 4k out · api 29% of time)
	var tokenParts []string
	if out := p.ContextWindow.TotalOutputTokens; out > 0 {
		tokenParts = append(tokenParts, fmt.Sprintf("%s↑%s %s%dk out%s", Cyan, Reset, Gray, out/1000, Reset))
	}
	if p.Cost.TotalDurationMS > 0 && p.Cost.TotalAPIDurationMS > 0 {
		apiPct := float64(p.Cost.TotalAPIDurationMS) / float64(p.Cost.TotalDurationMS) * 100
		tokenParts = append(tokenParts, fmt.Sprintf("%sapi %.0f%%%s", Gray, apiPct, Reset))
	}
	secTokens := strings.Join(tokenParts, "  ")

	// Section: session name
	secSession := ""
	if p.SessionName != "" {
		secSession = Gray + "📝 " + Reset + p.SessionName
	}

	// ── Assemble and print ────────────────────────────────────────────────────
	printLine(secModel, secGit, secCost)
	printLine(secCtx, secRate, secVer)
	printLine(secCache, secTokens, secSession)
}

// printLine joins non-empty sections with sep and prints the result.
// Skips the line entirely if all sections are empty.
func printLine(sections ...string) {
	var out []string
	for _, s := range sections {
		if s != "" {
			out = append(out, s)
		}
	}
	if len(out) > 0 {
		fmt.Println(strings.Join(out, sep))
	}
}
