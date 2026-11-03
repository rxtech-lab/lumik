import { createClient, type Client, type InArgs } from '@libsql/client';
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
    CREATE TABLE IF NOT EXISTS account_deletions (owner TEXT PRIMARY KEY, delete_at INTEGER NOT NULL, completed INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, instructions TEXT NOT NULL, naming_template TEXT NOT NULL, schema_json TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS groups_owner ON groups(owner);
    CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, owner TEXT NOT NULL, name TEXT NOT NULL, original_name TEXT NOT NULL, storage_key TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, data_json TEXT, error TEXT, processing_started_at TEXT, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS documents_group ON documents(owner,group_id);
    CREATE TABLE IF NOT EXISTS proposals (id TEXT PRIMARY KEY, owner TEXT NOT NULL, mutation TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS pdf_uploads (id TEXT PRIMARY KEY, owner TEXT NOT NULL, group_id TEXT NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL, staging_key TEXT NOT NULL, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS gc (storage_key TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS group_views (id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE, owner TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, spec_json TEXT NOT NULL, queries_json TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS group_views_group ON group_views(owner,group_id);
    CREATE TABLE IF NOT EXISTS chat_messages (id TEXT PRIMARY KEY, owner TEXT NOT NULL, conversation_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, activity_json TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS chat_messages_owner ON chat_messages(owner,conversation_id,created_at);
  `);
  await addColumn(client, 'groups', 'extract_additional', 'INTEGER NOT NULL DEFAULT 0');
  await addColumn(client, 'documents', 'additional_json', 'TEXT');
  await addColumn(client, 'groups', 'deleted_at', 'TEXT');
  await addColumn(client, 'groups', 'parent_id', 'TEXT');
  await addColumn(client, 'groups', 'kind', "TEXT NOT NULL DEFAULT 'group'");
  await client.execute('CREATE INDEX IF NOT EXISTS groups_parent ON groups(owner,parent_id)');
  await client.execute("CREATE UNIQUE INDEX IF NOT EXISTS groups_inbox ON groups(owner) WHERE kind='inbox'");
  await addColumn(client, 'documents', 'current_version_id', 'TEXT');
  await addColumn(client, 'pdf_uploads', 'target_document_id', 'TEXT');
  await addColumn(client, 'pdf_uploads', 'target_form_id', 'TEXT');
  await client.executeMultiple(`
    CREATE TABLE IF NOT EXISTS document_versions (id TEXT PRIMARY KEY, document_id TEXT NOT NULL, owner TEXT NOT NULL, number INTEGER NOT NULL, name TEXT NOT NULL, storage_key TEXT NOT NULL, size INTEGER NOT NULL, data_json TEXT, additional_json TEXT, created_at TEXT NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS document_versions_number ON document_versions(document_id,number);
    CREATE INDEX IF NOT EXISTS document_versions_owner ON document_versions(owner);
    CREATE TABLE IF NOT EXISTS form_templates (id TEXT PRIMARY KEY, owner TEXT NOT NULL, document_id TEXT NOT NULL, version_id TEXT NOT NULL, title TEXT NOT NULL, source TEXT NOT NULL, sections_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE UNIQUE INDEX IF NOT EXISTS form_templates_version ON form_templates(version_id);
    CREATE INDEX IF NOT EXISTS form_templates_document ON form_templates(document_id);
    CREATE INDEX IF NOT EXISTS form_templates_owner ON form_templates(owner);
    CREATE TABLE IF NOT EXISTS signing_requests (id TEXT PRIMARY KEY, owner TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS signing_requests_owner ON signing_requests(owner,created_at);
    CREATE TABLE IF NOT EXISTS filled_forms (id TEXT PRIMARY KEY, owner TEXT NOT NULL, document_id TEXT NOT NULL, version_id TEXT NOT NULL, template_id TEXT NOT NULL, title TEXT NOT NULL, values_json TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'draft', signing_request_id TEXT, signed_storage_key TEXT, signed_size INTEGER, signature_method TEXT, signed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS filled_forms_document ON filled_forms(document_id,updated_at);
    CREATE INDEX IF NOT EXISTS filled_forms_owner ON filled_forms(owner);
    CREATE INDEX IF NOT EXISTS filled_forms_request ON filled_forms(signing_request_id) WHERE signing_request_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS documents_group_only ON documents(group_id);
    CREATE INDEX IF NOT EXISTS groups_deleted ON groups(deleted_at) WHERE deleted_at IS NOT NULL;
    INSERT OR IGNORE INTO document_versions (id,document_id,owner,number,name,storage_key,size,created_at) SELECT id,id,owner,1,original_name,storage_key,size,created_at FROM documents WHERE current_version_id IS NULL;
    UPDATE documents SET current_version_id=id WHERE current_version_id IS NULL;
  `);
}

/**
 * Queues every file stored under the documents `documents` selects and removes their paperwork.
 * Run it before deleting those documents; the document's own key is always one of its versions.
 */
export function documentChildrenCleanup(documents: string, args: InArgs) {
    return [
        { sql: `INSERT OR IGNORE INTO gc SELECT storage_key FROM document_versions WHERE document_id IN (${documents})`, args },
        { sql: `INSERT OR IGNORE INTO gc SELECT signed_storage_key FROM filled_forms WHERE signed_storage_key IS NOT NULL AND document_id IN (${documents})`, args },
        { sql: `DELETE FROM filled_forms WHERE document_id IN (${documents})`, args },
        { sql: `DELETE FROM form_templates WHERE document_id IN (${documents})`, args },
        { sql: `DELETE FROM document_versions WHERE document_id IN (${documents})`, args },
    ];
}
/** A signing request exists only for the forms in it. */
export const emptySigningRequests = (owner: string) => ({ sql: 'DELETE FROM signing_requests WHERE owner=? AND NOT EXISTS (SELECT 1 FROM filled_forms f WHERE f.signing_request_id=signing_requests.id)', args: [owner] });

export async function expirePDFUploads(client = db()) {
    const cutoff = Date.now() - 60_000;
    await client.batch([
        { sql: 'INSERT OR IGNORE INTO gc SELECT staging_key FROM pdf_uploads WHERE expires_at<?', args: [cutoff] },
        { sql: 'DELETE FROM pdf_uploads WHERE expires_at<?', args: [cutoff] },
    ], 'write');
}
