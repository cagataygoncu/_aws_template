import { createServer } from "http";
import { parse } from "url";
import next from "next";

// Load secrets from AWS Secrets Manager before starting the app
const secretName = process.env.SECRET_NAME;
if (secretName) {
    try {
        const { SecretsManagerClient, GetSecretValueCommand } = await import(
            "@aws-sdk/client-secrets-manager"
        );
        const client = new SecretsManagerClient({
            region: process.env.AWS_REGION || "ap-southeast-2",
        });
        const { SecretString } = await client.send(
            new GetSecretValueCommand({ SecretId: secretName })
        );
        const secrets = JSON.parse(SecretString);
        let count = 0;
        for (const [key, value] of Object.entries(secrets)) {
            if (!process.env[key]) {
                process.env[key] = String(value);
                count++;
            }
        }
        console.log(
            `Loaded ${count} secrets from "${secretName}" (${Object.keys(secrets).length} total)`
        );
    } catch (err) {
        console.error("Failed to load secrets from Secrets Manager:", err.message);
        process.exit(1);
    }
}

const port = parseInt(process.env.PORT || "3000", 10);
const app = next({ dev: false });
const handle = app.getRequestHandler();

await app.prepare();

createServer((req, res) => {
    handle(req, res, parse(req.url, true));
}).listen(port, "0.0.0.0", () => {
    console.log(`> Ready on http://0.0.0.0:${port}`);
});
