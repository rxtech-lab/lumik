import { oauthResponse, authorize } from "@/lib/mcp/oauth";
export const runtime = "nodejs";
export function GET(request: Request) { return oauthResponse(() => authorize(request)); }
