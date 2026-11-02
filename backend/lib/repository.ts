import { randomUUID } from 'node:crypto';
import type { Client, Row } from '@libsql/client';
import { db } from './db';
import { ApiError, groupInput, mutationInput, safeName, validateData, type Document, type Group } from './contracts';
function group(row: Row): Group { return { id: String(row.id), name: String(row.name), instructions: String(row.instructions), namingTemplate: String(row.naming_template), schema: JSON.parse(String(row.schema_json)), createdAt: String(row.created_at), documentCount: Number(row.document_count ?? 0) }; }
function document(row: Row): Document { return { id: String(row.id), groupId: String(row.group_id), name: String(row.name), originalName: String(row.original_name), storageKey: String(row.storage_key), size: Number(row.size), status: String(row.status), data: row.data_json ? JSON.parse(String(row.data_json)) : null, error: row.error ? String(row.error) : null, createdAt: String(row.created_at) }; }
export class Repository {
    constructor(readonly owner: string, private client: Client = db()) { }
    async groups() { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE owner=? ORDER BY created_at DESC', args: [this.owner] }); return r.rows.map(group); }
    async group(id: string) { const g = (await this.groups()).find(x => x.id === id); if (!g)
        throw new ApiError(404, 'Group not found'); return g; }
    async createGroup(input: unknown) { const g = groupInput.parse(input); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO groups VALUES(?,?,?,?,?,?,?)', args: [id, this.owner, g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), new Date().toISOString()] }); return this.group(id); }
    async updateGroup(id: string, input: unknown) { const g = groupInput.parse(input); await this.group(id); await this.client.execute({ sql: 'UPDATE groups SET name=?,instructions=?,naming_template=?,schema_json=? WHERE id=? AND owner=?', args: [g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), id, this.owner] }); return this.group(id); }
    async documents(groupId: string) { await this.group(groupId); const r = await this.client.execute({ sql: 'SELECT * FROM documents WHERE group_id=? AND owner=? ORDER BY created_at DESC', args: [groupId, this.owner] }); return r.rows.map(document); }
    async document(id: string) { const r = await this.client.execute({ sql: 'SELECT * FROM documents WHERE id=? AND owner=?', args: [id, this.owner] }); if (!r.rows[0])
        throw new ApiError(404, 'Document not found'); return document(r.rows[0]); }
    async addDocument(groupId: string, id: string, name: string, size: number) { await this.group(groupId); await this.client.execute({ sql: 'INSERT INTO documents (id,group_id,owner,name,original_name,storage_key,size,status,created_at) VALUES(?,?,?,?,?,?,?,?,?)', args: [id, groupId, this.owner, safeName(name), safeName(name), `${id}.pdf`, size, 'uploaded', new Date().toISOString()] }); return this.document(id); }
    async claimDocument(id: string) {
        await this.document(id);
        const r = await this.client.execute({ sql: "UPDATE documents SET status='processing',error=NULL,processing_started_at=? WHERE id=? AND owner=? AND (status!='processing' OR processing_started_at<?)", args: [new Date().toISOString(), id, this.owner, new Date(Date.now() - 180000).toISOString()] });
        if (!r.rowsAffected)
            throw new ApiError(409, 'Document is already being processed');
    }
    async complete(id: string, name: string, data: unknown) { await this.client.execute({ sql: "UPDATE documents SET name=?,data_json=?,status='ready',error=NULL WHERE id=? AND owner=?", args: [safeName(name), JSON.stringify(data), id, this.owner] }); return this.document(id); }
    async fail(id: string) { await this.client.execute({ sql: "UPDATE documents SET status='failed',error='Processing failed. Please retry.' WHERE id=? AND owner=?", args: [id, this.owner] }); }
    async editDocument(id: string, name: string, data: unknown) { const d = await this.document(id); if (d.status === 'processing')
        throw new ApiError(409, 'Wait for processing to finish'); const g = await this.group(d.groupId); validateData(g.schema, data); return this.complete(id, safeName(name.replace(/\.pdf$/i, '')) + '.pdf', data); }
    async deleteDocument(id: string) {
        const d = await this.document(id);
        await this.client.batch([{ sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [d.storageKey] }, { sql: 'DELETE FROM documents WHERE id=? AND owner=?', args: [id, this.owner] }], 'write');
    }
    async deleteGroup(id: string) {
        await this.group(id);
        await this.client.batch([
            { sql: 'INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE group_id=? AND owner=?', args: [id, this.owner] },
            { sql: 'DELETE FROM documents WHERE group_id=? AND owner=?', args: [id, this.owner] },
            { sql: 'DELETE FROM groups WHERE id=? AND owner=?', args: [id, this.owner] },
        ], 'write');
    }
    async propose(input: unknown) { const mutation = mutationInput.parse(input); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO proposals(id,owner,mutation,created_at) VALUES(?,?,?,?)', args: [id, this.owner, JSON.stringify(mutation), new Date().toISOString()] }); return { id, mutation, state: 'pending' }; }
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
