import { resourceMetadata } from "@/lib/mcp/oauth-config";
import { oauthResponse } from "@/lib/mcp/oauth";
export const dynamic = "force-dynamic";
export function GET() { return oauthResponse(async () => Response.json(resourceMetadata(), { headers: { "cache-control": "no-store" } })); }
