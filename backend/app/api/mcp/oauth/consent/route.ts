import { oauthResponse, consentPage, approveConsent } from "@/lib/mcp/oauth";
export const runtime = "nodejs";
export function GET(request: Request) { return oauthResponse(() => consentPage(request)); }
export function POST(request: Request) { return oauthResponse(() => approveConsent(request)); }
