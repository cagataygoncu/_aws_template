// The task target: process one request, forever. Mirrors src/main_task.py.
import { processRequest } from "./main";

const INTERVAL_MS = 3_000;

async function main(): Promise<void> {
    console.log("main_task starting");

    // The catch sits inside the loop on purpose: this is a long-running ECS
    // service, so one failed iteration must not end the process. A container
    // that exits is a stopped task, and enough stopped tasks trip the
    // deployment circuit breaker and roll the whole deploy back.
    for (;;) {
        try {
            console.log("processing");
            await processRequest("test");
        } catch (error) {
            console.error(error);
        }
        await new Promise((resolve) => setTimeout(resolve, INTERVAL_MS));
    }
}

// Anything that goes wrong around the loop - a missing environment variable,
// a client that will not construct - exits non-zero rather than dying with a
// bare stack trace that `make local-run` can only report as "exited (1)".
main().catch((error) => {
    console.error(error);
    process.exit(1);
});
