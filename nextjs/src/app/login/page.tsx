import { SignIn } from "@/components/sign-in";

const Login = async ({
    searchParams,
}: {
    searchParams: { [key: string]: string | string[] | undefined };
}) => {
    const error = searchParams["error"];

    return (
        <div className="flex min-h-screen items-center justify-center bg-gray-50">
            <div className="w-96 rounded-lg bg-white p-8 shadow-md flex flex-col items-center gap-4">
                <h1 className="text-2xl font-bold text-gray-900">PROJECT_NAME</h1>
                <p className="text-sm text-gray-600">
                    Sign in to continue.
                </p>
                <SignIn />
                {error ? (
                    <p className="text-xs text-red-600">
                        There was an error signing you in. Please try again.
                    </p>
                ) : null}
            </div>
        </div>
    );
};

export default Login;
