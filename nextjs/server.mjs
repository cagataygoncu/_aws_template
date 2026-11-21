import { createServer } from "http";
import { parse } from "url";
import next from "next";

import { applyToEnv, loadConfig } from "./config.mjs";

// The configuration (config.mjs): the block of the config object
// container_config.env names, and the secret's API keys - put into process.env
// once, before Next starts, so Next and NextAuth read them there. Not for a
// health probe: that only asks the running server, so it reads nothing.
if (!process.argv.includes("--healthcheck")) {
    try {
        const local = (process.env.MODE ?? "online").toLowerCase() === "local";
        const config = await loadConfig(local);
        const count = applyToEnv(config);
        console.log(
            `block ${config.block}: ${count} environment variables set from ` +
                `${Object.keys(config.settings).length} settings and ${Object.keys(config.apiKeys).length} API keys`,
        );
    } catch (err) {
        console.error("Failed to load the configuration:", err.message);
        process.exit(1);
    }
}

const port = parseInt(process.env.PORT || "3000", 10);

// What the ALB target group checks, served by src/app/api/health/route.ts.
// The container health check probes the same path through this file, so the
// two cannot drift apart.
const HEALTH_PATH = "/api/health";
const PROBE_TIMEOUT_MS = 3_000;

// `node server.mjs --healthcheck` asks this container's own health endpoint
// whether it is serving and reports through the exit status. Running the same
// program rather than curl keeps the port and path in one place, and the slim
// base image carries neither curl nor wget.
//
// It returns before Next is prepared, so the probe never boots the app.
if (process.argv.includes("--healthcheck")) {
    const { get } = await import("http");
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
} else {
    const app = next({ dev: false });
    const handle = app.getRequestHandler();

    await app.prepare();

    createServer((req, res) => {
        handle(req, res, parse(req.url, true));
    }).listen(port, "0.0.0.0", () => {
        console.log(`> Ready on http://0.0.0.0:${port}`);
    });
}
