package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// The status line refreshes every few seconds in every open session; one
// reading per interval is plenty for a quota time series.
const quotaLogInterval = 5 * time.Minute

type quotaReading struct {
	At               int64    `json:"at"`
	FiveHourPct      *float64 `json:"five_hour_pct,omitempty"`
	FiveHourResetsAt *int64   `json:"five_hour_resets_at,omitempty"`
	SevenDayPct      *float64 `json:"seven_day_pct,omitempty"`
	SevenDayResetsAt *int64   `json:"seven_day_resets_at,omitempty"`
}

func quotaLogPath() string {
	return stateFile("quota.jsonl")
}

// stateFile resolves a file in the metrics state directory, or "" when no
// home can be found.
func stateFile(name string) string {
	if dir := os.Getenv("AGENT_METRICS_STATE"); dir != "" {
		return filepath.Join(dir, name)
	}
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "agent-metrics", name)
}

// logQuota appends the plan-quota percentages to a local log that the
// metrics collector rolls up. It is a side effect of rendering, so every
// failure is swallowed: the status line must never break or stall over it.
func logQuota(p Payload, path string, now time.Time) {
	rl := p.RateLimits
	if path == "" || rl == nil || (rl.FiveHour == nil && rl.SevenDay == nil) {
		return
	}
	if st, err := os.Stat(path); err == nil && now.Sub(st.ModTime()) < quotaLogInterval {
		return
	}
	r := quotaReading{At: now.Unix()}
	if fh := rl.FiveHour; fh != nil {
		r.FiveHourPct, r.FiveHourResetsAt = &fh.UsedPercentage, &fh.ResetsAt
	}
	if sd := rl.SevenDay; sd != nil {
		r.SevenDayPct, r.SevenDayResetsAt = &sd.UsedPercentage, &sd.ResetsAt
	}
	line, err := json.Marshal(r)
	if err != nil {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0700) != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	// One write in append mode, so concurrent sessions cannot interleave lines.
	_, werr := f.Write(append(line, '\n'))
	f.Close() //nolint:errcheck
	if werr == nil {
		// The throttle reads the mtime, which must follow the caller's clock.
		os.Chtimes(path, now, now) //nolint:errcheck
	}
}
