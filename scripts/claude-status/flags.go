package main

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
)

// A flags file is a few hundred bytes; anything larger is not ours, and the
// status line must not stall reading it.
const maxFlagsBytes = 64 << 10

type flagsSummary struct {
	Date  string
	Count int
	Worst string
}

// activeFlags is set once per run by main; renderers read it so their
// signatures stay as they are.
var activeFlags flagsSummary

var severityRank = map[string]int{"info": 1, "warn": 2, "critical": 3}

func flagsPath() string { return stateFile("flags.json") }

func ackedPath() string { return stateFile("acked.json") }

func readSmall(path string) ([]byte, bool) {
	if path == "" {
		return nil, false
	}
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() > maxFlagsBytes {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	return raw, err == nil
}

// readFlagsSummary reports the unacknowledged flags the daily report left
// behind. Every failure means "nothing to show": this runs on each status
// line refresh and must never break it.
func readFlagsSummary() (flagsSummary, bool) {
	raw, ok := readSmall(flagsPath())
	if !ok {
		return flagsSummary{}, false
	}
	var f struct {
		Date  string `json:"date"`
		Flags []struct {
			Severity string `json:"severity"`
		} `json:"flags"`
	}
	if json.Unmarshal(raw, &f) != nil || f.Date == "" || len(f.Flags) == 0 {
		return flagsSummary{}, false
	}
	// A malformed ack file acknowledges nothing: showing a flag twice is
	// better than hiding one.
	if rawAck, ok := readSmall(ackedPath()); ok {
		var a struct {
			Dates []string `json:"dates"`
		}
		if json.Unmarshal(rawAck, &a) == nil && slices.Contains(a.Dates, f.Date) {
			return flagsSummary{}, false
		}
	}
	s := flagsSummary{Date: f.Date, Count: len(f.Flags), Worst: "info"}
	for _, fl := range f.Flags {
		if severityRank[fl.Severity] > severityRank[s.Worst] {
			s.Worst = fl.Severity
		}
	}
	return s, true
}

// flagsBadge is the status-line marker; short drops the severity word for
// widths where every column counts.
func flagsBadge(s flagsSummary, short bool) string {
	if s.Count == 0 {
		return ""
	}
	color := Gray
	switch s.Worst {
	case "critical":
		color = BoldRed
	case "warn":
		color = Yellow
	}
	if short {
		return fmt.Sprintf("%s⚑%d%s", color, s.Count, Reset)
	}
	return fmt.Sprintf("%s⚑ %d %s%s", color, s.Count, s.Worst, Reset)
}
