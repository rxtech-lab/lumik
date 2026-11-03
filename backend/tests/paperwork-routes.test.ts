import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ToolChoiceViolationError } from 'ai';
import { createClient, type Client } from '@libsql/client';
import { migrate } from '../lib/db';

const state = vi.hoisted(() => ({ client: undefined as unknown as Client, generateText: vi.fn(), after: vi.fn() }));
vi.mock('../lib/auth', () => ({ principal: async () => 'alice' }));
vi.mock('../lib/db', async original => ({ ...await original<typeof import('../lib/db')>(), db: () => state.client }));
vi.mock('next/server', () => ({ after: state.after }));
vi.mock('ai', async original => ({ ...await original<typeof import('ai')>(), generateText: state.generateText }));
import { DELETE, GET, PATCH, POST } from '../app/api/v1/[...path]/route';

const pdf = new TextEncoder().encode('%PDF-1.4 test');
const handlers = { GET, POST, PATCH, DELETE };
let dir: string;
function call(method: keyof typeof handlers, path: string, body?: unknown) {
    const parts = path.split('/');
    const init: RequestInit = { method };
    if (body instanceof FormData) init.body = body;
    else if (body !== undefined) init.body = JSON.stringify(body);
    return handlers[method](new Request(`http://localhost/api/v1/${path}`, init), { params: Promise.resolve({ path: parts }) });
}
async function ok<T = Record<string, any>>(response: Response | Promise<Response>) { // eslint-disable-line @typescript-eslint/no-explicit-any
    const r = await response;
    const json = await r.json();
    expect(r.status, JSON.stringify(json)).toBeLessThan(300);
    return json as T;
}
function upload(extra: Record<string, string> = {}) {
    const form = new FormData();
    form.set('file', new File([pdf], 'Lease.pdf', { type: 'application/pdf' }));
    for (const [key, value] of Object.entries(extra)) form.set(key, value);
    return form;
}
const widget = { name: 'tenant.name', kind: 'text', page: 0, x: 0.1, y: 0.1, w: 0.4, h: 0.03, options: [] };
async function makeDocument() {
    const group = await ok(call('POST', 'groups', { name: 'Leases', instructions: '', namingTemplate: '{title}', schema: { type: 'object', properties: {}, additionalProperties: false } }));
    const document = await ok(call('POST', `groups/${group.id}/documents`, upload()));
    await state.client.execute({ sql: "UPDATE documents SET status='ready' WHERE id=?", args: [document.id] });
    return { group, document };
}
beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'paperwork-test-'));
    vi.stubEnv('LOCAL_STORAGE_DIR', join(dir, 'files'));
    vi.stubEnv('NODE_ENV', 'test');
    state.client = createClient({ url: 'file:' + join(dir, 'test.db') });
    await migrate(state.client);
    state.generateText.mockReset();
    state.after.mockReset();
});
afterEach(() => { state.client.close(); rmSync(dir, { recursive: true, force: true }); vi.unstubAllEnvs(); });

it('opens the same saved form the second time without reading the PDF again', async () => {
    const { document } = await makeDocument();
    state.generateText.mockResolvedValueOnce({ output: { title: 'Lease form', sections: [{ title: 'Tenant', footer: null, fields: [{ label: 'Tenant name', type: 'text', required: true, help: null, ref: 'w1', placements: [], options: [] }] }] } });
    const first = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [widget] }));
    expect(first.template).toMatchObject({ title: 'Lease form', source: 'acroform' });
    expect(first.template.sections[0].fields[0]).toMatchObject({ label: 'Tenant name', widgets: ['tenant.name'], placements: [{ page: 0 }] });
    expect(first.form).toMatchObject({ status: 'draft', sections: first.template.sections, pdfPath: `documents/${document.id}/versions/${document.id}/pdf` });
    const calls = state.generateText.mock.calls.length;
    const second = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [widget] }));
    expect(state.generateText.mock.calls.length).toBe(calls);
    expect(second.template.id).toBe(first.template.id);
    expect(second.form.id).toBe(first.form.id);
    const regenerated = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [widget], regenerate: true }));
    expect(regenerated.template.id).not.toBe(first.template.id);
    expect(regenerated.form.id).not.toBe(first.form.id);
    expect(state.generateText.mock.calls.length).toBeGreaterThan(calls);
});

it('a PDF with its own fields still gets a form when the AI is down', async () => {
    const { document } = await makeDocument();
    state.generateText.mockRejectedValueOnce(new Error('gateway down'));
    const { template } = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [widget] }));
    expect(template.sections[0].fields[0]).toMatchObject({ label: 'Name', widgets: ['tenant.name'] });
});

it('a flat PDF reports a failed read and saves nothing, then a form with no blanks can be built by hand', async () => {
    const { document } = await makeDocument();
    state.generateText.mockRejectedValueOnce(new Error('gateway down'));
    expect((await call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [] })).status).toBe(502);
    expect((await ok(call('GET', `documents/${document.id}/workspace`))).templates).toEqual([]);
    state.generateText.mockResolvedValueOnce({ output: { title: 'Letter', sections: [] } });
    const { template } = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [] }));
    expect(template.sections).toEqual([]);
    const sections = [{ id: 's1', title: 'Details', fields: [{ id: 'f1', label: 'Name', type: 'text', placements: [{ page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.03 }] }] }];
    const saved = await ok(call('PATCH', `form-templates/${template.id}`, { title: 'Letter', sections }));
    expect(saved.sections[0].fields[0]).toMatchObject({ required: false, options: [], widgets: [] });
});

it('walks a form from filling to signed, keeping the original PDF', async () => {
    const { group, document } = await makeDocument();
    state.generateText.mockRejectedValueOnce(new Error('labels unavailable'));
    const { form } = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [widget] }));
    const saved = await ok(call('PATCH', `forms/${form.id}`, { revision: 0, values: { f1: 'Ada' } }));
    expect(saved.revision).toBe(1);
    expect((await call('PATCH', `forms/${form.id}`, { revision: 0, values: { f1: 'Stale' } })).status).toBe(409);
    const { id: requestId } = await ok(call('POST', 'signing-requests', { formIds: [form.id] }));
    expect((await call('PATCH', `forms/${form.id}`, { revision: 1, values: { f1: 'Too late' } })).status).toBe(409);
    expect(await ok(call('POST', `signing-requests/${requestId}/uploads`, { items: [{ formId: form.id, size: pdf.length }] }))).toEqual({ mode: 'local', uploads: [] });
    const signedFile = upload({ method: 'trackpad' });
    const { requests } = await ok(call('POST', `forms/${form.id}/sign`, signedFile));
    expect(requests[0]).toMatchObject({ status: 'completed', forms: [{ status: 'signed', signatureMethod: 'trackpad' }] });
    expect((await call('POST', `forms/${form.id}/sign`, upload({ method: 'drawn' }))).status).toBe(409);
    const signed = await call('GET', `forms/${form.id}/signed-pdf`);
    expect(signed.headers.get('Content-Type')).toBe('application/pdf');
    expect(new Uint8Array(await signed.arrayBuffer())).toEqual(pdf);
    const overview = await ok(call('GET', `groups/${group.id}/overview`));
    expect(overview.forms).toMatchObject([{ status: 'signed', signedPdfPath: `forms/${form.id}/signed-pdf` }]);
    expect(overview.forms[0]).not.toHaveProperty('signedKey');
    expect((await ok(call('GET', `documents/${document.id}/workspace`))).versions[0].size).toBe(pdf.length);
});

it('uploads a version, reads it the first time it becomes current, and serves each version', async () => {
    const { document } = await makeDocument();
    const before = state.after.mock.calls.length;
    const kept = await ok(call('POST', `documents/${document.id}/versions`, upload({ makeCurrent: 'false' })));
    expect(kept.versions.map((v: { number: number; isCurrent: boolean }) => [v.number, v.isCurrent])).toEqual([[2, false], [1, true]]);
    expect(state.after.mock.calls.length).toBe(before);
    const second = kept.versions[0].id;
    const switched = await ok(call('POST', `documents/${document.id}/versions/${second}/current`));
    expect(switched.versions[0].isCurrent).toBe(true);
    expect(switched.document.status).toBe('processing');
    expect(state.after.mock.calls.length).toBe(before + 1);
    expect((await call('GET', `documents/${document.id}/versions/${second}/pdf`)).status).toBe(200);
    expect((await call('GET', `documents/${document.id}/versions/nope/pdf`)).status).toBe(404);
    expect((await call('POST', `documents/${document.id}/versions/${document.id}/current`)).status).toBe(409);
});

it('validates input before doing any work', async () => {
    const { document } = await makeDocument();
    state.generateText.mockClear();
    expect((await call('POST', `documents/${document.id}/form-template`, { widgets: [] })).status).toBe(400);
    expect((await call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [{ ...widget, x: 7 }] })).status).toBe(400);
    expect((await call('PATCH', 'forms/x', { revision: 0, values: { f1: { nested: true } } })).status).toBe(400);
    expect((await call('POST', 'signing-requests', { formIds: [] })).status).toBe(400);
    expect(state.generateText).not.toHaveBeenCalled();
});


it('continues unfinished generation until the finish tool runs without a step cap', async () => {
    const { document } = await makeDocument();
    const section = { title: 'Tenant', footer: null, fields: [{ label: 'Name', type: 'text', required: false, help: null, ref: null, placements: [{ page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.03 }], options: [] }] };
    let firstSignal: AbortSignal;
    state.generateText.mockImplementationOnce(async options => {
        firstSignal = options.abortSignal;
        expect(options.toolChoice).toBe('required');
        await options.tools.write_section.execute(section);
        // More than the old 24-step cap still must not terminate the run.
        for (let step = 0; step < 30; step++) {
            options.onStepFinish({ toolCalls: [], toolResults: [], finishReason: 'tool-calls' });
            expect(options.stopWhen({ steps: Array(step + 1).fill({}) })).toBe(false);
        }
        return {};
    }).mockImplementationOnce(async options => {
        expect(options.abortSignal).toBe(firstSignal);
        expect(options.messages[0].content[1].text).toContain('Tenant');
        await options.tools.finish.execute({ title: 'Completed lease' });
        expect(options.stopWhen({ steps: [] })).toBe(true);
        return {};
    });
    const { template } = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [] }));
    expect(template.title).toBe('Completed lease');
    expect(template.sections).toHaveLength(1);
    expect(state.generateText).toHaveBeenCalledTimes(2);
});


it('recovers a missing tool call and finalizes the saved draft', async () => {
    const { document } = await makeDocument();
    let originalSignal: AbortSignal;
    state.generateText.mockImplementationOnce(async options => {
        originalSignal = options.abortSignal;
        await options.tools.write_section.execute({ title: 'Tenant', footer: null, fields: [{ label: 'Name', type: 'text', required: false, help: null, ref: null, placements: [{ page: 0, x: 0.1, y: 0.1, w: 0.3, h: 0.03 }], options: [] }] });
        throw new ToolChoiceViolationError({ toolChoice: { type: 'required' }, finishReason: 'other', provider: 'gateway', modelId: 'test', content: [] });
    }).mockImplementationOnce(async options => {
        expect(options.abortSignal).toBe(originalSignal);
        expect(options.messages[0].content[1].text).toContain('Tenant');
        await options.tools.finish.execute({ title: 'Recovered form' });
        return {};
    });
    const { template } = await ok(call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [] }));
    expect(template.title).toBe('Recovered form');
    expect(template.sections).toHaveLength(1);
    expect(state.generateText).toHaveBeenCalledTimes(2);
});

it('bounds missing tool call recovery and reports resumable progress', async () => {
    const { document } = await makeDocument();
    state.generateText.mockRejectedValue(new ToolChoiceViolationError({ toolChoice: { type: 'required' }, finishReason: 'other', provider: 'gateway', modelId: 'test', content: [] }));
    const response = await call('POST', `documents/${document.id}/form-template`, { pageCount: 1, widgets: [] });
    expect(response.status).toBe(502);
    expect(await response.text()).toContain('retry to resume');
    expect(state.generateText).toHaveBeenCalledTimes(3);
    expect((await ok(call('GET', `documents/${document.id}/workspace`))).templates).toEqual([]);
});
