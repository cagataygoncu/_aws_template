import assert from "node:assert/strict";
import { test } from "node:test";

import { checkCredentials, loadConfig, resolveBlock } from "../../src/config";

// The config object as shipped: a broken services/*.json fails the build.
// Mirrors tests/unit/test_config.py in the Python layer. npm test runs from the
// project root, where container_config.env and services/ are.

test("the shipped config object resolves", async () => {
    delete process.env.CONFIG_KEY; // both read from container_config.env
    delete process.env.CONFIG_BLOCK;
    const config = await loadConfig(true);
    assert.ok(Object.keys(config.settings).length > 0, "the block resolved to no settings");
});

test("a block's keys win over its profile's", () => {
    const data = { profiles: { p: { A: 1, B: 1 } }, blk: { PROFILE: "p", B: 2 } };
    assert.deepEqual(resolveBlock(data, "blk"), { A: 1, B: 2, PROFILE: "p" });
});

test("a missing block or profile fails", () => {
    assert.throws(() => resolveBlock({}, "blk"), /no block/);
    assert.throws(() => resolveBlock({ blk: { PROFILE: "nope" } }, "blk"), /names profile/);
});

test("an unknown credential id fails", () => {
    assert.throws(
        () => checkCredentials({ X_CREDENTIAL: "cred_9" }, { cred_1: { username: "u", password: "p" } }),
        /X_CREDENTIAL=cred_9/,
    );
});
