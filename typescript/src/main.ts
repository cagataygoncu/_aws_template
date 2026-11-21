import { f1 } from "../lib/package_a/module_x";
import { getConfig } from "./config";

/**
 * Where the service gets the things it depends on. Deployed code is online; a
 * local run opts out with MODE=local.
 *
 * Online is the default so that nothing has to be set on AWS, and forgetting
 * to set it locally fails loudly on the first AWS call rather than silently
 * running against stub data in production.
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
 * The one function every entrypoint calls - the task loop, the server handler
 * and the Lambda handler all funnel into it, so the behaviour is the same
 * however this is deployed. Mirrors process_request in src/main.py.
 */
export async function processRequest(eventData: unknown, mode?: Mode): Promise<string> {
    mode = mode ?? getMode();

    // The settings: the block of the config object container_config.env
    // names, with credentials from the secret (config.ts). Read once, then
    // kept. Log what was read, never a credential or key.
    const config = await getConfig(mode === "local");
    console.log(
        `block ${config.block}: ${Object.keys(config.settings).length} settings, ` +
            `${Object.keys(config.credentials).length} credentials`,
    );

    const input = { event_data: eventData };
    console.log(`input: ${JSON.stringify(input)}`);

    const output = f1(input);

    console.log(`output: ${output} for input: ${JSON.stringify(input)}`);
    return output;
}
