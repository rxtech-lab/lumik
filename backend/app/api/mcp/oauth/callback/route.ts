import { oauthResponse, callback } from "@/lib/mcp/oauth";
export const runtime = "nodejs";
export function GET(request: Request) { return oauthResponse(() => callback(request)); }
