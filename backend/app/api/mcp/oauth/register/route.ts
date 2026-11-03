import { oauthResponse, registerClient } from "@/lib/mcp/oauth";
export const runtime = "nodejs";
export function POST(request: Request) { return oauthResponse(() => registerClient(request)); }
