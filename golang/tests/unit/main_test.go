package unit

import (
	"testing"

	"main/src/app"
)

// Mirrors tests/unit/test_template.py in the Python layer: F1 returns a
// SHA-256 hex digest for any input.
func TestF1(t *testing.T) {
	res := app.F1(map[string]any{"event_data": "abc"})

	if len(res) != 64 {
		t.Fatalf("expected a 64 character digest, got %d: %q", len(res), res)
	}
	for _, c := range res {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			t.Fatalf("not hex: %q", res)
		}
	}

	const want = "8987d2a46ae00b20596a11c516f99dff101495df797fa9d3693c65d438c79204"
	if res != want {
		t.Fatalf("F1 changed: got %q, want %q", res, want)
	}
}
