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
async function addColumn(client: Client, table: string, column: string, definition: string) {
    const columns = await client.execute(`PRAGMA table_info(${table})`);
    if (!columns.rows.some(row => row.name === column))
        await client.execute(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
export async function migrate(client = db()) {
    await client.executeMultiple(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, instructions TEXT NOT NULL, naming_template TEXT NOT NULL, schema_json TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS groups_owner ON groups(owner);
    CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, owner TEXT NOT NULL, name TEXT NOT NULL, original_name TEXT NOT NULL, storage_key TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, data_json TEXT, error TEXT, processing_started_at TEXT, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS documents_group ON documents(owner,group_id);
    CREATE TABLE IF NOT EXISTS proposals (id TEXT PRIMARY KEY, owner TEXT NOT NULL, mutation TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS pdf_uploads (id TEXT PRIMARY KEY, owner TEXT NOT NULL, group_id TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, staging_key TEXT NOT NULL, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS gc (storage_key TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS group_views (id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, owner TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, spec_json TEXT NOT NULL, queries_json TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS group_views_group ON group_views(owner,group_id);
  `);
  await addColumn(client, 'groups', 'extract_additional', 'INTEGER NOT NULL DEFAULT 0');
  await addColumn(client, 'documents', 'additional_json', 'TEXT');
  await addColumn(client, 'groups', 'deleted_at', 'TEXT');
}

export async function expirePDFUploads(client = db()) {
    const cutoff = Date.now() - 60_000;
    await client.batch([
        { sql: 'INSERT OR IGNORE INTO gc SELECT staging_key FROM pdf_uploads WHERE expires_at<?', args: [cutoff] },
        { sql: 'DELETE FROM pdf_uploads WHERE expires_at<?', args: [cutoff] },
    ], 'write');
}
