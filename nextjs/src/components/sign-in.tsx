import { signIn } from "@/auth";

export const SignIn = () => {
    return (
        <form
            action={async () => {
                "use server";
                await signIn("cognito", { redirectTo: "/home" });
            }}
        >
            <button
                type="submit"
                className="rounded-md bg-blue-600 px-8 py-2 font-bold text-white hover:bg-blue-700 transition-colors"
            >
                Sign in
            </button>
        </form>
    );
};
