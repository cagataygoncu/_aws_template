import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

import { f1 } from "../lib/package_a/module_x";

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

    if (mode === "online") {
        // Anything that must not sit in the environment file - endpoints,
        // credentials, keys - comes from Secrets Manager, read with the task
        // role. Log that it was read, never what it contained.
        const secretName = process.env.SECRET_NAME;
        const client = new SecretsManagerClient({});
        const { SecretString } = await client.send(
            new GetSecretValueCommand({ SecretId: secretName }),
        );
        const settings = JSON.parse(SecretString ?? "{}");
        console.log(`read ${Object.keys(settings).length} settings from ${secretName}`);
    }

    const input = { event_data: eventData };
    console.log(`input: ${JSON.stringify(input)}`);

    const output = f1(input);

    console.log(`output: ${output} for input: ${JSON.stringify(input)}`);
    return output;
}
