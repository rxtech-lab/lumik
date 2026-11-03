import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { generateText } from 'ai';
import { chat, processUploadedDocument, suggestDocumentName, suggestDocumentGroup } from '../lib/ai';
import { migrate } from '../lib/db';
import { Repository } from '../lib/repository';
vi.mock('ai', async original => ({ ...await original<typeof import('ai')>(), generateText: vi.fn() }));
vi.mock('../lib/storage', () => ({ getPDF: vi.fn(async () => new Uint8Array([1])) }));
const draft = { name: 'Invoices', instructions: 'Extract invoice details', namingTemplate: '{vendor}-{title}', schema: { type: 'object', properties: { vendor: { type: 'string' } }, required: ['vendor'], additionalProperties: false } };
let dir: string;
let client: Client;
let repo: Repository;
beforeEach(async () => { vi.stubEnv('AI_GATEWAY_API_KEY', undefined); dir = mkdtempSync(join(tmpdir(), 'scanner-test-')); client = createClient({ url: 'file:' + join(dir, 'test.db') }); await migrate(client); repo = new Repository('alice', client); });
afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks(); client.close(); rmSync(dir, { recursive: true, force: true }); });
async function claimedUpload() {
    const group = await repo.createGroup(draft);
    const doc = await repo.addDocument(group.id, 'doc-a', 'Scan.pdf', 100);
    await repo.claimDocument(doc.id);
    return doc.id;
}
describe('Lumik and scans', () => {
    const systemPrompt = () => String(vi.mocked(generateText).mock.lastCall?.[0].system);
    it('tells Lumik about attached scans and what the Inbox holds', async () => {
        vi.mocked(generateText).mockResolvedValue({ text: 'ok', steps: [] } as never);
        const inbox = await repo.inbox();
        const attached = await repo.addDocument(inbox.id, 'scan-new', 'Scan.pdf', 100);
        await repo.complete(attached.id, 'attached-scan.pdf', { document_type: 'invoice', summary: 'From Acme', date: null });
        await repo.addDocument(inbox.id, 'scan-old', 'older.pdf', 100);
        await chat(repo, [{ role: 'user', content: 'Organize these scans.' }], { attachedDocumentIds: [attached.id, 'not-mine'] });
        expect(systemPrompt()).toContain('holds 2 unfiled documents');
        expect(systemPrompt()).toContain('older.pdf');
        const line = systemPrompt().split('\n').find(l => l.startsWith('The user attached'));
        expect(line).toContain('attached-scan.pdf');
        expect(line).toContain('From Acme');
        expect(line).not.toContain('older.pdf');
        expect(line).not.toContain('not-mine');
    });
    it('focuses on the groups the user chose and ignores ones that are not theirs', async () => {
        vi.mocked(generateText).mockResolvedValue({ text: 'ok', steps: [] } as never);
        const open = await repo.createGroup({ ...draft, name: 'Open group' });
        const added = await repo.createGroup({ ...draft, name: 'Added group' });
        const foreign = await new Repository('bob', client).createGroup({ ...draft, name: 'Foreign group' });
        await chat(repo, [{ role: 'user', content: 'hi' }], { groupId: open.id, groupIds: [open.id, added.id, foreign.id] });
        expect(systemPrompt()).toContain('has this group open');
        expect(systemPrompt().split('\n').find(l => l.startsWith('The user also added'))).toContain('Added group');
        expect(systemPrompt()).not.toContain('Foreign group');
    });
    it('keeps a removed group out even while one of its PDFs is open', async () => {
        vi.mocked(generateText).mockResolvedValue({ text: 'ok', steps: [] } as never);
        const group = await repo.createGroup(draft);
        const doc = await repo.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        await chat(repo, [{ role: 'user', content: 'hi' }], { documentId: doc.id, groupIds: [] });
        expect(systemPrompt()).toContain('is reading this PDF');
        expect(systemPrompt()).not.toContain('has this group open');
        await chat(repo, [{ role: 'user', content: 'hi' }], { groupIds: [] });
        expect(systemPrompt()).toContain('has not chosen a group');
    });
    it('offers the organize plan through propose_change, ignoring any review text from the model', async () => {
        vi.mocked(generateText).mockResolvedValue({ text: 'ok', steps: [] } as never);
        await chat(repo, [{ role: 'user', content: 'hello' }]);
        const tools = vi.mocked(generateText).mock.lastCall?.[0].tools as unknown as Record<string, { execute: (input: unknown, options: unknown) => Promise<{ mutation: { review: unknown } }> }>;
        const group = await repo.createGroup(draft);
        const doc = await repo.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        const proposal = await tools.propose_change.execute({ action: 'organize_documents', review: { moves: [{ document: 'forged' }] }, newGroups: [{ ref: 'sub', parent: group.id, name: 'Sub' }], moves: [{ documentId: doc.id, target: 'sub' }] }, {});
        expect(proposal.mutation.review).toEqual({ newGroups: [{ path: 'Invoices / Sub', fields: ['vendor'] }], moves: [{ document: 'a.pdf', from: 'Invoices', to: 'Invoices / Sub', reread: false }] });
    });
});
describe('automatic processing after upload', () => {
    it('fills fields and renames the PDF without an explicit Gateway API key', async () => {
        vi.mocked(generateText).mockResolvedValue({ output: { title: 'March invoice', fields: { vendor: 'Acme' } } } as never);
        const id = await claimedUpload();
        await processUploadedDocument(repo, id);
        expect(await repo.document(id)).toMatchObject({ status: 'ready', name: 'Acme-March invoice.pdf', originalName: 'Scan.pdf', data: { vendor: 'Acme' } });
    });
    it('follows the naming of previous documents in the group', async () => {
        const group = await repo.createGroup(draft);
        const previous = await repo.addDocument(group.id, 'doc-old', 'one.pdf', 100);
        await repo.complete(previous.id, '2026-03_Acme_Invoice.pdf', { vendor: 'Acme' });
        const unnamed = await repo.addDocument(group.id, 'doc-unnamed', 'Scan.pdf', 100);
        await repo.complete(unnamed.id, 'Scan.pdf', { vendor: 'Other' });
        const doc = await repo.addDocument(group.id, 'doc-new', 'Scan 2.pdf', 100);
        await repo.claimDocument(doc.id);
        vi.mocked(generateText).mockResolvedValue({ output: { title: '2026-04_Beta_Invoice', fields: { vendor: 'Beta' } } } as never);
        await processUploadedDocument(repo, doc.id);
        const prompt = JSON.stringify(vi.mocked(generateText).mock.lastCall?.[0].messages);
        expect(prompt).toContain('2026-03_Acme_Invoice.pdf');
        expect(prompt).not.toContain('Scan.pdf');
        expect((await repo.document(doc.id)).name).toBe('2026-04_Beta_Invoice.pdf');
    });
    it('suggests a name from the group naming without saving anything', async () => {
        const group = await repo.createGroup(draft);
        const previous = await repo.addDocument(group.id, 'doc-old', 'one.pdf', 100);
        await repo.complete(previous.id, '2026-03_Acme_Invoice.pdf', { vendor: 'Acme' });
        const doc = await repo.addDocument(group.id, 'doc-new', 'Scan.pdf', 100);
        vi.mocked(generateText).mockResolvedValue({ output: { name: '2026-04_Beta/Invoice' } } as never);
        expect(await suggestDocumentName(repo, doc.id)).toEqual({ name: '2026-04_Beta-Invoice.pdf' });
        expect(JSON.stringify(vi.mocked(generateText).mock.lastCall?.[0].messages)).toContain('2026-03_Acme_Invoice.pdf');
        expect(await repo.document(doc.id)).toMatchObject({ name: 'Scan.pdf', status: 'uploaded', data: null });
    });
    it('reads a moved PDF for its new group, using that group’s naming', async () => {
        const inbox = await repo.inbox();
        const group = await repo.createGroup(draft);
        const doc = await repo.addDocument(inbox.id, 'scan', 'Scan.pdf', 100);
        await repo.complete(doc.id, 'inbox-name.pdf', { document_type: 'invoice', summary: 'From Acme', date: null });
        expect((await repo.moveDocument(doc.id, group.id)).reread).toBe(true);
        vi.mocked(generateText).mockResolvedValue({ output: { title: 'March', fields: { vendor: 'Acme' } } } as never);
        await processUploadedDocument(repo, doc.id);
        expect(await repo.document(doc.id)).toMatchObject({ groupId: group.id, status: 'ready', name: 'Acme-March.pdf', data: { vendor: 'Acme' } });
    });
    it('records a failure instead of throwing, leaving the document retryable', async () => {
        vi.spyOn(console, 'error').mockImplementation(() => {});
        vi.mocked(generateText).mockRejectedValue(new Error('gateway down'));
        const id = await claimedUpload();
        await expect(processUploadedDocument(repo, id)).resolves.toBeUndefined();
        expect(await repo.document(id)).toMatchObject({ status: 'failed', name: 'Scan.pdf' });
        await expect(repo.claimDocument(id)).resolves.toBeUndefined();
    });
});

describe('PDF destination suggestions', () => {
    it('suggests an owned subgroup without moving the saved document', async () => {
        const id = await claimedUpload();
        await repo.complete(id, 'Acme.pdf', { vendor: 'Acme' });
        const original = await repo.document(id);
        const target = await repo.createGroup({ ...draft, name: 'Acme', parentId: original.groupId });
        vi.mocked(generateText).mockResolvedValue({ output: { groupId: target.id, reason: 'Acme invoices belong here.' } } as never);
        expect(await suggestDocumentGroup(repo, id)).toEqual({ suggestion: { groupId: target.id, reason: 'Acme invoices belong here.' } });
        expect((await repo.document(id)).groupId).toBe(original.groupId);
    });
    it('rejects foreign, invented, current and inbox destinations', async () => {
        const id = await claimedUpload();
        await repo.complete(id, 'Acme.pdf', { vendor: 'Acme' });
        const original = await repo.document(id);
        await repo.createGroup({ ...draft, name: 'Other' });
        const foreign = await new Repository('bob', client).createGroup(draft);
        const inbox = await repo.inbox();
        for (const groupId of [foreign.id, 'invented', original.groupId, inbox.id, null]) {
            vi.mocked(generateText).mockResolvedValue({ output: { groupId, reason: 'Match' } } as never);
            expect(await suggestDocumentGroup(repo, id)).toEqual({ suggestion: null });
        }
    });
});
