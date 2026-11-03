export const oauthMigration = `
CREATE TABLE IF NOT EXISTS mcp_oauth_clients (
	id text PRIMARY KEY NOT NULL,
	name text NOT NULL,
	redirect_uris text NOT NULL,
	created_at integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_clients_created_idx ON mcp_oauth_clients (created_at);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS mcp_oauth_codes (
	hash text PRIMARY KEY NOT NULL,
	grant_id text NOT NULL,
	redirect_uri text NOT NULL,
	challenge text NOT NULL,
	used_at integer,
	expires_at integer NOT NULL,
	FOREIGN KEY (grant_id) REFERENCES mcp_oauth_grants(id) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_codes_expiry_idx ON mcp_oauth_codes (expires_at);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS mcp_oauth_grants (
	id text PRIMARY KEY NOT NULL,
	owner_id text NOT NULL,
	client_id text NOT NULL,
	resource text NOT NULL,
	scope text NOT NULL,
	revoked_at integer,
	expires_at integer NOT NULL,
	FOREIGN KEY (client_id) REFERENCES mcp_oauth_clients(id) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_grants_owner_idx ON mcp_oauth_grants (owner_id);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_grants_expiry_idx ON mcp_oauth_grants (expires_at);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS mcp_oauth_requests (
	id text PRIMARY KEY NOT NULL,
	state_hash text NOT NULL,
	client_id text NOT NULL,
	redirect_uri text NOT NULL,
	client_state text,
	challenge text NOT NULL,
	scope text NOT NULL,
	upstream_verifier text NOT NULL,
	login_claimed_at integer,
	owner_id text,
	consent_hash text,
	expires_at integer NOT NULL,
	FOREIGN KEY (client_id) REFERENCES mcp_oauth_clients(id) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS mcp_oauth_requests_state_hash_unique ON mcp_oauth_requests (state_hash);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_requests_expiry_idx ON mcp_oauth_requests (expires_at);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS mcp_oauth_tokens (
	hash text PRIMARY KEY NOT NULL,
	grant_id text NOT NULL,
	kind text NOT NULL,
	used_at integer,
	expires_at integer NOT NULL,
	FOREIGN KEY (grant_id) REFERENCES mcp_oauth_grants(id) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_tokens_grant_idx ON mcp_oauth_tokens (grant_id);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS mcp_oauth_tokens_expiry_idx ON mcp_oauth_tokens (expires_at);
`;
