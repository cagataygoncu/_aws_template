// The server target: listen behind the ALB. Mirrors src/main_server.py.
//
// node:http rather than a framework: the template should not decide that for
// you, and one fewer dependency is one fewer thing to keep patched. Swap in
// express or fastify when the routes justify it.
import { createServer } from "node:http";

import { processRequest } from "./main";

// The port the deployment publishes. Substituted at bootstrap from the same
// value that fills ContainerPort in the CFN targets, so the ALB target group
// and the listener cannot disagree with what the process binds. PORT
// overrides it for a local run.
const DEFAULT_PORT = "{{CONTAINER_PORT}}";

const port = parseInt(process.env.PORT ?? DEFAULT_PORT, 10);

const server = createServer((request, response) => {
    // The ALB target group health check. Keep it free of dependencies: if it
    // calls the database, a slow database takes the whole service out.
    if (request.url === "/health") {
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

server.listen(port, "0.0.0.0", () => {
    console.log(`listening on :${port} in ${process.env.MODE ?? "online"} mode`);
});
