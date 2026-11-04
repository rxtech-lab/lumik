import { documentOrder, type DocumentSort } from './document-sort';
import { randomUUID } from 'node:crypto';
import type { Client, Row } from '@libsql/client';
import { db, documentChildrenCleanup, emptySigningRequests } from './db';
import { z } from 'zod';
import { ApiError, groupInput, mutationInput, newGroupInput, safeName, validateData, viewInput, type Additional, type DeletedGroup, type Document, type Group, type GroupView, type Schema } from './contracts';
import { runSQL, type SandboxData, type SQLParam, type SQLResult } from './sql-sandbox';
import { runJS } from './js-sandbox';
import { validateUISpec } from './ui-catalog';
function group(row: Row): Group { return { id: String(row.id), parentId: row.parent_id ? String(row.parent_id) : null, kind: row.kind === 'inbox' ? 'inbox' : 'group', name: String(row.name), instructions: String(row.instructions), namingTemplate: String(row.naming_template), extractAdditional: Boolean(row.extract_additional), schema: JSON.parse(String(row.schema_json)), createdAt: String(row.created_at), documentCount: Number(row.document_count ?? 0) }; }
export function document(row: Row): Document { return { id: String(row.id), groupId: String(row.group_id), name: String(row.name), originalName: String(row.original_name), storageKey: String(row.storage_key), size: Number(row.size), status: String(row.status), data: row.data_json ? JSON.parse(String(row.data_json)) : null, additional: row.additional_json ? JSON.parse(String(row.additional_json)) : null, error: row.error ? String(row.error) : null, createdAt: String(row.created_at) }; }
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
    // This runs after most deletes and rarely has work, so don't spend writes when it has none.
    if (!(await client.execute({ sql: `${expired} LIMIT 1`, args })).rows.length)
        return;
    await client.batch([
        { sql: `INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE group_id IN (${expired})`, args },
        ...documentChildrenCleanup(`SELECT id FROM documents WHERE group_id IN (${expired})`, args),
        { sql: `DELETE FROM documents WHERE group_id IN (${expired})`, args },
        { sql: `DELETE FROM group_views WHERE group_id IN (${expired})`, args },
        { sql: 'DELETE FROM groups WHERE deleted_at IS NOT NULL AND deleted_at<=?', args },
        { sql: 'DELETE FROM signing_requests WHERE NOT EXISTS (SELECT 1 FROM filled_forms f WHERE f.signing_request_id=signing_requests.id)', args: [] },
    ], 'write');
}
/** Fields the inbox reads from each scan, so Lumik can file it without opening the PDF again. */
const inboxSchema: Schema = { type: 'object', properties: {
    document_type: { type: 'string', description: 'What kind of document this is, such as invoice, receipt, contract, or letter' },
    summary: { type: 'string', description: 'One sentence saying who it is from and what it is about' },
    date: { type: ['string', 'null'], description: 'The date the document states, as YYYY-MM-DD' },
}, required: ['document_type', 'summary', 'date'], additionalProperties: false };
const inboxInstructions = 'Scans wait here until they are filed. Identify what each one is so it can be filed in the right group.';
type OrganizeMutation = Extract<z.infer<typeof mutationInput>, { action: 'organize_documents' }>;
/** A group that is already deleted or was in another batch keeps its own place in the Recycle Bin. */
function deletedBatch(all: DeletedGroup[], root: DeletedGroup): DeletedGroup[] {
    const children = all.filter(g => g.parentId === root.id && g.deletedAt === root.deletedAt);
    return [root, ...children.flatMap(child => deletedBatch(all, child))];
}
const sameFields = (a: Schema, b: Schema) => JSON.stringify(a) === JSON.stringify(b);
export class Repository {
    constructor(readonly owner: string, private client: Client = db()) { }
    async groups() { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE owner=? AND deleted_at IS NULL ORDER BY created_at DESC', args: [this.owner] }); return r.rows.map(group); }
    async group(id: string) { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE g.id=? AND g.owner=? AND g.deleted_at IS NULL', args: [id, this.owner] }); if (!r.rows[0])
        throw new ApiError(404, 'Group not found'); return group(r.rows[0]); }
    /** Finds this account's inbox, creating it the first time it is needed. */
    async inbox() {
        await this.client.execute({ sql: "INSERT OR IGNORE INTO groups (id,owner,name,instructions,naming_template,schema_json,created_at,kind) VALUES(?,?,?,?,?,?,?,'inbox')", args: [randomUUID(), this.owner, 'Inbox', inboxInstructions, '{date}-{title}', JSON.stringify(inboxSchema), new Date().toISOString()] });
        return (await this.groups()).find(g => g.kind === 'inbox')!;
    }
    private async requireParent(id: string) {
        const parent = await this.group(id);
        if (parent.kind === 'inbox')
            throw new ApiError(422, 'The Inbox cannot have subgroups');
        return parent;
    }
    async createGroup(input: unknown) { const g = newGroupInput.parse(input); if (g.parentId)
        await this.requireParent(g.parentId); const id = randomUUID(); await this.client.execute({ sql: 'INSERT INTO groups (id,owner,parent_id,name,instructions,naming_template,schema_json,created_at,extract_additional) VALUES(?,?,?,?,?,?,?,?,?)', args: [id, this.owner, g.parentId ?? null, g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), new Date().toISOString(), g.extractAdditional ? 1 : 0] }); return this.group(id); }
    async moveGroup(id: string, parentId: string | null) {
        const moving = await this.group(id);
        if (moving.kind === 'inbox') throw new ApiError(422, 'The Inbox cannot be moved');
        let ancestor = parentId;
        const visited = new Set<string>();
        while (ancestor) {
            if (ancestor === id || visited.has(ancestor)) throw new ApiError(422, 'A group cannot be moved into itself or its descendants');
            visited.add(ancestor);
            ancestor = (await this.requireParent(ancestor)).parentId;
        }
        await this.client.execute({ sql: 'UPDATE groups SET parent_id=? WHERE id=? AND owner=?', args: [parentId, id, this.owner] });
        return this.group(id);
    }
    async updateGroup(id: string, input: unknown) { const g = groupInput.parse(input); if ((await this.group(id)).kind === 'inbox')
        throw new ApiError(422, 'The Inbox cannot be edited'); await this.client.execute({ sql: 'UPDATE groups SET name=?,instructions=?,naming_template=?,schema_json=?,extract_additional=? WHERE id=? AND owner=?', args: [g.name, g.instructions, g.namingTemplate, JSON.stringify(g.schema), g.extractAdditional ? 1 : 0, id, this.owner] }); return this.group(id); }
    /** One statement: a missing group returns no row, and a group without documents one row of NULLs. */
    async documents(groupId: string, sort: Partial<DocumentSort> = {}) { const r = await this.client.execute({ sql: `SELECT d.* FROM groups g LEFT JOIN documents d ON d.group_id=g.id AND d.owner=g.owner WHERE g.id=? AND g.owner=? AND g.deleted_at IS NULL ORDER BY ${documentOrder(sort)}`, args: [groupId, this.owner] }); if (!r.rows.length)
        throw new ApiError(404, 'Group not found'); return r.rows.filter(row => row.id !== null).map(document); }
    async document(id: string) { const r = await this.client.execute({ sql: 'SELECT d.* FROM documents d JOIN groups g ON g.id=d.group_id WHERE d.id=? AND d.owner=? AND g.deleted_at IS NULL', args: [id, this.owner] }); if (!r.rows[0])
        throw new ApiError(404, 'Document not found'); return document(r.rows[0]); }
    async addDocument(groupId: string, id: string, name: string, size: number) { await this.group(groupId); const now = new Date().toISOString(); await this.client.batch([
        { sql: 'INSERT INTO documents (id,group_id,owner,name,original_name,storage_key,size,status,created_at,current_version_id) VALUES(?,?,?,?,?,?,?,?,?,?)', args: [id, groupId, this.owner, safeName(name), safeName(name), `${id}.pdf`, size, 'uploaded', now, id] },
        { sql: 'INSERT INTO document_versions (id,document_id,owner,number,name,storage_key,size,created_at) VALUES(?,?,?,1,?,?,?,?)', args: [id, id, this.owner, safeName(name), `${id}.pdf`, size, now] },
    ], 'write'); return this.document(id); }
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
    /** Changes only the name, so documents that were never extracted keep their status and data. */
    async renameDocument(id: string, name: string) { const d = await this.document(id); if (d.status === 'processing')
        throw new ApiError(409, 'Wait for processing to finish'); await this.client.execute({ sql: 'UPDATE documents SET name=? WHERE id=? AND owner=?', args: [safeName(name.replace(/\.pdf$/i, '')) + '.pdf', id, this.owner] }); return this.document(id); }
    async deleteDocument(id: string) {
        const d = await this.document(id);
        await this.client.batch([
            { sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [d.storageKey] },
            ...documentChildrenCleanup('SELECT id FROM documents WHERE id=? AND owner=?', [id, this.owner]),
            { sql: 'DELETE FROM documents WHERE id=? AND owner=?', args: [id, this.owner] },
            emptySigningRequests(this.owner),
        ], 'write');
    }
    /** Files a document in another group. Returns whether its PDF must be read for the new group's fields. */
    private async relocate(d: Document, from: Group, targetId: string, targetSchema: Schema) {
        const reread = !sameFields(from.schema, targetSchema);
        await this.client.execute(reread
            ? { sql: "UPDATE documents SET group_id=?,status='processing',error=NULL,data_json=NULL,additional_json=NULL,processing_started_at=? WHERE id=? AND owner=?", args: [targetId, new Date().toISOString(), d.id, this.owner] }
            : { sql: 'UPDATE documents SET group_id=? WHERE id=? AND owner=?', args: [targetId, d.id, this.owner] });
        return reread;
    }
    private requireMovable(d: Document) {
        if (d.status === 'processing')
            throw new ApiError(409, `Wait for ${d.name} to finish processing`);
    }
    /** The caller reads the PDF again when `reread` is true, since its fields no longer apply. */
    async moveDocument(id: string, groupId: string) {
        const d = await this.document(id);
        this.requireMovable(d);
        const groups = await this.groups();
        const from = groups.find(g => g.id === d.groupId)!;
        const to = groups.find(g => g.id === groupId);
        if (!to)
            throw new ApiError(404, 'Group not found');
        if (to.kind === 'inbox')
            throw new ApiError(422, 'Documents cannot be moved into the Inbox');
        if (to.id === from.id)
            return { document: d, reread: false };
        const reread = await this.relocate(d, from, to.id, to.schema);
        return { document: await this.document(id), reread };
    }
    /** Checks a whole plan against current data and describes it, without changing anything. */
    private async planOrganize(m: OrganizeMutation) {
        if (!m.newGroups.length && !m.moves.length)
            throw new ApiError(422, 'Add at least one new group or move');
        const existing = new Map((await this.groups()).map(g => [g.id, g]));
        const planned = new Map<string, { input: { name: string; instructions: string; namingTemplate: string; extractAdditional: boolean; schema: Schema }; parent: string | null; path: string }>();
        const pathOf = (g: Group): string => { const parent = g.parentId ? existing.get(g.parentId) : undefined; return parent ? `${pathOf(parent)} / ${g.name}` : g.name; };
        const unknown = (value: string) => new ApiError(422, `Unknown group "${value}". Use an ID from list_groups or the ref of an earlier new group.`);
        for (const g of m.newGroups) {
            if (planned.has(g.ref) || existing.has(g.ref))
                throw new ApiError(422, `The ref "${g.ref}" is already used`);
            const parentGroup = g.parent ? existing.get(g.parent) : undefined;
            const parentPlan = g.parent ? planned.get(g.parent) : undefined;
            if (g.parent && !parentGroup && !parentPlan)
                throw unknown(g.parent);
            if (parentGroup?.kind === 'inbox')
                throw new ApiError(422, 'The Inbox cannot have subgroups');
            const inherited = parentGroup ?? parentPlan?.input;
            const schema = g.schema ?? inherited?.schema;
            if (!schema)
                throw new ApiError(422, `The new group "${g.name}" needs a schema because it has no parent`);
            const input = { name: g.name, schema, instructions: g.instructions ?? inherited?.instructions ?? '', namingTemplate: g.namingTemplate ?? inherited?.namingTemplate ?? '{date}-{title}', extractAdditional: g.extractAdditional ?? inherited?.extractAdditional ?? false };
            const parentPath = parentGroup ? pathOf(parentGroup) : parentPlan?.path;
            planned.set(g.ref, { input, parent: g.parent ?? null, path: parentPath ? `${parentPath} / ${g.name}` : g.name });
        }
        if (new Set(m.moves.map(move => move.documentId)).size !== m.moves.length)
            throw new ApiError(422, 'Each document can be moved only once');
        const moves = [];
        for (const move of m.moves) {
            const document = await this.document(move.documentId);
            this.requireMovable(document);
            const from = existing.get(document.groupId)!;
            const toGroup = existing.get(move.target);
            const toPlan = planned.get(move.target);
            if (!toGroup && !toPlan)
                throw unknown(move.target);
            if (toGroup?.kind === 'inbox')
                throw new ApiError(422, 'Documents cannot be moved into the Inbox');
            if (toGroup?.id === from.id)
                throw new ApiError(422, `${document.name} is already in ${from.name}`);
            moves.push({ document, from, target: move.target, schema: (toGroup ?? toPlan!.input).schema, toPath: toGroup ? pathOf(toGroup) : toPlan!.path });
        }
        return {
            planned,
            moves,
            review: {
                newGroups: [...planned.values()].map(g => ({ path: g.path, fields: Object.keys((g.input.schema.properties ?? {}) as object) })),
                moves: moves.map(move => ({ document: move.document.name, from: pathOf(move.from), to: move.toPath, reread: !sameFields(move.from.schema, move.schema) })),
            },
        };
    }
    /** Creates the new groups and moves the documents. Returns the documents to read again. */
    private async organize(m: OrganizeMutation) {
        const { planned, moves } = await this.planOrganize(m);
        const created = new Map<string, string>();
        for (const [ref, g] of planned) {
            const parentId = g.parent ? created.get(g.parent) ?? g.parent : null;
            created.set(ref, (await this.createGroup({ ...g.input, parentId })).id);
        }
        const reread: string[] = [];
        for (const move of moves)
            if (await this.relocate(move.document, move.from, created.get(move.target) ?? move.target, move.schema))
                reread.push(move.document.id);
        return reread;
    }
    /** Moves the group and its subgroups to the Recycle Bin; their documents and PDFs stay until they are purged. */
    async deleteGroup(id: string) {
        if ((await this.group(id)).kind === 'inbox')
            throw new ApiError(422, 'The Inbox cannot be deleted');
        await this.client.execute({ sql: 'WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT g.id FROM groups g JOIN tree ON g.parent_id=tree.id WHERE g.owner=? AND g.deleted_at IS NULL) UPDATE groups SET deleted_at=? WHERE owner=? AND id IN (SELECT id FROM tree)', args: [id, this.owner, new Date().toISOString(), this.owner] });
    }
    private async allDeleted() { const r = await this.client.execute({ sql: 'SELECT g.*, (SELECT count(*) FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner) document_count FROM groups g WHERE owner=? AND deleted_at>? ORDER BY deleted_at DESC', args: [this.owner, purgeCutoff()] }); return r.rows.map(deletedGroup); }
    /** Subgroups deleted with their parent appear as one entry, counted in the parent. */
    async deletedGroups() {
        const all = await this.allDeleted();
        return all.filter(g => !all.some(p => p.id === g.parentId && p.deletedAt === g.deletedAt))
            .map(g => ({ ...g, documentCount: deletedBatch(all, g).reduce((sum, member) => sum + member.documentCount, 0) }));
    }
    private async requireDeletedBatch(id: string) {
        const all = await this.allDeleted();
        const root = all.find(g => g.id === id);
        if (!root || all.some(p => p.id === root.parentId && p.deletedAt === root.deletedAt))
            throw new ApiError(404, 'Deleted group not found');
        return { root, ids: deletedBatch(all, root).map(g => g.id) };
    }
    async restoreGroup(id: string) {
        const { root, ids } = await this.requireDeletedBatch(id);
        const marks = ids.map(() => '?').join(',');
        // A parent that is gone or still in the bin can't hold it, so it comes back at the top level.
        const parentAlive = root.parentId ? (await this.groups()).some(g => g.id === root.parentId) : false;
        await this.client.batch([
            { sql: `UPDATE groups SET deleted_at=NULL WHERE id IN (${marks}) AND owner=?`, args: [...ids, this.owner] },
            { sql: 'UPDATE groups SET parent_id=? WHERE id=? AND owner=?', args: [parentAlive ? root.parentId : null, id, this.owner] },
        ], 'write');
        return this.group(id);
    }
    async purgeGroup(id: string) {
        const { ids } = await this.requireDeletedBatch(id);
        const marks = ids.map(() => '?').join(',');
        const args = [...ids, this.owner];
        await this.client.batch([
            { sql: `INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE group_id IN (${marks}) AND owner=?`, args },
            ...documentChildrenCleanup(`SELECT id FROM documents WHERE group_id IN (${marks}) AND owner=?`, args),
            { sql: `DELETE FROM documents WHERE group_id IN (${marks}) AND owner=?`, args },
            { sql: `DELETE FROM group_views WHERE group_id IN (${marks}) AND owner=?`, args },
            { sql: `DELETE FROM groups WHERE id IN (${marks}) AND owner=?`, args },
            emptySigningRequests(this.owner),
        ], 'write');
    }
    /** The only rows agent-written SQL and JavaScript can see: this owner's, optionally one group's. */
    async sandboxData(groupId?: string): Promise<SandboxData> {
        const groups = (await this.groups()).filter(g => !groupId || g.id === groupId);
        if (groupId && !groups.length)
            throw new ApiError(404, 'Group not found');
        const r = await this.client.execute({ sql: 'SELECT id,group_id,name,original_name,status,size,created_at,data_json data,additional_json FROM documents WHERE owner=? AND group_id IN (SELECT id FROM groups WHERE owner=? AND deleted_at IS NULL) AND (? IS NULL OR group_id=?)', args: [this.owner, this.owner, groupId ?? null, groupId ?? null] });
        return {
            groups: groups.map(g => ({ id: g.id, parent_id: g.parentId, kind: g.kind, name: g.name, instructions: g.instructions, created_at: g.createdAt })),
            documents: r.rows.map(d => ({ id: d.id, group_id: d.group_id, name: d.name, original_name: d.original_name, status: d.status, size: d.size, created_at: d.created_at, data: d.data, additional: d.additional_json ? JSON.stringify(JSON.parse(String(d.additional_json)).facts ?? {}) : null })),
        };
    }
    async views(groupId: string) { await this.group(groupId); const r = await this.client.execute({ sql: 'SELECT * FROM group_views WHERE group_id=? AND owner=? ORDER BY created_at', args: [groupId, this.owner] }); return r.rows.map(view); }
    async view(groupId: string, id: string) { const r = await this.client.execute({ sql: 'SELECT v.* FROM group_views v JOIN groups g ON g.id=v.group_id WHERE v.id=? AND v.group_id=? AND v.owner=? AND g.deleted_at IS NULL', args: [id, groupId, this.owner] }); if (!r.rows[0])
        throw new ApiError(404, 'View not found'); return view(r.rows[0]); }
    /** Checks a view against the group's real data, so a broken one never reaches review. */
    async checkView(groupId: string, input: unknown) {
        const v = viewInput.parse(input);
        validateUISpec(v.spec);
        if (v.kind === 'filter' && !v.queries.documents)
            throw new ApiError(422, 'A filter needs a query named "documents" that selects the id column');
        const results = await this.runQueries(groupId, v.queries, this.viewParams(v.spec));
        if (v.kind === 'filter' && !results.documents.columns.includes('id'))
            throw new ApiError(422, 'A filter\'s "documents" query must select the id column');
        await this.statisticsState(v.spec, results);
        return v;
    }
    async runQueries(groupId: string, queries: Record<string, string>, params: Record<string, SQLParam> = {}): Promise<Record<string, SQLResult>> {
        const data = await this.sandboxData(groupId);
        return runSQL(data, Object.fromEntries(Object.entries(queries).map(([name, sql]) => [name, { sql, params }])));
    }
    /** The spec's starting state plus each query's rows at /queries/<name>. */
    private viewParams(spec: Record<string, unknown>): Record<string, SQLParam> {
        return Object.fromEntries(Object.entries((spec.state ?? {}) as Record<string, unknown>)
            .filter(([key, value]) => !['queries', 'processed'].includes(key) && (value === null || ['string', 'number', 'boolean'].includes(typeof value)))
            .map(([key, value]) => [key, value === '' ? null : typeof value === 'boolean' ? Number(value) : value as SQLParam]));
    }
    async viewState(groupId: string, input: { spec: Record<string, unknown>; queries: Record<string, string> }, values: Record<string, string | number | boolean | null> = {}) {
        const spec = { ...input.spec, state: { ...(input.spec.state as object | undefined), ...values } };
        const results = await this.runQueries(groupId, input.queries, this.viewParams(spec));
        return this.statisticsState(spec, results);
    }
    private async statisticsState(spec: Record<string, unknown>, results: Record<string, SQLResult>) {
        const queries = Object.fromEntries(Object.entries(results).map(([name, result]) => [name, result.rows]));
        const state = { ...(spec.state as object | undefined), queries };
        if (spec.postProcess === undefined) return state;
        if (typeof spec.postProcess !== 'string' || spec.postProcess.length > 8000)
            throw new ApiError(422, 'postProcess must be JavaScript of at most 8000 characters');
        const { result } = await runJS(spec.postProcess, { queries });
        if (!result || typeof result !== 'object' || Array.isArray(result))
            throw new ApiError(422, 'postProcess must return an object');
        if (JSON.stringify(result).length > 200000)
            throw new ApiError(422, 'postProcess output is too large');
        return { ...state, processed: result };
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
    async addChatMessage(conversationId: string, role: 'user' | 'assistant', content: string, activity: { tool: string; detail: string | null }[] = []) {
        await this.client.execute({ sql: 'INSERT INTO chat_messages (id,owner,conversation_id,role,content,activity_json,created_at) VALUES(?,?,?,?,?,?,?)', args: [randomUUID(), this.owner, conversationId, role, content, JSON.stringify(activity), new Date().toISOString()] });
    }
    /** The most recent conversation, oldest message first, up to its last 100 messages. */
    async latestConversation() {
        const latest = await this.client.execute({ sql: 'SELECT conversation_id FROM chat_messages WHERE owner=? ORDER BY created_at DESC, rowid DESC LIMIT 1', args: [this.owner] });
        if (!latest.rows[0])
            return { conversationId: null, messages: [] };
        const conversationId = String(latest.rows[0].conversation_id);
        const r = await this.client.execute({ sql: 'SELECT * FROM chat_messages WHERE owner=? AND conversation_id=? ORDER BY created_at DESC, rowid DESC LIMIT 100', args: [this.owner, conversationId] });
        return { conversationId, messages: r.rows.reverse().map(x => ({ id: String(x.id), role: String(x.role), content: String(x.content), activity: JSON.parse(String(x.activity_json)), createdAt: String(x.created_at) })) };
    }
    async propose(input: unknown) {
        const parsed = mutationInput.parse(input);
        if (parsed.action === 'create_view' || parsed.action === 'update_view')
            await this.checkView(parsed.groupId, parsed.view);
        if (parsed.action === 'create_group' && parsed.group.parentId)
            await this.requireParent(parsed.group.parentId);
        // IDs mean nothing to the person reviewing, so an organize plan also carries its names.
        const mutation = parsed.action === 'organize_documents' ? { ...parsed, review: (await this.planOrganize(parsed)).review } : parsed;
        const id = randomUUID();
        await this.client.execute({ sql: 'INSERT INTO proposals(id,owner,mutation,created_at) VALUES(?,?,?,?)', args: [id, this.owner, JSON.stringify(mutation), new Date().toISOString()] });
        return { id, mutation, state: 'pending' };
    }
    async proposals() { const r = await this.client.execute({ sql: "SELECT * FROM proposals WHERE owner=? AND state='pending' AND created_at>? ORDER BY created_at DESC", args: [this.owner, new Date(Date.now() - 86400000).toISOString()] }); return r.rows.map(x => ({ id: String(x.id), mutation: JSON.parse(String(x.mutation)), state: String(x.state) })); }
    async resolveProposal(id: string, approve: boolean) {
        // A transaction makes the mutation and one-time approval atomic.
        const tx = await this.client.transaction('write');
        let reread: string[] = [];
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
                    case 'rename_document':
                        await scoped.renameDocument(m.documentId, m.name);
                        break;
                    case 'organize_documents':
                        reread = await scoped.organize(m);
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
        return { ok: true, reread };
    }
}
