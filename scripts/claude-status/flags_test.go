package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func stateWith(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("AGENT_METRICS_STATE", dir)
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func flagsJSON(date string, severities ...string) string {
	var items []string
	for _, s := range severities {
		items = append(items, `{"id":"x","severity":"`+s+`","metric":"m","message":"msg","value":1,"baseline":null}`)
	}
	return `{"date":"` + date + `","window":"daily","flags":[` + strings.Join(items, ",") + `]}`
}

func TestFlagsPathFollowsQuotaRules(t *testing.T) {
	t.Setenv("AGENT_METRICS_STATE", "/s")
	if got := flagsPath(); got != "/s/flags.json" {
		t.Errorf("got %q", got)
	}
	t.Setenv("AGENT_METRICS_STATE", "")
	t.Setenv("XDG_STATE_HOME", "/x")
	if got := flagsPath(); got != "/x/agent-metrics/flags.json" {
		t.Errorf("got %q", got)
	}
}

func TestFlagsBadgeSeverities(t *testing.T) {
	cases := []struct {
		sev  []string
		want string
	}{
		{[]string{"info"}, "info"},
		{[]string{"info", "warn"}, "warn"},
		{[]string{"warn", "critical", "info"}, "critical"},
		{[]string{"bogus"}, "info"},
	}
	for _, c := range cases {
		stateWith(t, map[string]string{"flags.json": flagsJSON("2026-10-08", c.sev...)})
		got, ok := readFlagsSummary()
		if !ok || got.Worst != c.want || got.Count != len(c.sev) || got.Date != "2026-10-08" {
			t.Errorf("%v: got %+v ok=%v, want worst %s", c.sev, got, ok, c.want)
		}
	}
}

func TestFlagsBadgeAbsent(t *testing.T) {
	cases := map[string]map[string]string{
		"no file":    {},
		"malformed":  {"flags.json": "{not json"},
		"wrong type": {"flags.json": `{"date":5,"flags":"x"}`},
		"empty list": {"flags.json": flagsJSON("2026-10-08")},
		"no date":    {"flags.json": `{"flags":[{"severity":"warn"}]}`},
		"acked":      {"flags.json": flagsJSON("2026-10-08", "warn"), "acked.json": `{"dates":["2026-10-07","2026-10-08"]}`},
	}
	for name, files := range cases {
		stateWith(t, files)
		if got, ok := readFlagsSummary(); ok {
			t.Errorf("%s: got %+v, want none", name, got)
		}
	}
}

func TestFlagsBadgeIgnoresMalformedAcks(t *testing.T) {
	stateWith(t, map[string]string{"flags.json": flagsJSON("2026-10-08", "warn"), "acked.json": "garbage"})
	if _, ok := readFlagsSummary(); !ok {
		t.Error("a malformed ack file hid the flags")
	}
	stateWith(t, map[string]string{"flags.json": flagsJSON("2026-10-09", "warn"), "acked.json": `{"dates":["2026-10-08"]}`})
	if _, ok := readFlagsSummary(); !ok {
		t.Error("an older ack hid today's flags")
	}
}

func TestFlagsBadgeSkipsOversizedFile(t *testing.T) {
	stateWith(t, map[string]string{"flags.json": flagsJSON("2026-10-08", "warn") + strings.Repeat(" ", maxFlagsBytes)})
	if _, ok := readFlagsSummary(); ok {
		t.Error("read a file over the size cap")
	}
}

func TestFlagsBadgeText(t *testing.T) {
	s := flagsSummary{Count: 2, Worst: "critical"}
	if got := visibleLen(flagsBadge(s, false)); got != len("⚑ 2 critical") && got != len([]rune("⚑ 2 critical")) {
		t.Errorf("long badge width %d", got)
	}
	if got := ansiSeq.ReplaceAllString(flagsBadge(s, true), ""); got != "⚑2" {
		t.Errorf("short badge %q", got)
	}
	if flagsBadge(flagsSummary{}, false) != "" {
		t.Error("empty summary rendered a badge")
	}
}

func lineWithBadge(t *testing.T, cols int) []string {
	t.Helper()
	old := activeFlags
	activeFlags = flagsSummary{Count: 3, Worst: "warn"}
	t.Cleanup(func() { activeFlags = old })
	return renderLinesWithJira(Payload{}, nil, cols, false, nil)
}

func TestRenderShowsBadgeWithoutExtraLine(t *testing.T) {
	for _, cols := range []int{0, 70, 100, 150} {
		before := renderLinesWithJira(Payload{}, nil, cols, false, nil)
		after := lineWithBadge(t, cols)
		if len(after) > max(len(before), 1) {
			t.Errorf("cols %d: badge added a line (%d -> %d)", cols, len(before), len(after))
		}
		if !strings.Contains(strings.Join(after, "\n"), "⚑") {
			t.Errorf("cols %d: no badge in %q", cols, after)
		}
	}
}

func TestRenderBadgeNeverBreaksCompactWidth(t *testing.T) {
	for cols := 1; cols < compactCols; cols++ {
		for _, l := range lineWithBadge(t, cols) {
			if visibleLen(l) > max(cols-2, 1) {
				t.Errorf("cols %d: line %q is %d wide", cols, l, visibleLen(l))
			}
		}
	}
}

func TestFlagsBadgeAgreesWithNotifyValidation(t *testing.T) {
	cases := map[string]string{
		"bad date":         `{"date":"tomorrow","flags":[{"severity":"warn"}]}`,
		"non-ascii digits": `{"date":"٢٠٢٦-١٠-٠٨","flags":[{"severity":"warn"}]}`,
		"null flag":        `{"date":"2026-10-08","flags":[null]}`,
		"null flags":       `{"date":"2026-10-08","flags":null}`,
		"numeric severity": `{"date":"2026-10-08","flags":[{"severity":5}]}`,
		"scalar flag":      `{"date":"2026-10-08","flags":[3]}`,
	}
	for name, body := range cases {
		stateWith(t, map[string]string{"flags.json": body})
		if got, ok := readFlagsSummary(); ok {
			t.Errorf("%s: got %+v, want none", name, got)
		}
	}
	stateWith(t, map[string]string{"flags.json": `{"date":"2026-10-08","flags":[{"id":"a"}]}`})
	if got, ok := readFlagsSummary(); !ok || got.Worst != "info" {
		t.Errorf("a flag without severity should count as info, got %+v ok=%v", got, ok)
	}
}

func TestFlagsBadgeIgnoresNonRegularFiles(t *testing.T) {
	dir := stateWith(t, nil)
	if err := os.Symlink("/dev/zero", filepath.Join(dir, "flags.json")); err != nil {
		t.Fatal(err)
	}
	if _, ok := readFlagsSummary(); ok {
		t.Error("read a symlink to a device")
	}
}

func realisticPayload() Payload {
	p := fullPayload()
	reset := time.Now().Add(30 * time.Hour).Unix()
	p.RateLimits.SevenDay = &struct {
		UsedPercentage float64 `json:"used_percentage"`
		ResetsAt       int64   `json:"resets_at"`
	}{UsedPercentage: 61, ResetsAt: reset}
	return p
}

func TestBadgeGivesWayBeforeAnythingElse(t *testing.T) {
	p := realisticPayload()
	cfg := &jiraConfig{}
	for cols := 20; cols <= 260; cols++ {
		activeFlags = flagsSummary{}
		before := renderLinesWithJira(p, testGit(), cols, false, cfg)
		activeFlags = flagsSummary{Count: 3, Worst: "critical"}
		after := renderLinesWithJira(p, testGit(), cols, false, cfg)
		activeFlags = flagsSummary{}
		if len(after) != len(before) {
			t.Errorf("cols %d: %d lines became %d", cols, len(before), len(after))
			continue
		}
		for i := range after {
			if after[i] == before[i] {
				continue
			}
			stripped := stripANSI(after[i])
			if !strings.Contains(stripped, "⚑") {
				t.Errorf("cols %d line %d changed without the marker: %q -> %q", cols, i, before[i], after[i])
			}
			if w := visibleLen(after[i]); cols > 0 && w > cols-2 {
				t.Errorf("cols %d line %d: marker made it %d wide", cols, i, w)
			}
			for _, keep := range []string{"5h", "7d", "ctx"} {
				if strings.Contains(stripANSI(before[i]), keep) && !strings.Contains(stripped, keep) {
					t.Errorf("cols %d line %d: marker displaced %q", cols, i, keep)
				}
			}
		}
	}
}
