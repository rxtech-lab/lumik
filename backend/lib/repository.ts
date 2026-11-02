import { randomUUID } from 'node:crypto';
import type { Client, Row } from '@libsql/client';
import { db } from './db';
import { ApiError, groupInput, mutationInput, safeName, validateData, viewInput, type Additional, type DeletedGroup, type Document, type Group, type GroupView } from './contracts';
import { runSQL, type SandboxData, type SQLParam, type SQLResult } from './sql-sandbox';
import { validateUISpec } from './ui-catalog';
function group(row: Row): Group { return { id: String(row.id), name: String(row.name), instructions: String(row.instructions), namingTemplate: String(row.naming_template), extractAdditional: Boolean(row.extract_additional), schema: JSON.parse(String(row.schema_json)), createdAt: String(row.created_at), documentCount: Number(row.document_count ?? 0) }; }
function document(row: Row): Document { return { id: String(row.id), groupId: String(row.group_id), name: String(row.name), originalName: String(row.original_name), storageKey: String(row.storage_key), size: Number(row.size), status: String(row.status), data: row.data_json ? JSON.parse(String(row.data_json)) : null, additional: row.additional_json ? JSON.parse(String(row.additional_json)) : null, error: row.error ? String(row.error) : null, createdAt: String(row.created_at) }; }
function view(row: Row): GroupView { return { id: String(row.id), groupId: String(row.group_id), kind: String(row.kind) as GroupView['kind'], title: String(row.title), spec: JSON.parse(String(row.spec_json)), queries: JSON.parse(String(row.queries_json)), createdAt: String(row.created_at) }; }
/** How long a deleted group waits in the Recycle Bin before it is permanently deleted. */
export const recycleBinDays = 30;
const recycleBinMs = recycleBinDays * 24 * 60 * 60 * 1000;
const purgeCutoff = () => new Date(Date.now() - recycleBinMs).toISOString();
function deletedGroup(row: Row): DeletedGroup { const deletedAt = String(row.deleted_at); return { ...group(row), deletedAt, purgeAt: new Date(new Date(deletedAt).getTime() + recycleBinMs).toISOString() }; }
/** Permanently deletes every owner's expired groups and queues their PDFs for cleanup. */
export async function purgeExpiredGroups(client: Client = db()) {
    const expired = 'SELECT id FROM groups WHERE deleted_at IS NOT NULL AND deleted_at<=?';
    const args = [purgeCutoff()];
    await client.batch([
        { sql: `INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE group_id IN (${expired})`, args },
        { sql: `DELETE FROM documents WHERE group_id IN (${expired})`, args },
        { sql: `DELETE FROM group_views WHERE group_id IN (${expired})`, args },
        { sql: 'DELETE FROM groups WHERE deleted_at IS NOT NULL AND deleted_at<=?', args },
    ], 'write');
}
export class Repository {
    constructor(readonly owner: string, private client: Client = db()) { }
    async groups() { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE owner=? AND deleted_at IS NULL ORDER BY created_at DESC', args: [this.owner] }); return r.rows.map(group); }
    async group(id: string) { const g = (await this.groups()).find(x => x.id === id); if (!g)
        throw new ApiError(404, 'Group not found'); return g; }
    async createGroup(input: unknown) { const g = groupInput.parse(input); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO groups (id,owner,name,instructions,naming_template,schema_json,created_at,extract_additional) VALUES(?,?,?,?,?,?,?,?)', args: [id, this.owner, g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), new Date().toISOString(), g.extractAdditional ? 1 : 0] }); return this.group(id); }
    async updateGroup(id: string, input: unknown) { const g = groupInput.parse(input); await this.group(id); await this.client.execute({ sql: 'UPDATE groups SET name=?,instructions=?,naming_template=?,schema_json=?,extract_additional=? WHERE id=? AND owner=?', args: [g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), g.extractAdditional ? 1 : 0, id, this.owner] }); return this.group(id); }
    async documents(groupId: string) { await this.group(groupId); const r = await this.client.execute({ sql: 'SELECT * FROM documents WHERE group_id=? AND owner=? ORDER BY created_at DESC', args: [groupId, this.owner] }); return r.rows.map(document); }
    async document(id: string) { const r = await this.client.execute({ sql: 'SELECT d.* FROM documents d JOIN groups g ON g.id=d.group_id WHERE d.id=? AND d.owner=? AND g.deleted_at IS NULL', args: [id, this.owner] }); if (!r.rows[0])
        throw new ApiError(404, 'Document not found'); return document(r.rows[0]); }
    async addDocument(groupId: string, id: string, name: string, size: number) { await this.group(groupId); await this.client.execute({ sql: 'INSERT INTO documents (id,group_id,owner,name,original_name,storage_key,size,status,created_at) VALUES(?,?,?,?,?,?,?,?,?)', args: [id, groupId, this.owner, safeName(name), safeName(name), `${id}.pdf`, size, 'uploaded', new Date().toISOString()] }); return this.document(id); }
    async claimDocument(id: string) {
        await this.document(id);
        const r = await this.client.execute({ sql: "UPDATE documents SET status='processing',error=NULL,processing_started_at=? WHERE id=? AND owner=? AND (status!='processing' OR processing_started_at<?)", args: [new Date().toISOString(), id, this.owner, new Date(Date.now() - 180000).toISOString()] });
        if (!r.rowsAffected)
            throw new ApiError(409, 'Document is already being processed');
    }
    async complete(id: string, name: string, data: unknown, additional?: Additional | null) { await this.client.execute({ sql: "UPDATE documents SET name=?,data_json=?,additional_json=COALESCE(?,additional_json),status='ready',error=NULL WHERE id=? AND owner=?", args: [safeName(name), JSON.stringify(data), additional ? JSON.stringify(additional) : null, id, this.owner] }); return this.document(id); }
    async fail(id: string) { await this.client.execute({ sql: "UPDATE documents SET status='failed',error='Processing failed. Please retry.' WHERE id=? AND owner=?", args: [id, this.owner] }); }
    async editDocument(id: string, name: string, data: unknown) { const d = await this.document(id); if (d.status === 'processing')
        throw new ApiError(409, 'Wait for processing to finish'); const g = await this.group(d.groupId); validateData(g.schema, data); return this.complete(id, safeName(name.replace(/\.pdf$/i, '')) + '.pdf', data); }
    async deleteDocument(id: string) {
        const d = await this.document(id);
        await this.client.batch([{ sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [d.storageKey] }, { sql: 'DELETE FROM documents WHERE id=? AND owner=?', args: [id, this.owner] }], 'write');
    }
    /** Moves the group to the Recycle Bin; its documents and PDFs stay until it is purged. */
    async deleteGroup(id: string) {
        await this.group(id);
        await this.client.execute({ sql: 'UPDATE groups SET deleted_at=? WHERE id=? AND owner=?', args: [new Date().toISOString(), id, this.owner] });
    }
    async deletedGroups() { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE owner=? AND deleted_at>? ORDER BY deleted_at DESC', args: [this.owner, purgeCutoff()] }); return r.rows.map(deletedGroup); }
    private async requireDeletedGroup(id: string) { if (!(await this.deletedGroups()).some(g => g.id === id))
        throw new ApiError(404, 'Deleted group not found'); }
    async restoreGroup(id: string) {
        await this.requireDeletedGroup(id);
        await this.client.execute({ sql: 'UPDATE groups SET deleted_at=NULL WHERE id=? AND owner=?', args: [id, this.owner] });
        return this.group(id);
    }
    async purgeGroup(id: string) {
        await this.requireDeletedGroup(id);
        await this.client.batch([
            { sql: 'INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE group_id=? AND owner=?', args: [id, this.owner] },
            { sql: 'DELETE FROM documents WHERE group_id=? AND owner=?', args: [id, this.owner] },
            { sql: 'DELETE FROM group_views WHERE group_id=? AND owner=?', args: [id, this.owner] },
            { sql: 'DELETE FROM groups WHERE id=? AND owner=?', args: [id, this.owner] },
        ], 'write');
    }
    /** The only rows agent-written SQL and JavaScript can see: this owner's, optionally one group's. */
    async sandboxData(groupId?: string): Promise<SandboxData> {
        const groups = (await this.groups()).filter(g => !groupId || g.id === groupId);
        if (groupId && !groups.length)
            throw new ApiError(404, 'Group not found');
        const r = await this.client.execute({ sql: 'SELECT id,group_id,name,original_name,status,size,created_at,data_json data,additional_json FROM documents WHERE owner=? AND group_id IN (SELECT id FROM groups WHERE owner=? AND deleted_at IS NULL) AND (? IS NULL OR group_id=?)', args: [this.owner, this.owner, groupId ?? null, groupId ?? null] });
        return {
            groups: groups.map(g => ({ id: g.id, name: g.name, instructions: g.instructions, created_at: g.createdAt })),
            documents: r.rows.map(d => ({ id: d.id, group_id: d.group_id, name: d.name, original_name: d.original_name, status: d.status, size: d.size, created_at: d.created_at, data: d.data, additional: d.additional_json ? JSON.stringify(JSON.parse(String(d.additional_json)).facts ?? {}) : null })),
        };
    }
    async views(groupId: string) { await this.group(groupId); const r = await this.client.execute({ sql: 'SELECT * FROM group_views WHERE group_id=? AND owner=? ORDER BY created_at', args: [groupId, this.owner] }); return r.rows.map(view); }
    async view(groupId: string, id: string) { const v = (await this.views(groupId)).find(x => x.id === id); if (!v)
        throw new ApiError(404, 'View not found'); return v; }
    /** Checks a view against the group's real data, so a broken one never reaches review. */
    async checkView(groupId: string, input: unknown) {
        const v = viewInput.parse(input);
        validateUISpec(v.spec);
        if (v.kind === 'filter' && !v.queries.documents)
            throw new ApiError(422, 'A filter needs a query named "documents" that selects the id column');
        const results = await this.runQueries(groupId, v.queries);
        if (v.kind === 'filter' && !results.documents.columns.includes('id'))
            throw new ApiError(422, 'A filter\'s "documents" query must select the id column');
        return v;
    }
    async runQueries(groupId: string, queries: Record<string, string>, params: Record<string, SQLParam> = {}): Promise<Record<string, SQLResult>> {
        const data = await this.sandboxData(groupId);
        return runSQL(data, Object.fromEntries(Object.entries(queries).map(([name, sql]) => [name, { sql, params }])));
    }
    /** The spec's starting state plus each query's rows at /queries/<name>. */
    async viewState(groupId: string, input: { spec: Record<string, unknown>; queries: Record<string, string> }) {
        const results = await this.runQueries(groupId, input.queries);
        return { ...(input.spec.state as object | undefined), queries: Object.fromEntries(Object.entries(results).map(([name, result]) => [name, result.rows])) };
    }
    async createView(groupId: string, input: unknown) { const v = await this.checkView(groupId, input); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO group_views (id,group_id,owner,kind,title,spec_json,queries_json,created_at) VALUES(?,?,?,?,?,?,?,?)', args: [id, groupId, this.owner, v.kind, v.title, JSON.stringify(v.spec), JSON.stringify(v.queries), new Date().toISOString()] }); return this.view(groupId, id); }
    async updateView(groupId: string, id: string, input: unknown) { await this.view(groupId, id); const v = await this.checkView(groupId, input); await this.client.execute({ sql: 'UPDATE group_views SET kind=?,title=?,spec_json=?,queries_json=? WHERE id=? AND owner=?', args: [v.kind, v.title, JSON.stringify(v.spec), JSON.stringify(v.queries), id, this.owner] }); return this.view(groupId, id); }
    async deleteView(groupId: string, id: string) { await this.view(groupId, id); await this.client.execute({ sql: 'DELETE FROM group_views WHERE id=? AND owner=?', args: [id, this.owner] }); }
    /** Runs a filter with the values from its form. An empty value binds NULL. */
    async runFilter(groupId: string, id: string, values: Record<string, string | number | boolean | null>) {
        const v = await this.view(groupId, id);
        if (v.kind !== 'filter')
            throw new ApiError(400, 'This view is not a filter');
        const params = Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value === '' ? null : typeof value === 'boolean' ? Number(value) : value]));
        const results = await this.runQueries(groupId, { documents: v.queries.documents }, params);
        return { documentIds: results.documents.rows.map(row => String(row.id)) };
    }
    async propose(input: unknown) { const mutation = mutationInput.parse(input); if (mutation.action === 'create_view' || mutation.action === 'update_view')
        await this.checkView(mutation.groupId, mutation.view); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO proposals(id,owner,mutation,created_at) VALUES(?,?,?,?)', args: [id, this.owner, JSON.stringify(mutation), new Date().toISOString()] }); return { id, mutation, state: 'pending' }; }
    async proposals() { const r = await this.client.execute({ sql: "SELECT * FROM proposals WHERE owner=? AND state='pending' AND created_at>? ORDER BY created_at DESC", args: [this.owner, new Date(Date.now() - 86400000).toISOString()] }); return r.rows.map(x => ({ id: String(x.id), mutation: JSON.parse(String(x.mutation)), state: String(x.state) })); }
    async resolveProposal(id: string, approve: boolean) {
        // A transaction makes the mutation and one-time approval atomic.
        const tx = await this.client.transaction('write');
        try {
            const r = await tx.execute({ sql: "SELECT * FROM proposals WHERE id=? AND owner=? AND state='pending' AND created_at>?", args: [id, this.owner, new Date(Date.now() - 86400000).toISOString()] });
            if (!r.rows[0])
                throw new ApiError(404, 'Proposal expired or already handled');
            const m = mutationInput.parse(JSON.parse(String(r.rows[0].mutation)));
            const scoped = new Repository(this.owner, tx as unknown as Client);
            if (approve)
                switch (m.action) {
                    case 'create_group':
                        await scoped.createGroup(m.group);
                        break;
                    case 'update_group':
                        await scoped.updateGroup(m.groupId, m.group);
                        break;
                    case 'delete_group':
                        await scoped.deleteGroup(m.groupId);
                        break;
                    case 'delete_document':
                        await scoped.deleteDocument(m.documentId);
                        break;
                    case 'create_view':
                        await scoped.createView(m.groupId, m.view);
                        break;
                    case 'update_view':
                        await scoped.updateView(m.groupId, m.viewId, m.view);
                        break;
                    case 'delete_view':
                        await scoped.deleteView(m.groupId, m.viewId);
                        break;
                    case 'update_document':
                        await scoped.editDocument(m.documentId, m.name, m.data);
                        break;
                }
            await tx.execute({ sql: 'UPDATE proposals SET state=? WHERE id=? AND owner=?', args: [approve ? 'approved' : 'rejected', id, this.owner] });
            await tx.commit();
        }
        catch (e) {
            await tx.rollback();
            throw e;
        }
        finally {
            tx.close();
        }
        return { ok: true };
    }
}
