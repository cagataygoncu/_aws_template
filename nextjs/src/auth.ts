import NextAuth from "next-auth";
import Cognito from "next-auth/providers/cognito";
import {
    CognitoIdentityProviderClient,
    AdminGetUserCommand,
} from "@aws-sdk/client-cognito-identity-provider";

const client = new CognitoIdentityProviderClient({
    region: process.env.AWS_REGION,
});

export const { handlers, auth, signIn, signOut } = NextAuth({
    secret: process.env.AUTH_SECRET,
    trustHost: true,
    session: {
        strategy: "jwt",
        maxAge: 24 * 60 * 60,
        updateAge: 60 * 60,
    },
    providers: [Cognito],
    callbacks: {
        async jwt({ token, user, account, profile }) {
            if (account && user) {
                const activeProfile: Record<string, string> = {};

                if (profile) {
                    Object.entries(profile).forEach(([key, value]) => {
                        if (typeof value === "string") activeProfile[key] = value;
                    });
                }

                // Fetch full user attributes from Cognito
                try {
                    const userResponse = await client.send(
                        new AdminGetUserCommand({
                            UserPoolId: process.env.AUTH_COGNITO_USER_POOL_ID!,
                            Username: activeProfile["cognito:username"] || user.id || "",
                        })
                    );

                    userResponse.UserAttributes?.forEach(({ Name, Value }) => {
                        if (Name && Value) activeProfile[Name] = Value;
                    });
                } catch (err) {
                    console.error("Failed to fetch user attributes", err);
                }

                return {
                    ...token,
                    idToken: account.id_token,
                    expiresAt: account.expires_at,
                    username: activeProfile["cognito:username"] || user.id,
                    name: activeProfile.name || "",
                };
            }

            return token;
        },
        async session({ session, token }) {
            return {
                ...session,
                idToken: token.idToken ?? "",
                user: {
                    ...session.user,
                    username: token.username ?? "",
                    name: token.name ?? "",
                    email: null,
                    image: undefined,
                },
            };
        },
    },
    pages: {
        signIn: "/login",
        error: "/login",
    },
});
