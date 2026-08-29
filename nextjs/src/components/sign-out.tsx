import { signOut } from "@/auth";

export const SignOut = () => {
    return (
        <form
            action={async () => {
                "use server";
                await signOut({ redirectTo: "/login" });
            }}
        >
            <button
                type="submit"
                className="rounded-md border border-gray-300 px-4 py-1.5 text-sm text-gray-700 hover:bg-gray-100 transition-colors"
            >
                Sign out
            </button>
        </form>
    );
};
