import { SignOut } from "@/components/sign-out";

export default function HomePage() {
    return (
        <div className="min-h-screen bg-gray-50">
            <header className="bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
                <h1 className="text-xl font-bold text-gray-900">PROJECT_NAME</h1>
                <SignOut />
            </header>
            <main className="max-w-7xl mx-auto px-4 py-6">
                <p className="text-gray-600">Welcome! You are signed in.</p>
            </main>
        </div>
    );
}
