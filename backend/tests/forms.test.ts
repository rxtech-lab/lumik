import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { migrate } from '../lib/db';
import { Forms } from '../lib/forms';
import { Repository } from '../lib/repository';
import { groupWidgets, sectionsFromDraft, sectionsFromWidgets } from '../lib/form-template';
import { templateEdit, type FormSection, type PDFWidget } from '../lib/contracts';

vi.mock('../lib/storage', () => ({ presignDownload: async (key: string) => `https://storage.test/${key}` }));
let dir: string;
let client: Client;
let repo: Repository;
let forms: Forms;
let other: Forms;
const schema = { type: 'object', properties: { vendor: { type: 'string' } }, required: ['vendor'], additionalProperties: false };
const sections: FormSection[] = [{ id: 's1', title: 'Details', footer: null, fields: [{ id: 'f1', label: 'Name', type: 'text', required: true, placements: [{ page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.03 }], options: [], widgets: [] }] }];
async function setup() {
    const group = await repo.createGroup({ name: 'Contracts', instructions: '', namingTemplate: '{title}', schema });
    await repo.addDocument(group.id, '11111111-1111-4111-8111-111111111111', 'Lease.pdf', 100);
    const documentId = '11111111-1111-4111-8111-111111111111';
    const template = await forms.saveTemplate(documentId, documentId, 'Lease', 'ai', sections);
    return { group, documentId, template };
}
/** Counts statements, since "one database call" is the promise these reads make. */
function counting(target: Client) {
    let calls = 0;
    const wrapped = new Proxy(target, { get(t, key) {
        const value = Reflect.get(t, key);
        if (key === 'execute' || key === 'batch')
            return (...args: unknown[]) => { calls++; return (value as (...a: unknown[]) => unknown).apply(t, args); };
        return typeof value === 'function' ? value.bind(t) : value;
    } });
    return { client: wrapped, calls: () => calls };
}
beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'forms-test-'));
    client = createClient({ url: 'file:' + join(dir, 'test.db') });
    await migrate(client);
    repo = new Repository('alice', client);
    forms = new Forms('alice', client);
    other = new Forms('bob', client);
});
afterEach(() => { client.close(); rmSync(dir, { recursive: true, force: true }); });

describe('reads', () => {
    it('reads the whole PDF page in one database call', async () => {
        const { documentId, template } = await setup();
        await forms.createForm(documentId, template.id);
        await client.batch([{ sql: "INSERT INTO group_views (id,group_id,owner,kind,title,spec_json,queries_json,created_at) SELECT 'v1',group_id,owner,'statistic','T','{}','{}','now' FROM documents WHERE id=?", args: [documentId] }], 'write');
        const counter = counting(client);
        const workspace = await new Forms('alice', counter.client).workspace(documentId);
        expect(counter.calls()).toBe(1);
        expect(workspace.document).not.toHaveProperty('storageKey');
        expect(workspace.versions).toMatchObject([{ number: 1, isCurrent: true, pdfUrl: `https://storage.test/${documentId}.pdf` }]);
        expect(workspace.versions[0]).not.toHaveProperty('storageKey');
        expect(workspace.templates).toMatchObject([{ title: 'Lease', sections: [{ title: 'Details' }] }]);
        expect(workspace.forms).toMatchObject([{ title: 'Form 1', status: 'draft', documentName: 'Lease.pdf', versionNumber: 1, values: {} }]);
        expect(workspace.forms[0]).not.toHaveProperty('versionKey');
    });
    it('reads the whole group page in one database call', async () => {
        const { group, documentId, template } = await setup();
        await forms.createForm(documentId, template.id);
        const counter = counting(client);
        const overview = await new Forms('alice', counter.client).overview(group.id);
        expect(counter.calls()).toBe(1);
        expect(overview.documents).toMatchObject([{ id: documentId, name: 'Lease.pdf', data: null, additional: null }]);
        expect(overview.documents[0]).not.toHaveProperty('storageKey');
        expect(overview.forms).toHaveLength(1);
        expect(overview.views).toEqual([]);
    });
    it('reads one group or its documents in a single statement, and still reports a missing group', async () => {
        const { group } = await setup();
        const counter = counting(client);
        const scoped = new Repository('alice', counter.client);
        expect((await scoped.group(group.id)).documentCount).toBe(1);
        expect(counter.calls()).toBe(1);
        expect(await scoped.documents(group.id)).toHaveLength(1);
        expect(counter.calls()).toBe(2);
        const empty = await repo.createGroup({ name: 'Empty', instructions: '', namingTemplate: '{title}', schema });
        expect(await repo.documents(empty.id)).toEqual([]);
        await expect(new Repository('bob', client).documents(group.id)).rejects.toMatchObject({ status: 404 });
    });
    it('keeps every read and write inside the account', async () => {
        const { group, documentId, template } = await setup();
        const form = await forms.createForm(documentId, template.id);
        await expect(other.workspace(documentId)).rejects.toMatchObject({ status: 404 });
        await expect(other.overview(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(other.form(form.id as string)).rejects.toMatchObject({ status: 404 });
        await expect(other.createForm(documentId, template.id)).rejects.toMatchObject({ status: 404 });
        await expect(other.saveValues(form.id as string, 0, { f1: 'x' })).rejects.toMatchObject({ status: 404 });
        await expect(other.updateTemplate(template.id, 'x', sections)).rejects.toMatchObject({ status: 404 });
        await expect(other.addToSigning([form.id as string])).rejects.toMatchObject({ status: 404 });
        await expect(other.deleteForm(form.id as string)).rejects.toMatchObject({ status: 404 });
        await expect(other.setCurrentVersion(documentId, documentId)).rejects.toMatchObject({ status: 404 });
        await expect(other.deleteVersion(documentId, documentId)).rejects.toMatchObject({ status: 409 });
        expect((await forms.workspace(documentId)).forms).toHaveLength(1);
    });
});

describe('filled forms', () => {
    it('keeps several filled copies of one form and leaves the template alone', async () => {
        const { documentId, template } = await setup();
        await forms.createForm(documentId, template.id);
        await forms.createForm(documentId, template.id, 'For landlord');
        const { forms: list, templates } = await forms.workspace(documentId);
        expect(list.map(f => f.title).sort()).toEqual(['For landlord', 'Form 1']);
        expect(templates).toHaveLength(1);
    });
    it('reuses a draft when asked, so opening the form twice does not pile up copies', async () => {
        const { documentId, template } = await setup();
        const first = await forms.createForm(documentId, template.id, null, true);
        const again = await forms.createForm(documentId, template.id, null, true);
        expect(again.id).toBe(first.id);
        expect((await forms.workspace(documentId)).forms).toHaveLength(1);
    });
    it('autosaves with a revision check, in one write', async () => {
        const { documentId, template } = await setup();
        const form = await forms.createForm(documentId, template.id);
        const counter = counting(client);
        const saved = await new Forms('alice', counter.client).saveValues(form.id as string, 0, { f1: 'Ada' });
        expect(counter.calls()).toBe(1);
        expect(saved.revision).toBe(1);
        await expect(forms.saveValues(form.id as string, 0, { f1: 'Stale' })).rejects.toMatchObject({ status: 409 });
        expect((await forms.form(form.id as string)).values).toEqual({ f1: 'Ada' });
    });
    it('deleting a filled copy queues its signed PDF and keeps the original', async () => {
        const { documentId, template } = await setup();
        const form = await forms.createForm(documentId, template.id);
        const requestId = await forms.addToSigning([form.id as string]);
        await forms.markSigned(requestId, [{ formId: form.id as string, uploadId: 'u', key: 'aaaa.pdf', size: 9, method: 'typed' }]);
        await forms.deleteForm(form.id as string);
        const gc = await client.execute('SELECT storage_key FROM gc');
        expect(gc.rows.map(r => r.storage_key)).toEqual(['aaaa.pdf']);
        expect((await forms.workspace(documentId)).versions).toHaveLength(1);
        expect(await forms.signingRequests()).toEqual([]);
        expect((await client.execute('SELECT * FROM signing_requests')).rows).toHaveLength(0);
    });
});

describe('signing', () => {
    it('signs several PDFs from one request, then freezes them', async () => {
        const { documentId, template } = await setup();
        const a = await forms.createForm(documentId, template.id, 'A');
        const b = await forms.createForm(documentId, template.id, 'B');
        const requestId = await forms.addToSigning([a.id as string, b.id as string]);
        let [request] = await forms.signingRequests();
        expect(request).toMatchObject({ id: requestId, title: '2 PDFs to sign', status: 'pending' });
        expect(request.forms[0]).toMatchObject({ status: 'awaiting_signature', sections, pdfUrl: `https://storage.test/${documentId}.pdf`, signedPdfUrl: null });
        await expect(forms.saveValues(a.id as string, 0, { f1: 'x' })).rejects.toMatchObject({ status: 409 });
        await forms.markSigned(requestId, [
            { formId: a.id as string, uploadId: 'ua', key: 'a.pdf', size: 5, method: 'drawn' },
            { formId: b.id as string, uploadId: 'ub', key: 'b.pdf', size: 5, method: 'trackpad' },
        ]);
        [request] = await forms.signingRequests();
        expect(request.status).toBe('completed');
        expect(request.forms.map(f => f.signatureMethod)).toEqual(['drawn', 'trackpad']);
        expect(request.forms[0].signedPdfUrl).toBe('https://storage.test/a.pdf');
        expect((await forms.signedFile(a.id as string)).key).toBe('a.pdf');
    });
    it('moves nothing unless every form can move', async () => {
        const { documentId, template } = await setup();
        const a = await forms.createForm(documentId, template.id);
        const b = await forms.createForm(documentId, template.id);
        await forms.addToSigning([a.id as string]);
        await expect(forms.addToSigning([a.id as string, b.id as string])).rejects.toMatchObject({ status: 409 });
        expect((await forms.form(b.id as string)).status).toBe('draft');
        expect((await forms.signingRequests())).toHaveLength(1);
    });
    it('returns unsigned forms to drafts and removes an empty request', async () => {
        const { documentId, template } = await setup();
        const a = await forms.createForm(documentId, template.id);
        const requestId = await forms.addToSigning([a.id as string], null, 'Lease');
        await forms.removeFromSigning(requestId, a.id as string);
        expect((await forms.form(a.id as string)).status).toBe('draft');
        expect(await forms.signingRequests()).toEqual([]);
        await forms.saveValues(a.id as string, 0, { f1: 'Editable again' });
    });
    it('deleting a request keeps signed PDFs and frees the rest', async () => {
        const { documentId, template } = await setup();
        const a = await forms.createForm(documentId, template.id);
        const b = await forms.createForm(documentId, template.id);
        const requestId = await forms.addToSigning([a.id as string, b.id as string]);
        await forms.markSigned(requestId, [{ formId: a.id as string, uploadId: 'u', key: 'a.pdf', size: 5, method: 'typed' }]);
        await forms.deleteSigningRequest(requestId);
        expect((await forms.form(a.id as string))).toMatchObject({ status: 'signed', signedPdfPath: `forms/${a.id}/signed-pdf` });
        expect((await forms.form(b.id as string)).status).toBe('draft');
    });
});

describe('versions', () => {
    const second = '22222222-2222-4222-8222-222222222222';
    it('numbers versions and switches the current one without touching older files', async () => {
        const { documentId } = await setup();
        await repo.complete(documentId, 'Lease.pdf', { vendor: 'Original' });
        await forms.addVersion(documentId, second, 'Lease v2.pdf', 200);
        expect((await repo.document(documentId)).storageKey).toBe(`${documentId}.pdf`);
        expect(await forms.setCurrentVersion(documentId, second)).toEqual({ needsExtraction: true });
        const current = await repo.document(documentId);
        expect(current).toMatchObject({ storageKey: `${second}.pdf`, size: 200, status: 'uploaded', data: null });
        const { versions } = await forms.workspace(documentId);
        expect(versions.map(v => [v.number, v.isCurrent])).toEqual([[2, true], [1, false]]);
    });
    it('going back restores that version’s extraction without another AI call', async () => {
        const { documentId } = await setup();
        await repo.complete(documentId, 'Lease.pdf', { vendor: 'Original' });
        await forms.addVersion(documentId, second, 'v2.pdf', 200);
        await forms.setCurrentVersion(documentId, second);
        await repo.complete(documentId, 'Lease.pdf', { vendor: 'Second' });
        expect(await forms.setCurrentVersion(documentId, documentId)).toEqual({ needsExtraction: false });
        expect(await repo.document(documentId)).toMatchObject({ status: 'ready', data: { vendor: 'Original' }, storageKey: `${documentId}.pdf`, size: 100 });
        expect(await forms.setCurrentVersion(documentId, second)).toEqual({ needsExtraction: false });
        expect((await repo.document(documentId)).data).toEqual({ vendor: 'Second' });
    });
    it('filled forms stay on their version, and that version can’t be deleted', async () => {
        const { documentId, template } = await setup();
        const form = await forms.createForm(documentId, template.id);
        await forms.addVersion(documentId, second, 'v2.pdf', 200);
        await forms.setCurrentVersion(documentId, second);
        expect((await forms.form(form.id as string))).toMatchObject({ versionId: documentId, versionNumber: 1, pdfUrl: `https://storage.test/${documentId}.pdf` });
        await expect(forms.deleteVersion(documentId, documentId)).rejects.toMatchObject({ status: 409 });
        await expect(forms.deleteVersion(documentId, second)).rejects.toMatchObject({ status: 409 });
    });
    it('deleting an unused version queues only its file', async () => {
        const { documentId } = await setup();
        await forms.addVersion(documentId, second, 'v2.pdf', 200);
        await forms.deleteVersion(documentId, second);
        const gc = await client.execute('SELECT storage_key FROM gc');
        expect(gc.rows.map(r => r.storage_key)).toEqual([`${second}.pdf`]);
        expect((await forms.workspace(documentId)).versions).toHaveLength(1);
    });
    it('refuses to switch while the document is being read', async () => {
        const { documentId } = await setup();
        await forms.addVersion(documentId, second, 'v2.pdf', 200);
        await repo.claimDocument(documentId);
        await expect(forms.setCurrentVersion(documentId, second)).rejects.toMatchObject({ status: 409 });
    });
    it('deleting the document removes every version, form, and signed PDF', async () => {
        const { documentId, template } = await setup();
        const form = await forms.createForm(documentId, template.id);
        const requestId = await forms.addToSigning([form.id as string]);
        await forms.markSigned(requestId, [{ formId: form.id as string, uploadId: 'u', key: 'signed.pdf', size: 5, method: 'drawn' }]);
        await forms.addVersion(documentId, second, 'v2.pdf', 200);
        await repo.deleteDocument(documentId);
        const gc = (await client.execute('SELECT storage_key FROM gc')).rows.map(r => r.storage_key).sort();
        expect(gc).toEqual([`${documentId}.pdf`, `${second}.pdf`, 'signed.pdf'].sort());
        for (const table of ['document_versions', 'form_templates', 'filled_forms', 'signing_requests'])
            expect((await client.execute(`SELECT 1 FROM ${table}`)).rows).toHaveLength(0);
    });
    it('backfills existing documents as version 1 when migrating', async () => {
        await client.batch([
            { sql: "INSERT INTO groups (id,owner,name,instructions,naming_template,schema_json,created_at) VALUES('g','alice','G','','{title}','{}','2026')", args: [] },
            { sql: "INSERT INTO documents (id,group_id,owner,name,original_name,storage_key,size,status,created_at) VALUES('old','g','alice','Old.pdf','Scan.pdf','old.pdf',7,'ready','2026')", args: [] },
        ], 'write');
        await migrate(client);
        await migrate(client);
        expect((await forms.workspace('old')).versions).toMatchObject([{ id: 'old', number: 1, name: 'Scan.pdf', size: 7, isCurrent: true }]);
    });
});

describe('building a form from a PDF', () => {
    const widget = (name: string, extra: Partial<PDFWidget> = {}): PDFWidget => ({ name, kind: 'text', page: 0, x: 0.1, y: 0.1, w: 0.2, h: 0.03, options: [], ...extra });
    it('merges repeated names and turns radio widgets into options', () => {
        const logical = groupWidgets([
            widget('applicant.fullName'), widget('applicant.fullName', { page: 1 }),
            widget('plan', { kind: 'radio', onState: 'Basic', x: 0.5 }), widget('plan', { kind: 'radio', onState: 'Pro', x: 0.6 }),
            widget('agree', { kind: 'checkbox', onState: 'Yes', value: 'Yes' }),
        ]);
        expect(logical).toHaveLength(3);
        expect(logical[0].field).toMatchObject({ label: 'Full Name', type: 'text', widgets: ['applicant.fullName'] });
        expect(logical[0].field.placements).toHaveLength(2);
        expect(logical[1].field).toMatchObject({ type: 'choice', placements: [] });
        expect(logical[1].field.options.map(o => [o.value, o.placements.length])).toEqual([['Basic', 1], ['Pro', 1]]);
        expect(logical[2].field).toMatchObject({ type: 'checkbox', defaultValue: true });
    });
    it('uses AI wording but never loses a PDF field', () => {
        const logical = groupWidgets([widget('a'), widget('b', { page: 1 })]);
        const built = sectionsFromDraft({ title: 'T', sections: [{ title: 'You', footer: null, fields: [
            { label: 'Your name', type: 'date', required: true, help: null, ref: 'w1', placements: [], options: [] },
            { label: 'Invented', type: 'text', required: false, help: null, ref: 'w99', placements: [], options: [] },
        ] }] }, logical, 2);
        expect(built.map(s => s.title)).toEqual(['You', 'More fields']);
        expect(built[0].fields).toMatchObject([{ label: 'Your name', type: 'date', required: true, widgets: ['a'] }]);
        expect(built[1].fields).toMatchObject([{ widgets: ['b'] }]);
    });
    it('clamps AI boxes to the page and drops fields that land nowhere', () => {
        const built = sectionsFromDraft({ title: 'T', sections: [{ title: 'S', footer: null, fields: [
            { label: 'Good', type: 'text', required: false, help: null, ref: null, placements: [{ page: 0, x: 0.9, y: -1, w: 5, h: 0.1 }], options: [] },
            { label: 'Off the end', type: 'text', required: false, help: null, ref: null, placements: [{ page: 7, x: 0, y: 0, w: 0.1, h: 0.1 }], options: [] },
        ] }] }, [], 1);
        expect(built[0].fields).toHaveLength(1);
        expect(built[0].fields[0].placements[0]).toMatchObject({ x: 0.9, y: 0 });
        expect(built[0].fields[0].placements[0].w).toBeCloseTo(0.1);
    });
    it('falls back to reading order by page without the AI', () => {
        const built = sectionsFromWidgets(groupWidgets([widget('later', { y: 0.5 }), widget('first', { y: 0.2 }), widget('next', { page: 1 })]));
        expect(built.map(s => [s.title, s.fields.map(f => f.widgets[0])])).toEqual([['Page 1', ['first', 'later']], ['Page 2', ['next']]]);
    });
});

describe('generation checkpoints', () => {
    it('resumes across service instances, isolates owners, and clears completed work', async () => {
        const draft = { title: 'Draft', sections: [{ title: 'Names', fields: [] }] };
        await forms.saveGenerationCheckpoint('version-a', draft);
        expect(await new Forms('alice', client).generationCheckpoint('version-a')).toEqual(draft);
        expect(await other.generationCheckpoint('version-a')).toBeNull();
        expect(await forms.generationCheckpoint('version-b')).toBeNull();
        await forms.clearGenerationCheckpoint('version-a');
        expect(await forms.generationCheckpoint('version-a')).toBeNull();
    });
});

it('stores positions moved by hand so a form can be fine-tuned', async () => {
    const { template } = await setup();
    const moved = { page: 0, x: 0.2, y: 0.3, w: 0.05, h: 0.02, manual: true, part: 'day' };
    const edit = templateEdit.parse({ title: 'Lease', sections: [{ ...sections[0], fields: [{ ...sections[0].fields[0], placements: [moved] }] }] });
    await forms.updateTemplate(template.id, edit.title, edit.sections);
    const row = await client.execute({ sql: 'SELECT sections_json FROM form_templates WHERE id=?', args: [template.id] });
    expect(JSON.parse(String(row.rows[0].sections_json))[0].fields[0].placements).toEqual([moved]);
});
