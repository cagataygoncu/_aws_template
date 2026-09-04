// The lambda target: the runtime invokes handler. Mirrors src/main_lambda.py.
import type { Context } from "aws-lambda";

import { processRequest } from "./main";

export async function handler(
    event: Record<string, unknown>,
    context: Context,
): Promise<Record<string, unknown>> {
    if (event.warmup) {
        return { statusCode: 200 };
    }

    try {
        const eventData = event.event_data ?? event;
        console.log(`handler: requestId=${context.awsRequestId}`);

        const output = await processRequest(eventData);

        return { statusCode: 200, output, error: null };
    } catch (error) {
        console.error(error);
        return { statusCode: 500, output: null, error: String(error) };
    }
}
