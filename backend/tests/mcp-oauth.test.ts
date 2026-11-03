import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as resourceMetadataRoute from "@/app/.well-known/oauth-protected-resource/route";
import * as pathMetadataRoute from "@/app/.well-known/oauth-protected-resource/api/mcp/route";
import * as authorizationMetadataRoute from "@/app/.well-known/oauth-authorization-server/route";
import * as authorizeRoute from "@/app/api/mcp/oauth/authorize/route";
import * as callbackRoute from "@/app/api/mcp/oauth/callback/route";
import * as consentRoute from "@/app/api/mcp/oauth/consent/route";
import * as registerRoute from "@/app/api/mcp/oauth/register/route";
import * as tokenRoute from "@/app/api/mcp/oauth/token/route";
import * as revokeRoute from "@/app/api/mcp/oauth/revoke/route";
import * as mcpRoute from "@/app/api/mcp/route";
import { mcpOAuthClients, mcpOAuthCodes, mcpOAuthGrants, mcpOAuthRequests, mcpOAuthTokens } from "@/lib/mcp/schema";
import { challenge, digest, mcpOrigin, mcpResource, oauthUrl, secret } from "@/lib/mcp/oauth-config";
import { authenticateOAuthToken, cleanupOAuth } from "@/lib/mcp/oauth-tokens";
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beforeAll, afterAll } from 'vitest';
import { db, migrate } from '@/lib/db';
import { getDatabase } from '@/lib/mcp/database';
import { purgeAccounts } from '@/lib/account';
vi.mock('@/lib/mcp/login', () => ({ verifyLogin: async (token: string, issuer: string, client: string) => {
  const value = JSON.parse(token);
  if (value.client_id !== client) throw new Error('Wrong client');
  return { sub: value.sub };
} }));
const ISSUER = 'https://auth.test.example';
const CALLBACK = 'https://agent.example/oauth/callback';
const BROKER_CLIENT = 'lumik-mcp-login';
const dir = mkdtempSync(join(tmpdir(), 'lumik-oauth-'));
const env = { handle: { db: getDatabaseForTest() }, tokens: { alice: JSON.stringify({ sub: 'user-alice', client_id: 'app' }) } };
function getDatabaseForTest() {
  process.env.TURSO_DATABASE_URL = 'file:' + join(dir, 'test.db');
  return getDatabase();
}
beforeAll(async () => { await migrate(); });
afterAll(() => { db().close(); rmSync(dir, { recursive: true, force: true }); });
beforeEach(async () => {
  for (const table of ['mcp_oauth_tokens','mcp_oauth_codes','mcp_oauth_requests','mcp_oauth_grants','mcp_oauth_clients','account_deletions']) await db().execute('DELETE FROM ' + table);
  vi.stubEnv('AUTH_ISSUER', ISSUER);
  vi.stubEnv('MCP_RXAUTH_CLIENT_ID', BROKER_CLIENT);
  vi.stubEnv('MCP_RXAUTH_CLIENT_SECRET', 'test-secret');
  vi.stubEnv('MCP_RESOURCE_URL', 'https://lumik.test.example/api/mcp');
});
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
async function signToken(sub: string, claims: { client_id: string }) { return JSON.stringify({ sub, ...claims }); }
function apiRequest(method: string, path: string, options: { body?: unknown; token?: string; headers?: Record<string,string> } = {}) {
  return new Request('https://lumik.test.example' + path, { method, headers: { 'content-type': 'application/json', ...options.headers, ...(options.token ? { authorization: 'Bearer ' + options.token } : {}) }, body: options.body ? JSON.stringify(options.body) : undefined });
}

function formRequest(endpoint: string, params: Record<string, string>, cookie?: string) {
  return new Request(oauthUrl(endpoint), { method: "POST", headers: {
    "content-type": "application/x-www-form-urlencoded", origin: mcpOrigin(), ...(cookie ? { cookie } : {}),
  }, body: new URLSearchParams(params) });
}

function cookieFrom(response: Response) { return response.headers.get("set-cookie")!.split(";", 1)[0]; }

async function register(name = "Test agent", redirects = [CALLBACK]) {
  const response = await registerRoute.POST(apiRequest("POST", "/api/mcp/oauth/register", {
    body: { client_name: name, redirect_uris: redirects, token_endpoint_auth_method: "none" },
  }));
  expect(response.status).toBe(201);
  return (await response.json()).client_id as string;
}

async function start(clientId: string, scope = "lumik:read lumik:write", overrides: Record<string, string> = {}) {
  const verifier = secret();
  const url = new URL(oauthUrl("authorize"));
  url.search = new URLSearchParams({ client_id: clientId, redirect_uri: CALLBACK, response_type: "code", scope,
    resource: mcpResource(), code_challenge_method: "S256", code_challenge: challenge(verifier), state: "agent-state", ...overrides }).toString();
  return { response: await authorizeRoute.GET(new Request(url)), verifier };
}

async function login(clientId: string, scope = "lumik:read lumik:write", owner = "user-alice", redirectUri = CALLBACK) {
  const begun = await start(clientId, scope, { redirect_uri: redirectUri });
  expect(begun.response.status).toBe(302);
  const upstream = new URL(begun.response.headers.get("location")!);
  const upstreamToken = await signToken(owner, { client_id: BROKER_CLIENT });
  const fetchMock = vi.fn(async () => Response.json({ access_token: upstreamToken }));
  vi.stubGlobal("fetch", fetchMock);
  const url = new URL(oauthUrl("callback"));
  url.search = new URLSearchParams({ state: upstream.searchParams.get("state")!, code: "upstream-code" }).toString();
  const response = await callbackRoute.GET(new Request(url, { headers: { cookie: cookieFrom(begun.response) } }));
  vi.unstubAllGlobals();
  expect(response.status).toBe(302);
  const consentUrl = response.headers.get("location")!;
  const cookie = cookieFrom(response);
  expect(cookie).toBe(cookieFrom(begun.response));
  const requestId = new URL(consentUrl).searchParams.get("request")!;
  return { verifier: begun.verifier, cookie, requestId, consentUrl, upstream, fetchMock, upstreamToken };
}

async function authorizeCode(clientId: string, scope?: string, owner?: string) {
  const signedIn = await login(clientId, scope, owner);
  const response = await consentRoute.POST(formRequest("consent", {
    request: signedIn.requestId, csrf: signedIn.cookie.split("=", 2)[1], decision: "allow",
  }, signedIn.cookie));
  expect(response.status).toBe(302);
  const redirect = new URL(response.headers.get("location")!);
  expect(redirect.searchParams.get("state")).toBe("agent-state");
  expect(redirect.searchParams.get("iss")).toBe(mcpOrigin());
  return { ...signedIn, code: redirect.searchParams.get("code")! };
}

async function tokens(clientId: string, scope?: string, owner?: string) {
  const approved = await authorizeCode(clientId, scope, owner);
  const response = await tokenRoute.POST(formRequest("token", { grant_type: "authorization_code", client_id: clientId,
    code: approved.code, redirect_uri: CALLBACK, code_verifier: approved.verifier, resource: mcpResource() }));
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toContain("no-store");
  return { ...(await response.json()), ...approved } as typeof approved & { access_token: string; refresh_token: string; scope: string };
}

async function rpc(token: string | undefined, method: string, params?: unknown) {
  return mcpRoute.POST(apiRequest("POST", "/api/mcp", { token, headers: { accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: 1, method, ...(params ? { params } : {}) } }));
}

describe("MCP OAuth discovery and registration", () => {
  it("discovers resource, issuer, PKCE, public DCR, refresh and revocation without credentials", async () => {
    const resource = await (await resourceMetadataRoute.GET()).json();
    expect(resource).toMatchObject({ resource: mcpResource(), authorization_servers: [mcpOrigin()], scopes_supported: ["lumik:read", "lumik:write"] });
    expect(await (await pathMetadataRoute.GET()).json()).toEqual(resource);
    expect(await (await authorizationMetadataRoute.GET()).json()).toMatchObject({ issuer: mcpOrigin(), registration_endpoint: oauthUrl("register"),
      token_endpoint_auth_methods_supported: ["none"], code_challenge_methods_supported: ["S256"], authorization_response_iss_parameter_supported: true });
    const missing = await rpc(undefined, "initialize");
    expect(missing.status).toBe(401);
    expect(missing.headers.get("www-authenticate")).toContain(`resource_metadata="${mcpOrigin()}/.well-known/oauth-protected-resource"`);
  });

  it("accepts HTTPS and loopback callbacks, rejects unsafe callbacks and unsupported clients", async () => {
    await register("Loopback", ["http://127.0.0.1:12345/callback", "http://[::1]:6789/callback"]);
    for (const uri of ["http://attacker.example/callback", "javascript:alert(1)", "data:text/html,test", "file:///tmp/callback", "blob:https://agent.example/id", "rxcode://mcp/callback#fragment", "https://agent.example/#fragment", "https://user:password@agent.example/callback", "https://agent.example;unsafe/callback"]) {
      const response = await registerRoute.POST(apiRequest("POST", "/register", { body: { redirect_uris: [uri] } }));
      expect(response.status).toBe(400);
      expect((await response.json()).error).toBe("invalid_client_metadata");
    }
    expect((await registerRoute.POST(apiRequest("POST", "/register", { body: { redirect_uris: [CALLBACK], token_endpoint_auth_method: "client_secret_post" } }))).status).toBe(400);
  });

  it("bounds anonymous registration writes across instances", async () => {
    await env.handle.db.insert(mcpOAuthClients).values(Array.from({ length: 60 }, (_, i) => ({ id: `client-${i}`, name: "Agent", redirectUris: [CALLBACK] })));
    const response = await registerRoute.POST(apiRequest("POST", "/register", { body: { redirect_uris: [CALLBACK] } }));
    expect(response.status).toBe(429);
  });

  it("does not trust Host headers for discovery or audience", async () => {
    const response = await rpc(undefined, "initialize");
    expect(response.headers.get("www-authenticate")).not.toContain("localhost");
    vi.stubEnv("MCP_RESOURCE_URL", "https://attacker.example/api/mcp?token=secret");
    expect(() => mcpResource()).toThrow("MCP_RESOURCE_URL");
  });
});

describe("RxLab login, consent and PKCE code exchange", () => {
  it("delegates login with separate state/PKCE and requires explicit consent", async () => {
    const clientId = await register('<img src=x onerror="alert(1)">');
    const signedIn = await login(clientId);
    expect(signedIn.upstream.origin).toBe(ISSUER);
    expect(signedIn.upstream.searchParams.get("client_id")).toBe(BROKER_CLIENT);
    expect(signedIn.upstream.searchParams.get("redirect_uri")).toBe(oauthUrl("callback"));
    expect(signedIn.upstream.searchParams.get("state")).not.toBe("agent-state");
    const body = signedIn.fetchMock.mock.calls[0];
    expect(body).toBeDefined();
    const page = await consentRoute.GET(new Request(signedIn.consentUrl, { headers: { cookie: signedIn.cookie } }));
    expect(page.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(page.headers.get("referrer-policy")).toBe("same-origin");
    expect(page.headers.get("content-security-policy")).not.toContain("form-action");
    const html = await page.text();
    expect(html).toContain("&lt;img");
    expect(html).not.toContain("<img");
    expect(html).toContain("Read your PDFs");
    expect(html).toContain("Upload PDFs");
    expect(await env.handle.db.select().from(mcpOAuthGrants)).toHaveLength(0);
    expect(await env.handle.db.select().from(mcpOAuthCodes)).toHaveLength(0);
    expect(JSON.stringify(await env.handle.db.select().from(mcpOAuthRequests))).not.toContain(signedIn.upstreamToken);
    expect((await consentRoute.GET(new Request(signedIn.consentUrl))).status).toBe(400);
  });

  it("connects RxCode through its exact native callback and exchanges the code", async () => {
    const redirectUri = "rxcode://mcp/oauth/callback";
    const clientId = await register("RxCode", [redirectUri]);
    const signedIn = await login(clientId, undefined, undefined, redirectUri);
    const page = await consentRoute.GET(new Request(signedIn.consentUrl, { headers: { cookie: signedIn.cookie } }));
    expect(page.status).toBe(200);
    expect(page.headers.get("content-security-policy")).not.toContain("form-action");
    const approved = await consentRoute.POST(formRequest("consent", {
      request: signedIn.requestId, csrf: signedIn.cookie.split("=", 2)[1], decision: "allow",
    }, signedIn.cookie));
    const callback = new URL(approved.headers.get("location")!);
    expect(callback.protocol).toBe("rxcode:");
    expect(callback.host).toBe("mcp");
    expect(callback.pathname).toBe("/oauth/callback");
    const issued = await tokenRoute.POST(formRequest("token", {
      grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri,
      resource: mcpResource(), code: callback.searchParams.get("code")!, code_verifier: signedIn.verifier,
    }));
    expect(issued.status).toBe(200);
    expect((await rpc((await issued.json()).access_token, "tools/list")).status).toBe(200);
    expect((await start(clientId, undefined, { redirect_uri: "rxcode://other/callback" })).response.status).toBe(400);
  });

  it("gives consent a full window after a slow login while keeping browser binding", async () => {
    const clientId = await register();
    const begun = await start(clientId);
    const cookie = cookieFrom(begun.response);
    const upstream = new URL(begun.response.headers.get("location")!);
    const oldDeadline = new Date(Date.now() + 2_000);
    await env.handle.db.update(mcpOAuthRequests).set({ expiresAt: oldDeadline });
    const upstreamToken = await signToken("user-alice", { client_id: BROKER_CLIENT });
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ access_token: upstreamToken })));
    const response = await callbackRoute.GET(new Request(`${oauthUrl("callback")}?state=${upstream.searchParams.get("state")}&code=code`, { headers: { cookie } }));
    expect(response.status).toBe(302);
    const consentUrl = response.headers.get("location")!;
    const [flow] = await env.handle.db.select().from(mcpOAuthRequests);
    expect(flow.expiresAt.getTime()).toBeGreaterThan(oldDeadline.getTime() + 590_000);
    // The original browser cookie still works even if the redirect's renewal is lost.
    expect((await consentRoute.GET(new Request(consentUrl, { headers: { cookie } }))).status).toBe(200);
    expect((await consentRoute.GET(new Request(consentUrl, { headers: { cookie: cookie + "forged" } }))).status).toBe(400);
    await env.handle.db.update(mcpOAuthRequests).set({ expiresAt: new Date(Date.now() - 1_000) });
    expect((await consentRoute.GET(new Request(consentUrl, { headers: { cookie } }))).status).toBe(400);
  });

  it("rejects unregistered redirect URIs before redirecting, and returns iss on valid-client errors", async () => {
    const clientId = await register();
    const invalid = (await start(clientId, undefined, { redirect_uri: "https://attacker.example/steal" })).response;
    expect(invalid.status).toBe(400);
    expect(invalid.headers.has("location")).toBe(false);
    for (const overrides of [{ code_challenge_method: "plain" }, { resource: "https://other.example/mcp" }, { scope: "admin" }] as Record<string, string>[]) {
      const response = (await start(clientId, undefined, overrides)).response;
      const target = new URL(response.headers.get("location")!);
      expect(target.origin).toBe("https://agent.example");
      expect(target.searchParams.has("error")).toBe(true);
      expect(target.searchParams.get("iss")).toBe(mcpOrigin());
    }
  });

  it("rejects login CSRF, forged upstream tokens and callback replay", async () => {
    const clientId = await register();
    const begun = await start(clientId);
    const upstream = new URL(begun.response.headers.get("location")!);
    const callback = `${oauthUrl("callback")}?state=${upstream.searchParams.get("state")}&code=code`;
    expect((await callbackRoute.GET(new Request(callback))).status).toBe(400);
    // A valid app token from a different OAuth client cannot prove broker login.
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ access_token: env.tokens.alice })));
    const rejected = await callbackRoute.GET(new Request(callback, { headers: { cookie: cookieFrom(begun.response) } }));
    expect((await rejected.json()).error).toBe("invalid_grant");
    expect((await callbackRoute.GET(new Request(callback, { headers: { cookie: cookieFrom(begun.response) } }))).status).toBe(400);
    expect(await env.handle.db.select().from(mcpOAuthGrants)).toHaveLength(0);
  });

  it("requires same-origin consent, allows cancellation, and prevents consent replay", async () => {
    const clientId = await register();
    const signedIn = await login(clientId);
    const fields = { request: signedIn.requestId, csrf: signedIn.cookie.split("=", 2)[1], decision: "deny" };
    const forged = formRequest("consent", fields, signedIn.cookie);
    forged.headers.set("origin", "https://attacker.example");
    expect((await consentRoute.POST(forged)).status).toBe(403);
    const opaqueOrigin = formRequest("consent", fields, signedIn.cookie);
    opaqueOrigin.headers.set("origin", "null");
    expect((await consentRoute.POST(opaqueOrigin)).status).toBe(403);
    const denied = await consentRoute.POST(formRequest("consent", fields, signedIn.cookie));
    const target = new URL(denied.headers.get("location")!);
    expect(target.searchParams.get("error")).toBe("access_denied");
    expect(target.searchParams.get("iss")).toBe(mcpOrigin());
    expect(await env.handle.db.select().from(mcpOAuthGrants)).toHaveLength(0);
    expect((await consentRoute.POST(formRequest("consent", fields, signedIn.cookie))).status).toBe(400);
  });

  it("binds code exchange to client, exact callback, resource, S256 verifier and single use", async () => {
    const clientId = await register();
    const otherClient = await register("Other agent");
    const approved = await authorizeCode(clientId);
    const fields = { grant_type: "authorization_code", client_id: clientId, code: approved.code, redirect_uri: CALLBACK,
      code_verifier: approved.verifier, resource: mcpResource() };
    for (const overrides of [{ client_id: otherClient }, { redirect_uri: CALLBACK + "?other=1" }, { resource: "https://other.example/mcp" }, { code_verifier: secret() }]) {
      expect((await tokenRoute.POST(formRequest("token", { ...fields, ...overrides }))).status).toBe(400);
    }
    const response = await tokenRoute.POST(formRequest("token", fields));
    expect(response.status).toBe(200);
    const result = await response.json();
    expect(result.access_token).toMatch(/^lumik_oauth_/);
    expect(result.refresh_token).toMatch(/^lumik_refresh_/);
    expect((await tokenRoute.POST(formRequest("token", fields))).status).toBe(400);
    const stored = JSON.stringify(await env.handle.db.select().from(mcpOAuthTokens));
    expect(stored).not.toContain(result.access_token);
    expect(stored).not.toContain(result.refresh_token);
    expect(stored).toContain(digest(result.access_token));
  });
});

describe("OAuth MCP permissions and token lifecycle", () => {
  it("declares scopes and blocks writes without consent", async () => {
    const issued = await tokens(await register(), 'lumik:read');
    const list = await (await rpc(issued.access_token, 'tools/list')).json();
    expect(list.result.tools.find((t: {name:string}) => t.name === 'analyze_document')._meta.securitySchemes).toEqual([{ type: 'oauth2', scopes: ['lumik:write'] }]);
    const result = await (await rpc(issued.access_token, 'tools/call', { name: 'analyze_document', arguments: { documentId: 'missing' } })).json();
    expect(result.result.isError).toBe(true);
    expect(result.result._meta['mcp/www_authenticate'][0]).toContain('insufficient_scope');
  });

  it("rotates refresh tokens and revokes the family when a consumed refresh token is replayed", async () => {
    const clientId = await register();
    const issued = await tokens(clientId);
    const fields = { grant_type: "refresh_token", client_id: clientId, refresh_token: issued.refresh_token, resource: mcpResource() };
    const refresh = await tokenRoute.POST(formRequest("token", fields));
    expect(refresh.status).toBe(200);
    const rotated = await refresh.json();
    expect(rotated.refresh_token).not.toBe(issued.refresh_token);
    expect(await authenticateOAuthToken(env.handle.db, rotated.access_token)).not.toBeNull();
    expect((await tokenRoute.POST(formRequest("token", fields))).status).toBe(400);
    const denied = await rpc(rotated.access_token, "tools/list");
    expect(denied.status).toBe(401);
    expect(denied.headers.get("www-authenticate")).toContain('error="invalid_token"');
  });

  it("prevents refresh resource/client/scope substitution and prevents refresh tokens authorizing MCP", async () => {
    const clientId = await register();
    const issued = await tokens(clientId, "lumik:read");
    const otherClient = await register("Other");
    const fields = { grant_type: "refresh_token", client_id: clientId, refresh_token: issued.refresh_token, resource: mcpResource() };
    for (const extra of [{ client_id: otherClient }, { scope: "lumik:read lumik:write" }, { resource: "https://other.example/mcp" }] as Record<string, string>[]) {
      expect((await tokenRoute.POST(formRequest("token", { ...fields, ...extra }))).status).toBe(400);
    }
    expect((await rpc(issued.refresh_token, "tools/list")).status).toBe(401);
    expect(await authenticateOAuthToken(env.handle.db, issued.access_token)).not.toBeNull();
    vi.stubEnv("MCP_RESOURCE_URL", "https://different.example/api/mcp");
    expect(await authenticateOAuthToken(env.handle.db, issued.access_token)).toBeNull();
  });

  it("narrows scopes on both new and previously issued access tokens", async () => {
    const clientId = await register();
    const issued = await tokens(clientId);
    const response = await tokenRoute.POST(formRequest("token", { grant_type: "refresh_token", client_id: clientId,
      refresh_token: issued.refresh_token, resource: mcpResource(), scope: "lumik:write" }));
    expect(response.status).toBe(200);
    const narrowed = await response.json();
    expect(narrowed.scope).toBe("lumik:write");
    expect((await authenticateOAuthToken(env.handle.db, narrowed.access_token))?.scopes).toEqual(["lumik:write"]);
    expect((await authenticateOAuthToken(env.handle.db, issued.access_token))?.scopes).toEqual(["lumik:write"]);
  });

  it("supports revocation, expiry and account-deletion cascade", async () => {
    const clientId = await register();
    const issued = await tokens(clientId);
    expect(await authenticateOAuthToken(env.handle.db, issued.access_token, new Date(Date.now() + 3601_000))).toBeNull();
    // Unknown tokens and other clients' tokens produce a non-disclosing success.
    const otherClient = await register("Other");
    expect((await revokeRoute.POST(formRequest("revoke", { client_id: otherClient, token: issued.access_token }))).status).toBe(200);
    expect(await authenticateOAuthToken(env.handle.db, issued.access_token)).not.toBeNull();
    expect((await revokeRoute.POST(formRequest("revoke", { client_id: clientId, token: issued.refresh_token }))).status).toBe(200);
    expect(await authenticateOAuthToken(env.handle.db, issued.access_token)).toBeNull();
    const newGrant = await tokens(clientId);
    await db().execute("INSERT INTO account_deletions VALUES('user-alice',0,0)");
    await expect(authenticateOAuthToken(env.handle.db, newGrant.access_token)).rejects.toMatchObject({ status: 403 });
    expect((await tokenRoute.POST(formRequest("token", { grant_type: "refresh_token", client_id: clientId, refresh_token: newGrant.refresh_token, resource: mcpResource() }))).status).toBe(403);
    await purgeAccounts();
    expect(await authenticateOAuthToken(env.handle.db, newGrant.access_token)).toBeNull();
    expect(await env.handle.db.select().from(mcpOAuthGrants)).toHaveLength(0);
    expect(await env.handle.db.select().from(mcpOAuthTokens)).toHaveLength(0);
  });

  it("cleans expired OAuth state and credentials while preserving registered clients", async () => {
    const clientId = await register();
    await tokens(clientId);
    await start(clientId);
    await cleanupOAuth(env.handle.db, new Date(Date.now() + 31 * 24 * 3600_000));
    expect(await env.handle.db.select().from(mcpOAuthRequests)).toHaveLength(0);
    expect(await env.handle.db.select().from(mcpOAuthGrants)).toHaveLength(0);
    expect(await env.handle.db.select().from(mcpOAuthTokens)).toHaveLength(0);
    expect(await env.handle.db.select().from(mcpOAuthClients)).toHaveLength(1);
  });
});
