import { NextRequest } from "next/server";
import { getSessionToken } from "./lib/session";

const middleware = async (req: NextRequest) => {
    const token = await getSessionToken(req);

    // Redirect non logged-in users to the login page
    if (!token && req.nextUrl.pathname !== "/login") {
        const newUrl = new URL("/login", req.nextUrl.origin);
        return Response.redirect(newUrl);
    }

    // Redirect "/" to home page for logged-in users
    if (token && req.nextUrl.pathname === "/") {
        const newUrl = new URL("/home", req.nextUrl.origin);
        return Response.redirect(newUrl);
    }
};

export const config = {
    matcher: [
        "/((?!api|_next/static|_next/image|favicon.ico).*)",
    ],
};

export default middleware;
