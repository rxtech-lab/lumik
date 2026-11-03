import { randomUUID } from 'node:crypto';
import type { Client, Row } from '@libsql/client';
import { ApiError, safeName, type Document, type FormSection } from './contracts';
import { db, emptySigningRequests } from './db';
import { document as documentFromRow } from './repository';
import { presignDownload } from './storage';

/**
 * Every read here is one SQL statement: rows that belong together come back as JSON columns, so a
 * page costs one database round trip and no follow-up API calls.
 */
const array = (select: string, order: string) => `(SELECT json_group_array(json(item)) FROM (SELECT ${select} ORDER BY ${order}))`;
const formJSON = (sections: boolean) => `json_object('id',f.id,'documentId',f.document_id,'documentName',d.name,'groupId',d.group_id,'versionId',f.version_id,'versionNumber',v.number,'templateId',f.template_id,'title',f.title,'status',f.status,'revision',f.revision,'values',json(f.values_json),'signingRequestId',f.signing_request_id,'signingRequestTitle',(SELECT r.title FROM signing_requests r WHERE r.id=f.signing_request_id),'signatureMethod',f.signature_method,'signedAt',f.signed_at,'signedSize',f.signed_size,'createdAt',f.created_at,'updatedAt',f.updated_at,'versionKey',v.storage_key,'signedKey',f.signed_storage_key${sections ? ",'sections',json(t.sections_json),'templateTitle',t.title" : ''}) item`;
const formTables = 'filled_forms f JOIN documents d ON d.id=f.document_id JOIN document_versions v ON v.id=f.version_id JOIN form_templates t ON t.id=f.template_id';
const documentJSON = `json_object('id',d.id,'groupId',d.group_id,'name',d.name,'originalName',d.original_name,'status',d.status,'data',json(d.data_json),'additional',json(d.additional_json),'error',d.error,'createdAt',d.created_at,'size',d.size) item`;
const viewJSON = `json_object('id',v.id,'groupId',v.group_id,'kind',v.kind,'title',v.title,'spec',json(v.spec_json),'queries',json(v.queries_json),'createdAt',v.created_at) item`;

type RawForm = Record<string, unknown> & { id: string; documentId: string; versionId: string; status: string; title: string; values: unknown; signatureMethod: string | null; versionKey?: string; signedKey?: string | null };
const parse = <T>(value: unknown): T[] => JSON.parse(String(value ?? '[]')) as T[];
async function linkForm({ versionKey, signedKey, ...form }: RawForm) {
    const [pdfUrl, signedPdfUrl] = await Promise.all([presignDownload(versionKey!), signedKey ? presignDownload(signedKey) : null]);
    return { ...form, pdfPath: `documents/${form.documentId}/versions/${form.versionId}/pdf`, pdfUrl, signedPdfPath: signedKey ? `forms/${form.id}/signed-pdf` : null, signedPdfUrl };
}
const summary = ({ versionKey: _version, signedKey, ...form }: RawForm) => ({ ...form, signedPdfPath: signedKey ? `forms/${form.id}/signed-pdf` : null });

export class Forms {
    constructor(readonly owner: string, private client: Client = db()) { }

    private async checkpointTable() {
        await this.client.execute(`CREATE TABLE IF NOT EXISTS form_generation_checkpoints (
            owner TEXT NOT NULL, version_id TEXT NOT NULL, draft_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL, PRIMARY KEY(owner, version_id))`);
    }
    async generationCheckpoint(versionId: string): Promise<unknown | null> {
        await this.checkpointTable();
        const result = await this.client.execute({ sql: 'SELECT draft_json FROM form_generation_checkpoints WHERE owner=? AND version_id=? AND updated_at>?', args: [this.owner, versionId, Date.now() - 86400000] });
        return result.rows[0] ? JSON.parse(String(result.rows[0].draft_json)) : null;
    }
    async saveGenerationCheckpoint(versionId: string, draft: unknown) {
        await this.checkpointTable();
        await this.client.execute({ sql: 'INSERT INTO form_generation_checkpoints(owner,version_id,draft_json,updated_at) VALUES(?,?,?,?) ON CONFLICT(owner,version_id) DO UPDATE SET draft_json=excluded.draft_json,updated_at=excluded.updated_at', args: [this.owner, versionId, JSON.stringify(draft), Date.now()] });
    }
    async clearGenerationCheckpoint(versionId: string) {
        await this.checkpointTable();
        await this.client.execute({ sql: 'DELETE FROM form_generation_checkpoints WHERE owner=? AND version_id=?', args: [this.owner, versionId] });
    }

    /** The PDF page: the document, its versions, form templates, and every filled form. */
    async workspace(documentId: string) {
        const r = await this.client.execute({ sql: `SELECT d.*,
            ${array("json_object('id',x.id,'number',x.number,'name',x.name,'size',x.size,'createdAt',x.created_at,'storageKey',x.storage_key) item FROM document_versions x WHERE x.document_id=d.id AND x.owner=d.owner", 'x.number DESC')} versions_json,
            ${array("json_object('id',x.id,'versionId',x.version_id,'title',x.title,'source',x.source,'sections',json(x.sections_json),'createdAt',x.created_at,'updatedAt',x.updated_at) item FROM form_templates x WHERE x.document_id=d.id AND x.owner=d.owner", 'x.created_at DESC')} templates_json,
            (SELECT json_group_array(json(item)) FROM (SELECT ${formJSON(false).replace(/\bd\./g, 'fd.')} FROM filled_forms f JOIN documents fd ON fd.id=f.document_id JOIN document_versions v ON v.id=f.version_id WHERE f.document_id=d.id AND f.owner=d.owner ORDER BY f.updated_at DESC)) forms_json
            FROM documents d JOIN groups g ON g.id=d.group_id WHERE d.id=? AND d.owner=? AND g.deleted_at IS NULL`, args: [documentId, this.owner] });
        const row = r.rows[0];
        if (!row)
            throw new ApiError(404, 'Document not found');
        const { storageKey: _key, ...document } = documentFromRow(row);
        const versions = await Promise.all(parse<{ id: string; number: number; storageKey: string }>(row.versions_json).map(async ({ storageKey, ...version }) => ({
            ...version, isCurrent: version.id === row.current_version_id, pdfPath: `documents/${documentId}/versions/${version.id}/pdf`, pdfUrl: await presignDownload(storageKey),
        })));
        return { document, versions, templates: parse(row.templates_json), forms: await Promise.all(parse<RawForm>(row.forms_json).map(linkForm)) };
    }

    /** The group page: its documents, views, and forms in one statement. */
    async overview(groupId: string) {
        const r = await this.client.execute({ sql: `SELECT g.id, g.parent_id,
            ${array(`${documentJSON} FROM documents d WHERE d.group_id=g.id AND d.owner=g.owner`, 'd.created_at DESC')} documents_json,
            ${array(`${viewJSON} FROM group_views v WHERE v.group_id=g.id AND v.owner=g.owner`, 'v.created_at')} views_json,
            ${array(`${formJSON(false)} FROM ${formTables} WHERE d.group_id=g.id AND d.owner=g.owner AND f.owner=g.owner`, 'f.updated_at DESC')} forms_json
            FROM groups g WHERE g.id=? AND g.owner=? AND g.deleted_at IS NULL`, args: [groupId, this.owner] });
        const row = r.rows[0];
        if (!row)
            throw new ApiError(404, 'Group not found');
        return { documents: parse<Omit<Document, 'storageKey'>>(row.documents_json), views: parse(row.views_json), forms: parse<RawForm>(row.forms_json).map(summary) };
    }

    /** One filled form with all it takes to show or render it, for opening it from a list. */
    async form(id: string) {
        return linkForm(await this.formRow(id));
    }
    private async formRow(id: string) {
        const r = await this.client.execute({ sql: `SELECT ${formJSON(true)} FROM ${formTables} JOIN groups g ON g.id=d.group_id WHERE f.id=? AND f.owner=? AND g.deleted_at IS NULL`, args: [id, this.owner] });
        if (!r.rows[0])
            throw new ApiError(404, 'Form not found');
        return JSON.parse(String(r.rows[0].item)) as RawForm;
    }
    async signedFile(id: string) {
        const r = await this.client.execute({ sql: 'SELECT f.signed_storage_key, f.title FROM filled_forms f JOIN documents d ON d.id=f.document_id JOIN groups g ON g.id=d.group_id WHERE f.id=? AND f.owner=? AND g.deleted_at IS NULL', args: [id, this.owner] });
        if (!r.rows[0]?.signed_storage_key)
            throw new ApiError(404, 'Signed PDF not found');
        return { key: String(r.rows[0].signed_storage_key), name: `${safeName(String(r.rows[0].title))}.pdf` };
    }

    // MARK: Templates
    /** The current version's PDF, and its template when one is already saved. */
    async templateContext(documentId: string) {
        const r = await this.client.execute({ sql: "SELECT d.*, (SELECT json_object('id',t.id,'versionId',t.version_id,'title',t.title,'source',t.source,'sections',json(t.sections_json),'createdAt',t.created_at,'updatedAt',t.updated_at) FROM form_templates t WHERE t.version_id=d.current_version_id) template_json FROM documents d JOIN groups g ON g.id=d.group_id WHERE d.id=? AND d.owner=? AND g.deleted_at IS NULL", args: [documentId, this.owner] });
        const row = r.rows[0];
        if (!row)
            throw new ApiError(404, 'Document not found');
        return { document: documentFromRow(row), versionId: String(row.current_version_id), template: row.template_json ? JSON.parse(String(row.template_json)) as Record<string, unknown> & { id: string } : null };
    }
    /** Saves the template, plus a first draft if it has none. A retry reuses what is already there. */
    async saveTemplate(documentId: string, versionId: string, title: string, source: 'acroform' | 'ai', sections: FormSection[]) {
        const now = new Date().toISOString();
        const results = await this.client.batch([
            { sql: 'INSERT OR IGNORE INTO form_templates (id,owner,document_id,version_id,title,source,sections_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)', args: [randomUUID(), this.owner, documentId, versionId, safeName(title), source, JSON.stringify(sections), now, now] },
            { sql: "SELECT json_object('id',t.id,'versionId',t.version_id,'title',t.title,'source',t.source,'sections',json(t.sections_json),'createdAt',t.created_at,'updatedAt',t.updated_at) template_json FROM form_templates t WHERE t.version_id=? AND t.owner=?", args: [versionId, this.owner] },
        ], 'write');
        return JSON.parse(String(results[1].rows[0].template_json)) as Record<string, unknown> & { id: string };
    }
    async updateTemplate(id: string, title: string, sections: FormSection[]) {
        const now = new Date().toISOString();
        const r = await this.client.execute({ sql: 'UPDATE form_templates SET title=?,sections_json=?,updated_at=? WHERE id=? AND owner=?', args: [safeName(title), JSON.stringify(sections), now, id, this.owner] });
        if (!r.rowsAffected)
            throw new ApiError(404, 'Form not found');
        return { id, title: safeName(title), sections, updatedAt: now };
    }

    // MARK: Filled forms
    /** A new draft of the template, or the latest draft when `reuseDraft` and one exists. */
    async createForm(documentId: string, templateId: string, title?: string | null, reuseDraft = false) {
        const id = randomUUID();
        const now = new Date().toISOString();
        const existing = reuseDraft ? "AND NOT EXISTS (SELECT 1 FROM filled_forms x WHERE x.document_id=t.document_id AND x.template_id=t.id AND x.status='draft')" : '';
        const r = await this.client.batch([
            { sql: `INSERT INTO filled_forms (id,owner,document_id,version_id,template_id,title,values_json,created_at,updated_at)
                SELECT ?,t.owner,t.document_id,t.version_id,t.id,COALESCE(?,'Form ' || (SELECT count(*)+1 FROM filled_forms x WHERE x.document_id=t.document_id)),'{}',?,?
                FROM form_templates t JOIN documents d ON d.id=t.document_id JOIN groups g ON g.id=d.group_id
                WHERE t.id=? AND t.document_id=? AND t.owner=? AND g.deleted_at IS NULL ${existing}`, args: [id, title ?? null, now, now, templateId, documentId, this.owner] },
            { sql: "SELECT id FROM filled_forms WHERE document_id=? AND template_id=? AND owner=? AND (id=? OR status='draft') ORDER BY id=? DESC, updated_at DESC LIMIT 1", args: [documentId, templateId, this.owner, id, id] },
        ], 'write');
        const created = r[1].rows[0];
        if (!created)
            throw new ApiError(404, 'Form not found');
        return this.form(String(created.id));
    }
    /** Autosave: one write that also checks the owner, the status, and that no other device got here first. */
    async saveValues(id: string, revision: number, values: Record<string, string | boolean | null>, title?: string) {
        const now = new Date().toISOString();
        const r = await this.client.execute({ sql: "UPDATE filled_forms SET values_json=?,title=COALESCE(?,title),revision=revision+1,updated_at=? WHERE id=? AND owner=? AND status='draft' AND revision=? RETURNING revision,updated_at,title", args: [JSON.stringify(values), title ?? null, now, id, this.owner, revision] });
        const row = r.rows[0];
        if (row)
            return { revision: Number(row.revision), updatedAt: String(row.updated_at), title: String(row.title) };
        const current = await this.client.execute({ sql: 'SELECT status FROM filled_forms WHERE id=? AND owner=?', args: [id, this.owner] });
        if (!current.rows[0])
            throw new ApiError(404, 'Form not found');
        throw new ApiError(409, current.rows[0].status === 'draft' ? 'This form changed on another device. Reopen it to continue.' : 'This form is with signing and can’t be edited. Remove it from the signing request first.');
    }
    /** The template and original PDF stay; only this filled copy and its signed PDF go. */
    async deleteForm(id: string) {
        const r = await this.client.batch([
            { sql: 'INSERT OR IGNORE INTO gc SELECT signed_storage_key FROM filled_forms WHERE id=? AND owner=? AND signed_storage_key IS NOT NULL', args: [id, this.owner] },
            { sql: 'DELETE FROM filled_forms WHERE id=? AND owner=?', args: [id, this.owner] },
            emptySigningRequests(this.owner),
        ], 'write');
        if (!r[1].rowsAffected)
            throw new ApiError(404, 'Form not found');
    }

    // MARK: Signing
    /** Everything the signing page needs, including what's required to render each PDF. */
    async signingRequests() {
        const r = await this.client.execute({ sql: `SELECT r.id, r.title, r.created_at,
            ${array(`${formJSON(true)} FROM ${formTables} JOIN groups g ON g.id=d.group_id WHERE f.signing_request_id=r.id AND f.owner=r.owner AND g.deleted_at IS NULL`, 'f.created_at')} forms_json
            FROM signing_requests r WHERE r.owner=? ORDER BY r.created_at DESC LIMIT 200`, args: [this.owner] });
        const requests = await Promise.all(r.rows.map(row => this.signingRequest(row)));
        return requests.filter(request => request.forms.length);
    }
    private async signingRequest(row: Row) {
        const forms = await Promise.all(parse<RawForm>(row.forms_json).map(linkForm));
        return { id: String(row.id), title: String(row.title), createdAt: String(row.created_at), status: forms.some(f => f.status !== 'signed') ? 'pending' : 'completed', forms };
    }
    /** Moves drafts into a new or existing request. Nothing moves unless all of them can. */
    async addToSigning(formIds: string[], requestId?: string | null, title?: string | null) {
        const marks = formIds.map(() => '?').join(',');
        const tx = await this.client.transaction('write');
        try {
            const names = await tx.execute({ sql: `SELECT f.id, f.status, d.name FROM filled_forms f JOIN documents d ON d.id=f.document_id WHERE f.owner=? AND f.id IN (${marks})`, args: [this.owner, ...formIds] });
            if (names.rows.length !== new Set(formIds).size)
                throw new ApiError(404, 'Form not found');
            if (names.rows.some(row => row.status !== 'draft'))
                throw new ApiError(409, 'Only filled forms that are not already in a signing request can be added');
            let id = requestId ?? null;
            if (id) {
                const existing = await tx.execute({ sql: 'SELECT id FROM signing_requests WHERE id=? AND owner=?', args: [id, this.owner] });
                if (!existing.rows[0])
                    throw new ApiError(404, 'Signing request not found');
            } else {
                id = randomUUID();
                const fallback = names.rows.length === 1 ? String(names.rows[0].name).replace(/\.pdf$/i, '') : `${names.rows.length} PDFs to sign`;
                await tx.execute({ sql: 'INSERT INTO signing_requests (id,owner,title,created_at) VALUES(?,?,?,?)', args: [id, this.owner, safeName(title ?? fallback), new Date().toISOString()] });
            }
            await tx.execute({ sql: `UPDATE filled_forms SET status='awaiting_signature',signing_request_id=?,updated_at=? WHERE owner=? AND status='draft' AND id IN (${marks})`, args: [id, new Date().toISOString(), this.owner, ...formIds] });
            await tx.commit();
            return id;
        } catch (e) {
            await tx.rollback();
            throw e;
        } finally {
            tx.close();
        }
    }
    /** Sends an unsigned form back to drafts, so it can be edited again. */
    async removeFromSigning(requestId: string, formId: string) {
        const r = await this.client.batch([
            { sql: "UPDATE filled_forms SET status='draft',signing_request_id=NULL,updated_at=? WHERE id=? AND owner=? AND signing_request_id=? AND status='awaiting_signature'", args: [new Date().toISOString(), formId, this.owner, requestId] },
            emptySigningRequests(this.owner),
        ], 'write');
        if (!r[0].rowsAffected)
            throw new ApiError(409, 'This form is not waiting for a signature in this request');
    }
    /** Unsigned forms go back to drafts; signed ones keep their signed PDF. */
    async deleteSigningRequest(id: string) {
        const r = await this.client.batch([
            { sql: "UPDATE filled_forms SET status=CASE status WHEN 'signed' THEN 'signed' ELSE 'draft' END,signing_request_id=NULL WHERE signing_request_id=? AND owner=?", args: [id, this.owner] },
            { sql: 'DELETE FROM signing_requests WHERE id=? AND owner=?', args: [id, this.owner] },
        ], 'write');
        if (!r[1].rowsAffected)
            throw new ApiError(404, 'Signing request not found');
    }
    async stageSignedUploads(requestId: string, items: { formId: string; size: number; uploadId: string; stagingKey: string }[]) {
        const marks = items.map(() => '?').join(',');
        const pending = await this.client.execute({ sql: `SELECT f.id, f.document_id, d.group_id FROM filled_forms f JOIN documents d ON d.id=f.document_id WHERE f.owner=? AND f.signing_request_id=? AND f.status='awaiting_signature' AND f.id IN (${marks})`, args: [this.owner, requestId, ...items.map(i => i.formId)] });
        const byForm = new Map(pending.rows.map(row => [String(row.id), row]));
        if (items.some(item => !byForm.has(item.formId)))
            throw new ApiError(409, 'A PDF in this request is no longer waiting for a signature');
        const expires = Date.now() + 86_400_000;
        await this.client.batch(items.map(item => ({ sql: 'INSERT INTO pdf_uploads (id,owner,group_id,name,size,staging_key,expires_at,target_form_id) VALUES(?,?,?,?,?,?,?,?)', args: [item.uploadId, this.owner, String(byForm.get(item.formId)!.group_id), 'signed.pdf', item.size, item.stagingKey, expires, item.formId] })), 'write');
    }
    /** The uploads to finish, leaving out forms a previous attempt already signed. */
    async pendingSignedUploads(requestId: string, items: { formId: string; uploadId: string }[]) {
        const marks = items.map(() => '?').join(',');
        const r = await this.client.execute({ sql: `SELECT f.id form_id, f.status, u.id upload_id, u.staging_key, u.size, u.expires_at FROM filled_forms f LEFT JOIN pdf_uploads u ON u.target_form_id=f.id AND u.owner=f.owner AND u.id IN (${marks}) WHERE f.owner=? AND f.signing_request_id=? AND f.id IN (${marks})`, args: [...items.map(i => i.uploadId), this.owner, requestId, ...items.map(i => i.formId)] });
        const rows = new Map(r.rows.map(row => [String(row.form_id), row]));
        const uploads: { formId: string; uploadId: string; stagingKey: string; size: number; }[] = [];
        for (const item of items) {
            const row = rows.get(item.formId);
            if (!row)
                throw new ApiError(404, 'A PDF in this request was not found');
            if (row.status === 'signed')
                continue;
            if (!row.upload_id)
                throw new ApiError(404, 'Upload not found. Sign again to retry.');
            if (Number(row.expires_at) < Date.now())
                throw new ApiError(410, 'Upload expired. Sign again to retry.');
            uploads.push({ formId: item.formId, uploadId: item.uploadId, stagingKey: String(row.staging_key), size: Number(row.size) });
        }
        return uploads;
    }
    /** Records every signature in one write, so a request is never left half recorded. */
    async markSigned(requestId: string, items: { formId: string; uploadId: string; key: string; size: number; method: string; stagingKey?: string }[]) {
        const now = new Date().toISOString();
        await this.client.batch(items.flatMap(item => [
            { sql: "UPDATE filled_forms SET status='signed',signed_storage_key=?,signed_size=?,signature_method=?,signed_at=?,updated_at=? WHERE id=? AND owner=? AND signing_request_id=? AND status='awaiting_signature'", args: [item.key, item.size, item.method, now, now, item.formId, this.owner, requestId] },
            ...(item.stagingKey ? [
                { sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [item.stagingKey] },
                { sql: 'DELETE FROM pdf_uploads WHERE id=? AND owner=?', args: [item.uploadId, this.owner] },
            ] : []),
        ]), 'write');
    }
    async signingContext(formId: string) {
        const r = await this.client.execute({ sql: "SELECT signing_request_id FROM filled_forms WHERE id=? AND owner=? AND status='awaiting_signature'", args: [formId, this.owner] });
        if (!r.rows[0])
            throw new ApiError(409, 'This form is not waiting for a signature');
        return String(r.rows[0].signing_request_id);
    }

    // MARK: Versions
    async versionKey(documentId: string, versionId: string) {
        const r = await this.client.execute({ sql: 'SELECT v.storage_key, v.name FROM document_versions v JOIN documents d ON d.id=v.document_id JOIN groups g ON g.id=d.group_id WHERE v.id=? AND v.document_id=? AND v.owner=? AND g.deleted_at IS NULL', args: [versionId, documentId, this.owner] });
        if (!r.rows[0])
            throw new ApiError(404, 'Version not found');
        return { key: String(r.rows[0].storage_key), name: String(r.rows[0].name) };
    }
    async stageVersionUpload(documentId: string, groupId: string, uploadId: string, name: string, size: number, stagingKey: string) {
        await this.client.execute({ sql: 'INSERT INTO pdf_uploads (id,owner,group_id,name,size,staging_key,expires_at,target_document_id) VALUES(?,?,?,?,?,?,?,?)', args: [uploadId, this.owner, groupId, safeName(name), size, stagingKey, Date.now() + 86_400_000, documentId] });
    }
    async stagedVersion(documentId: string, uploadId: string) {
        const r = await this.client.execute({ sql: 'SELECT u.*, (SELECT 1 FROM document_versions v WHERE v.id=u.id) already FROM pdf_uploads u WHERE u.id=? AND u.owner=? AND u.target_document_id=?', args: [uploadId, this.owner, documentId] });
        if (!r.rows[0])
            throw new ApiError(404, 'Upload not found');
        return r.rows[0];
    }
    /** Numbered inside the insert, so two uploads can't take the same number. */
    async addVersion(documentId: string, id: string, name: string, size: number, stagingKey?: string) {
        await this.client.batch([
            { sql: 'INSERT INTO document_versions (id,document_id,owner,number,name,storage_key,size,created_at) SELECT ?,d.id,d.owner,(SELECT COALESCE(MAX(x.number),0)+1 FROM document_versions x WHERE x.document_id=d.id),?,?,?,? FROM documents d WHERE d.id=? AND d.owner=? ON CONFLICT(id) DO NOTHING', args: [id, safeName(name), `${id}.pdf`, size, new Date().toISOString(), documentId, this.owner] },
            ...(stagingKey ? [
                { sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [stagingKey] },
                { sql: 'DELETE FROM pdf_uploads WHERE id=? AND owner=?', args: [id, this.owner] },
            ] : []),
        ], 'write');
    }
    /**
     * Each version keeps its own extraction, so going back costs no AI call. The caller extracts when
     * `needsExtraction`, which is the first time a version becomes current.
     */
    async setCurrentVersion(documentId: string, versionId: string) {
        const r = await this.client.batch([
            { sql: "UPDATE document_versions SET data_json=(SELECT d.data_json FROM documents d WHERE d.id=?),additional_json=(SELECT d.additional_json FROM documents d WHERE d.id=?) WHERE owner=? AND id=(SELECT d.current_version_id FROM documents d WHERE d.id=? AND d.owner=? AND d.status!='processing' AND d.current_version_id!=?)", args: [documentId, documentId, this.owner, documentId, this.owner, versionId] },
            { sql: "UPDATE documents SET current_version_id=v.id,storage_key=v.storage_key,size=v.size,data_json=v.data_json,additional_json=v.additional_json,error=NULL,status=CASE WHEN v.data_json IS NULL THEN 'uploaded' ELSE 'ready' END FROM document_versions v WHERE v.id=? AND v.document_id=documents.id AND documents.id=? AND documents.owner=? AND documents.status!='processing' RETURNING documents.status", args: [versionId, documentId, this.owner] },
        ], 'write');
        const row = r[1].rows[0];
        if (row)
            return { needsExtraction: row.status === 'uploaded' };
        const version = await this.client.execute({ sql: 'SELECT 1 FROM document_versions WHERE id=? AND document_id=? AND owner=?', args: [versionId, documentId, this.owner] });
        throw version.rows[0] ? new ApiError(409, 'Wait for processing to finish') : new ApiError(404, 'Version not found');
    }
    /** Filled and signed forms keep the version they were made from, so that version stays too. */
    async deleteVersion(documentId: string, versionId: string) {
        const removable = `SELECT v.id FROM document_versions v JOIN documents d ON d.id=v.document_id WHERE v.id=? AND v.document_id=? AND v.owner=? AND d.current_version_id!=v.id AND NOT EXISTS (SELECT 1 FROM filled_forms f WHERE f.version_id=v.id)`;
        const args = [versionId, documentId, this.owner];
        const r = await this.client.batch([
            { sql: `INSERT OR IGNORE INTO gc SELECT storage_key FROM document_versions WHERE id IN (${removable})`, args },
            { sql: `DELETE FROM form_templates WHERE version_id IN (${removable})`, args },
            { sql: `DELETE FROM document_versions WHERE id IN (${removable})`, args },
        ], 'write');
        if (!r[2].rowsAffected)
            throw new ApiError(409, 'This version is current or has filled forms, so it can’t be deleted');
    }
}
