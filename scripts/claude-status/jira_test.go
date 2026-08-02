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
