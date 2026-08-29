import { getToken } from "next-auth/jwt";
import type { NextRequest } from "next/server";
import type { JWT } from "next-auth/jwt";

const baseName = "authjs.session-token";

function isSecureRequest(req: NextRequest) {
    return req.headers.get("x-forwarded-proto") === "https";
}

/**
 * Read the session token even in edge handlers. Handles secure and insecure environments.
 */
export async function getSessionToken(req: NextRequest): Promise<JWT | null> {
    const isSecure = isSecureRequest(req);
    const cookieName = isSecure ? `__Secure-${baseName}` : baseName;

    const token = await getToken({
        req,
        secret: process.env.AUTH_SECRET,
        secureCookie: isSecure,
        cookieName,
    });

    return token;
}
