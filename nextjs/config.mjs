/**
 * The service's configuration: one secret, one config object, one block.
 *
 * container_config.env names all three:
 *
 *   AWS_SECRET_NAME   the Secrets Manager secret - credentials and API keys only:
 *                     {"credentials": {"<id>": {"username": ..., "password": ...}},
 *                      "api_keys": {"<id>": "<key>"}}
 *   CONFIG_BUCKET     the config object in S3: every other setting, as JSON
 *   CONFIG_KEY
 *   CONFIG_BLOCK      the block of the config object this deployment runs
 *
 * A block may name a PROFILE from the object's "profiles"; the block's own keys
 * win over its profile's. A setting ending in _CREDENTIAL holds a credential
 * id, looked up in the secret.
 *
 * server.mjs loads it once, before Next starts, and applyToEnv() puts it where
 * Next and NextAuth read: each setting, and each API key under its id, becomes
 * an environment variable unless one is already set. So a secret of
 * {"api_keys": {"AUTH_SECRET": "..."}} gives NextAuth its AUTH_SECRET.
 *
 * With MODE=local nothing is read from AWS: the config object is the local
 * copy, services/<basename of CONFIG_KEY>, and there are no credentials or API
 * keys. CONFIG_KEY and CONFIG_BLOCK a local run does not have are read from
 * container_config.env. Mirrors src/config.py in the Python layer.
 */
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

const CREDENTIAL_SUFFIX = "_CREDENTIAL";
const ENV_FILE = "container_config.env";

function isObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The block's settings, on top of its PROFILE's. */
export function resolveBlock(data, blockName) {
    if (!(blockName in data)) {
        throw new Error(`the config object has no block "${blockName}"`);
    }
    const block = data[blockName];
    if (!isObject(block)) {
        throw new Error(`block "${blockName}" is not a JSON object`);
    }
    const profileName = block.PROFILE;
    if (typeof profileName !== "string" || profileName === "") {
        return { ...block };
    }
    const profiles = isObject(data.profiles) ? data.profiles : {};
    const profile = profiles[profileName];
    if (!isObject(profile)) {
        throw new Error(`block "${blockName}" names profile "${profileName}", which the config object does not have`);
    }
    return { ...profile, ...block };
}

/** Every *_CREDENTIAL setting names a credential the secret holds. */
export function checkCredentials(settings, credentials) {
    const missing = Object.entries(settings)
        .filter(([key, value]) => key.endsWith(CREDENTIAL_SUFFIX) && !(String(value) in credentials))
        .map(([key, value]) => `${key}=${String(value)}`)
        .sort();
    if (missing.length > 0) {
        throw new Error(`credential ids not in the secret: ${missing.join(", ")}`);
    }
}

/** An environment variable; for a local run, else container_config.env's. */
function setting(name, local) {
    const value = process.env[name] ?? "";
    if (value !== "" || !local || !existsSync(ENV_FILE)) {
        return value;
    }
    for (const line of readFileSync(ENV_FILE, "utf8").split("\n")) {
        if (line.startsWith(`${name}=`)) {
            return line.slice(name.length + 1).trim();
        }
    }
    return "";
}

async function readConfigObject(local) {
    const key = setting("CONFIG_KEY", local);
    if (local) {
        if (key === "") {
            throw new Error("CONFIG_KEY is not set");
        }
        return readFileSync(join("services", basename(key)), "utf8");
    }
    const bucket = setting("CONFIG_BUCKET", local);
    if (bucket === "" || key === "") {
        throw new Error("CONFIG_BUCKET and CONFIG_KEY must both be set");
    }
    const { GetObjectCommand, S3Client } = await import("@aws-sdk/client-s3");
    const { Body } = await new S3Client({}).send(new GetObjectCommand({ Bucket: bucket, Key: key }));
    return (await Body?.transformToString()) ?? "";
}

export async function loadConfig(local) {
    const blockName = setting("CONFIG_BLOCK", local);
    if (blockName === "") {
        throw new Error("CONFIG_BLOCK is not set");
    }
    const settings = resolveBlock(JSON.parse(await readConfigObject(local)), blockName);
    const config = { block: blockName, settings, credentials: {}, apiKeys: {} };
    if (local) {
        return config;
    }
    const secretName = process.env.AWS_SECRET_NAME ?? "";
    if (secretName !== "") {
        const { GetSecretValueCommand, SecretsManagerClient } = await import("@aws-sdk/client-secrets-manager");
        const { SecretString } = await new SecretsManagerClient({}).send(
            new GetSecretValueCommand({ SecretId: secretName }),
        );
        const secret = JSON.parse(SecretString ?? "{}");
        config.credentials = secret.credentials ?? {};
        config.apiKeys = secret.api_keys ?? {};
    }
    checkCredentials(settings, config.credentials);
    return config;
}

/**
 * Each setting with a plain value, and each API key under its id, as an
 * environment variable - unless one is already set, which always wins.
 * Returns how many were set.
 */
export function applyToEnv(config, env = process.env) {
    let count = 0;
    const plain = Object.entries(config.settings).filter(([, v]) => ["string", "number", "boolean"].includes(typeof v));
    for (const [key, value] of [...plain, ...Object.entries(config.apiKeys)]) {
        if (env[key] === undefined || env[key] === "") {
            env[key] = String(value);
            count++;
        }
    }
    return count;
}
