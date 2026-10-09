package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func quotaPayload(t *testing.T, raw string) Payload {
	t.Helper()
	var p Payload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

const bothWindows = `{"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1800003600},"seven_day":{"used_percentage":61,"resets_at":1800500000}}}`

func quotaLines(t *testing.T, path string) []string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(raw)), "\n")
}

func TestLogQuotaAppendsOneReading(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-metrics", "quota.jsonl")
	now := time.Unix(1_800_000_000, 0)
	logQuota(quotaPayload(t, bothWindows), path, now)

	lines := quotaLines(t, path)
	if len(lines) != 1 {
		t.Fatalf("got %d lines, want 1: %q", len(lines), lines)
	}
	var got map[string]float64
	if err := json.Unmarshal([]byte(lines[0]), &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]float64{"at": 1_800_000_000, "five_hour_pct": 12.5, "five_hour_resets_at": 1_800_003_600,
		"seven_day_pct": 61, "seven_day_resets_at": 1_800_500_000}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %v, want %v", k, got[k], v)
		}
	}
	if len(got) != len(want) {
		t.Errorf("unexpected fields in %v", got)
	}
}

func TestLogQuotaThrottlesToFiveMinutes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "quota.jsonl")
	p := quotaPayload(t, bothWindows)
	now := time.Unix(1_800_000_000, 0)
	logQuota(p, path, now)
	logQuota(p, path, now.Add(60*time.Second))
	if n := len(quotaLines(t, path)); n != 1 {
		t.Fatalf("a call 60s later appended: %d lines", n)
	}
	logQuota(p, path, now.Add(301*time.Second))
	if n := len(quotaLines(t, path)); n != 2 {
		t.Fatalf("a call 301s later did not append: %d lines", n)
	}
}

func TestLogQuotaOmitsAbsentWindow(t *testing.T) {
	path := filepath.Join(t.TempDir(), "quota.jsonl")
	logQuota(quotaPayload(t, `{"rate_limits":{"seven_day":{"used_percentage":90,"resets_at":5}}}`), path, time.Unix(1_800_000_000, 0))
	line := quotaLines(t, path)[0]
	if strings.Contains(line, "five_hour") || !strings.Contains(line, `"seven_day_pct":90`) {
		t.Errorf("unexpected line %q", line)
	}
}

func TestLogQuotaWritesNothingWithoutRateLimits(t *testing.T) {
	for _, raw := range []string{`{}`, `{"rate_limits":{}}`} {
		path := filepath.Join(t.TempDir(), "quota.jsonl")
		logQuota(quotaPayload(t, raw), path, time.Unix(1_800_000_000, 0))
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("payload %s created the log", raw)
		}
	}
}

func TestLogQuotaIgnoresAnUnwritablePath(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(blocker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	logQuota(quotaPayload(t, bothWindows), filepath.Join(blocker, "quota.jsonl"), time.Unix(1_800_000_000, 0))
}

func TestQuotaLogPathHonoursTheStateOverride(t *testing.T) {
	t.Setenv("AGENT_METRICS_STATE", "/custom/state")
	if got := quotaLogPath(); got != filepath.Join("/custom/state", "quota.jsonl") {
		t.Errorf("got %q", got)
	}
	t.Setenv("AGENT_METRICS_STATE", "")
	t.Setenv("XDG_STATE_HOME", "/xdg")
	if got := quotaLogPath(); got != filepath.Join("/xdg", "agent-metrics", "quota.jsonl") {
		t.Errorf("got %q", got)
	}
}
