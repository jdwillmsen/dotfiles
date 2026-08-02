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
