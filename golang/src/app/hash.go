package app

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
)

// F1 mirrors lib/package_a/module_x.py in the Python layer: the one piece of
// work the template does, so there is something to replace with the real
// thing. It hashes the rendered input rather than any one field, which keeps
// it honest about what it was given.
func F1(input map[string]any) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%v", input)))
	return hex.EncodeToString(sum[:])
}
