import { createHash } from "crypto";

/**
 * Where the service gets the things it depends on. Deployed code is online; a
 * local run opts out with MODE=local.
 *
 * Online is the default so that nothing has to be set on AWS, and forgetting
 * to set it locally fails loudly on the first AWS call rather than silently
 * running against stub data in production.
 *
 * Mirrors get_mode() in the Python layer's src/main.py.
 */
export type Mode = "online" | "local";

export function getMode(): Mode {
    const mode = (process.env.MODE ?? "online").toLowerCase();
    if (mode === "local" || mode === "online") {
        return mode;
    }
    console.warn(`unknown MODE "${mode}", falling back to online`);
    return "online";
}

/**
 * The one piece of work the template does, so there is something to replace
 * with the real thing. Mirrors lib/package_a/module_x.py.
 */
export function f1(input: Record<string, unknown>): string {
    return createHash("sha256").update(JSON.stringify(input)).digest("hex");
}

/**
 * The one function every entrypoint calls, so the behaviour is the same
 * however this is deployed. Mirrors process_request in src/main.py.
 *
 * The secret is already read by server.mjs before Next starts, which merges it
 * into process.env - so anything it carries is read from there rather than
 * fetched again per request.
 */
export function processRequest(eventData: unknown, mode?: Mode): string {
    mode = mode ?? getMode();

    if (mode === "online") {
        const secretName = process.env.SECRET_NAME;
        console.log(`online - settings come from "${secretName}", loaded at startup by server.mjs`);
    }

    const input = { event_data: eventData };
    console.log(`input: ${JSON.stringify(input)}`);

    const output = f1(input);

    console.log(`output: ${output} for input: ${JSON.stringify(input)}`);
    return output;
}
