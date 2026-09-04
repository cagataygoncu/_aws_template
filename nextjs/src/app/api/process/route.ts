import { processRequest } from "@/lib/main";

// The route that does the service's work, so there is one place to replace.
// The health check next door stays free of dependencies on purpose.
export async function POST(request: Request) {
    try {
        const eventData = await request.text();
        return Response.json({ output: processRequest(eventData) });
    } catch (error) {
        console.error(error);
        return Response.json({ error: String(error) }, { status: 500 });
    }
}
