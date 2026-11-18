// The server target: listen behind the ALB. Mirrors src/main_server.py.
//
// node:http rather than a framework: the template should not decide that for
// you, and one fewer dependency is one fewer thing to keep patched. Swap in
// express or fastify when the routes justify it.
import { get } from "node:http";
import { createServer } from "node:http";

import { processRequest } from "./main";

// The port the deployment publishes. Substituted at bootstrap from the same
// value that fills ContainerPort in the CFN targets, so the ALB target group
// and the listener cannot disagree with what the process binds. PORT
// overrides it for a local run.
const DEFAULT_PORT = "{{CONTAINER_PORT}}";

// What the ALB target group checks. It is the alb module's default, and
// probeHealth below asks for the same path, so the two cannot drift apart.
const HEALTH_PATH = "/health";

// Bounds the self-probe. It runs inside the container against its own
// loopback, so anything slower than this is a hung process rather than a slow
// network.
const PROBE_TIMEOUT_MS = 3_000;

const port = parseInt(process.env.PORT ?? DEFAULT_PORT, 10);

/**
 * Ask this process's own health endpoint whether it is serving. This is what
 * `node build/src/main_server.js --healthcheck` runs: the container health
 * check calls the same program rather than curl, because the slim base image
 * carries neither curl nor wget, and the program already knows its port and
 * path - nothing has to be kept in step with a string in a CloudFormation
 * template.
 */
function probeHealth(): void {
    // 127.0.0.1 rather than localhost: no DNS lookup, and no IPv6 attempt
    // first in an image whose loopback may have no AAAA record.
    const request = get(
        { host: "127.0.0.1", port, path: HEALTH_PATH, timeout: PROBE_TIMEOUT_MS },
        (response) => {
            response.resume();
            if (response.statusCode !== 200) {
                console.error(`probe ${HEALTH_PATH}: status ${response.statusCode}`);
                process.exit(1);
            }
            process.exit(0);
        },
    );
    request.on("timeout", () => {
        console.error(`probe ${HEALTH_PATH}: timed out after ${PROBE_TIMEOUT_MS}ms`);
        request.destroy();
        process.exit(1);
    });
    request.on("error", (error) => {
        console.error(`probe ${HEALTH_PATH}: ${error.message}`);
        process.exit(1);
    });
}


const server = createServer((request, response) => {
    // The ALB target group health check. Keep it free of dependencies: if it
    // calls the database, a slow database takes the whole service out.
    if (request.url === HEALTH_PATH) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ status: "ok" }));
        return;
    }

    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
        void processRequest(Buffer.concat(chunks).toString())
            .then((output) => {
                response.writeHead(200, { "content-type": "application/json" });
                response.end(JSON.stringify({ output }));
            })
            .catch((error: unknown) => {
                console.error(error);
                response.writeHead(500, { "content-type": "application/json" });
                response.end(JSON.stringify({ error: String(error) }));
            });
    });
});

// Probing and serving are exclusive: probeHealth exits the process itself, and
// without the else the probe would fall through and try to bind a port the
// real server already holds.
if (process.argv.includes("--healthcheck")) {
    probeHealth();
} else {
    server.listen(port, "0.0.0.0", () => {
        console.log(`listening on :${port} in ${process.env.MODE ?? "online"} mode`);
    });
}
