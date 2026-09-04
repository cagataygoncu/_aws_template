import assert from "node:assert/strict";
import { test } from "node:test";

import { f1 } from "../../lib/package_a/module_x";

// Mirrors tests/unit/test_template.py in the Python layer: f1 returns a
// SHA-256 hex digest for any input.
test("f1 returns a sha256 hex digest", () => {
    const result = f1({ event_data: "abc" });

    assert.equal(result.length, 64);
    assert.match(result, /^[0-9a-f]{64}$/);
});
