import { createClient, type Client } from '@libsql/client';
import { mkdirSync } from 'node:fs';
let client: Client | undefined;
export function db() {
    if (!client) {
        const url = process.env.TURSO_DATABASE_URL;
        if (!url)
            throw new Error('TURSO_DATABASE_URL is required');
        if (url.startsWith('file:.data/'))
            mkdirSync('.data', { recursive: true });
        client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
    }
    return client;
}
export async function migrate(client = db()) {
    await client.executeMultiple(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, instructions TEXT NOT NULL, naming_template TEXT NOT NULL, schema_json TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS groups_owner ON groups(owner);
    CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, owner TEXT NOT NULL, name TEXT NOT NULL, original_name TEXT NOT NULL, storage_key TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, data_json TEXT, error TEXT, processing_started_at TEXT, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS documents_group ON documents(owner,group_id);
    CREATE TABLE IF NOT EXISTS proposals (id TEXT PRIMARY KEY, owner TEXT NOT NULL, mutation TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS gc (storage_key TEXT PRIMARY KEY);
  `);
}
