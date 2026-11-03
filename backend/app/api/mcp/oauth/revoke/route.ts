import { oauthResponse, revoke } from "@/lib/mcp/oauth";
export const runtime = "nodejs";
export function POST(request: Request) { return oauthResponse(() => revoke(request)); }
