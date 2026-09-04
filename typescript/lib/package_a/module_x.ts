import { createHash } from "node:crypto";

/**
 * The one piece of work the template does, so there is something to replace
 * with the real thing. Mirrors lib/package_a/module_x.py.
 */
export function f1(input: Record<string, unknown>): string {
    return createHash("sha256").update(JSON.stringify(input)).digest("hex");
}
