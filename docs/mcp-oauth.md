# Remote MCP OAuth

Add `https://www.lumik.dev/api/mcp` as a Streamable HTTP server and choose OAuth / Dynamic Client Registration.
Lumik brokers RxLab login, asks for explicit consent, and issues its own MCP credentials.
Ordinary app bearer tokens no longer authorize MCP; app API authentication remains unchanged.

## Deployment

1. Register a dedicated confidential RxAuth client with authorization code, S256 PKCE and
   `openid read:profile read:email` as the allowed scopes in RxAuth (its canonical names).
   Lumik requests the standard `openid profile email` aliases, which RxAuth normalizes. Register exactly `https://www.lumik.dev/api/mcp/oauth/callback`.
2. Set server-only `MCP_RXAUTH_CLIENT_ID`, `MCP_RXAUTH_CLIENT_SECRET`,
   `MCP_RESOURCE_URL=https://www.lumik.dev/api/mcp`, and `AUTH_ISSUER`.
   Do not add the broker client to the app's `RXLAB_ALLOWED_CLIENT_IDS`.
3. Run `bun run db:migrate` in `backend` before deployment.
4. The existing authenticated `/api/cron/accounts` job also retires expired OAuth state;
   `bun run storage:cleanup` does the same for manual maintenance.

Locally, use `MCP_RESOURCE_URL=http://localhost:3000/api/mcp` and register the matching
`http://localhost:3000/api/mcp/oauth/callback` in a development RxAuth client.
The client must reach that localhost server. App Debug/Release configuration is unchanged.

## Endpoints and permissions

Discovery is available at `/.well-known/oauth-protected-resource`,
`/.well-known/oauth-protected-resource/api/mcp`, and `/.well-known/oauth-authorization-server`.
Unauthorized MCP requests return a `WWW-Authenticate` challenge pointing to discovery.

Under `/api/mcp/oauth`, `register` accepts JSON public client metadata; `authorize` accepts
code requests bound to client, callback, resource and S256 challenge; `callback` verifies RxLab
login. `consent` provides a dedicated approval page with browser cookie, Origin and CSRF checks.
`token` accepts URL-encoded authorization-code or refresh requests with `client_id` and `resource`.
`revoke` accepts URL-encoded `client_id` and `token` and revokes the whole grant.

`lumik:read` permits reading/listing PDFs, documents, groups, summaries, statistics, views,
and sandboxed JS/SQL inspection. `lumik:write` permits uploads, analysis and change proposals.
Existing app approval requirements remain enforced. Default scope is read-only; write tools
return a scope challenge when additional consent is needed. Uploads still use presigned storage URLs.

Credentials are hashed at rest. Codes expire after one minute, access tokens after one hour,
and grants after thirty days. Refresh rotates credentials and can narrow scopes. Replay revokes
the grant. Account deletion blocks access and cleanup removes credentials. Registration is limited
to 60 clients per minute across instances. Native client-management UI is not yet implemented;
clients can disconnect through the revocation endpoint.

Adapted from Summary Chip, following the [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).

## Verification

Run `bun run test -- tests/mcp-oauth.test.ts tests/auth-http.test.ts tests/account.test.ts`.
Tests use temporary SQLite storage and stub upstream login verification/token responses.
JWT signature verification is tested separately in the auth tests. This does not establish
live RxAuth login or deployed client interoperability. Do not run UI tests.
