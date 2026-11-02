import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { generateText } from 'ai';
import { processUploadedDocument } from '../lib/ai';
import { migrate } from '../lib/db';
import { Repository } from '../lib/repository';
vi.mock('ai', async original => ({ ...await original<typeof import('ai')>(), generateText: vi.fn() }));
vi.mock('../lib/storage', () => ({ getPDF: vi.fn(async () => new Uint8Array([1])) }));
const draft = { name: 'Invoices', instructions: 'Extract invoice details', namingTemplate: '{vendor}-{title}', schema: { type: 'object', properties: { vendor: { type: 'string' } }, required: ['vendor'], additionalProperties: false } };
let dir: string;
let client: Client;
let repo: Repository;
beforeEach(async () => { vi.stubEnv('AI_GATEWAY_API_KEY', 'test'); dir = mkdtempSync(join(tmpdir(), 'scanner-test-')); client = createClient({ url: 'file:' + join(dir, 'test.db') }); await migrate(client); repo = new Repository('alice', client); });
afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks(); client.close(); rmSync(dir, { recursive: true, force: true }); });
async function claimedUpload() {
    const group = await repo.createGroup(draft);
    const doc = await repo.addDocument(group.id, 'doc-a', 'Scan.pdf', 100);
    await repo.claimDocument(doc.id);
    return doc.id;
}
describe('automatic processing after upload', () => {
    it('fills the fields and renames the PDF from its content', async () => {
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
    it('records a failure instead of throwing, leaving the document retryable', async () => {
        vi.spyOn(console, 'error').mockImplementation(() => {});
        vi.mocked(generateText).mockRejectedValue(new Error('gateway down'));
        const id = await claimedUpload();
        await expect(processUploadedDocument(repo, id)).resolves.toBeUndefined();
        expect(await repo.document(id)).toMatchObject({ status: 'failed', name: 'Scan.pdf' });
        await expect(repo.claimDocument(id)).resolves.toBeUndefined();
    });
});
