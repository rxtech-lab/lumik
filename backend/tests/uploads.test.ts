import { beforeEach, expect, it, vi } from 'vitest';
const mocks = vi.hoisted(() => ({ execute: vi.fn(), group: vi.fn(), presign: vi.fn(), promote: vi.fn(), add: vi.fn(), complete: vi.fn(), documents: vi.fn() }));
vi.mock('../lib/auth', () => ({ principal: async () => 'alice' }));
vi.mock('../lib/db', () => ({ db: () => ({ execute: mocks.execute }), expirePDFUploads: vi.fn() }));
vi.mock('../lib/repository', () => ({ Repository: class {
    complete = mocks.complete; documents = mocks.documents;
    owner = 'alice'; group = mocks.group; addDocument = mocks.add;
    async claimDocument() {}
    async document(id: string) { return { id, status: 'processing' }; }
}, purgeExpiredGroups: vi.fn() }));
vi.mock('../lib/storage', () => ({ presignPDF: mocks.presign, promoteUpload: mocks.promote, getPDF: vi.fn(), putPDF: vi.fn(), removePDF: vi.fn() }));
vi.mock('../lib/ai', () => ({ chat: vi.fn(), chatContext: vi.fn(), draftSchema: vi.fn(), processDocument: vi.fn(), processUploadedDocument: vi.fn() }));
vi.mock('next/server', () => ({ after: vi.fn() }));
import { POST } from '../app/api/v1/[...path]/route';
function request(path: string[], body = {}) {
    return POST(new Request('http://localhost/api/v1/' + path.join('/'), { method: 'POST', body: JSON.stringify(body) }), { params: Promise.resolve({ path }) });
}
beforeEach(() => { vi.resetAllMocks(); mocks.execute.mockResolvedValue({ rows: [] }); });
it('issues a private staging URL scoped to the authenticated owner and group', async () => {
    mocks.presign.mockResolvedValue('https://storage.test/signed');
    const response = await request(['groups', 'g', 'uploads'], { name: 'Scan.pdf', size: 6000000 });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ mode: 'direct', url: 'https://storage.test/signed' });
    expect(mocks.group).toHaveBeenCalledWith('g');
    expect(mocks.execute.mock.calls[0][0].args.slice(1, 5)).toEqual(['alice', 'g', 'Scan.pdf', 6000000]);
});
it('issues storage credentials for large PDFs', async () => {
    mocks.presign.mockResolvedValue('https://storage.test/signed');
    expect((await request(['groups', 'g', 'uploads'], { name: 'Scan.pdf', size: 2_000_000_000 })).status).toBe(200);
    expect(mocks.presign).toHaveBeenCalledWith(expect.any(String), 2_000_000_000);
});
it('rejects uploads too small to be a PDF before issuing storage credentials', async () => {
    expect((await request(['groups', 'g', 'uploads'], { name: 'Scan.pdf', size: 4 })).status).toBe(400);
    expect(mocks.presign).not.toHaveBeenCalled();
});
it('supports local disk without a presigned URL', async () => {
    mocks.presign.mockResolvedValue(null);
    expect(await (await request(['groups', 'g', 'uploads'], { name: 'Scan.pdf', size: 50 })).json()).toEqual({ mode: 'local' });
    expect(mocks.execute).not.toHaveBeenCalled();
});
it('does not finalize another owner or group upload', async () => {
    expect((await request(['groups', 'g', 'uploads', 'other', 'complete'])).status).toBe(404);
    expect(mocks.execute.mock.calls[0][0].args).toEqual(['other', 'alice', 'g']);
    expect(mocks.promote).not.toHaveBeenCalled();
});
it('rejects expired uploads before reading storage', async () => {
    mocks.execute.mockResolvedValueOnce({ rows: [{ expires_at: 1 }] });
    expect((await request(['groups', 'g', 'uploads', 'expired', 'complete'])).status).toBe(410);
    expect(mocks.promote).not.toHaveBeenCalled();
});

it('validates staged bytes before creating and processing a document', async () => {
    mocks.execute.mockResolvedValueOnce({ rows: [{ expires_at: Date.now() + 60000, staging_key: 'staged.pdf', size: 5, name: 'Scan.pdf' }] });
    expect((await request(['groups', 'g', 'uploads', 'id', 'complete'])).status).toBe(201);
    expect(mocks.promote).toHaveBeenCalledWith('staged.pdf', 'id.pdf', 5);
    expect(mocks.add).toHaveBeenCalledWith('g', 'id', 'Scan.pdf', 5);
});
it('completion retries reuse the existing document', async () => {
    mocks.execute.mockResolvedValueOnce({ rows: [{ expires_at: Date.now() + 60000 }] }).mockResolvedValueOnce({ rows: [{ id: 'id' }] });
    expect((await request(['groups', 'g', 'uploads', 'id', 'complete'])).status).toBe(200);
    expect(mocks.add).not.toHaveBeenCalled();
    expect(mocks.promote).not.toHaveBeenCalled();
});

it('saves local fields and naming without scheduling cloud AI', async () => {
    const { after } = await import('next/server');
    mocks.group.mockResolvedValue({ id: 'g', schema: { type: 'object', properties: { total: { type: 'number' } }, required: ['total'], additionalProperties: false }, namingTemplate: '{title}', extractAdditional: false });
    mocks.documents.mockResolvedValue([]);
    mocks.complete.mockResolvedValue({ id: 'id', status: 'ready' });
    mocks.execute.mockResolvedValueOnce({ rows: [{ expires_at: Date.now() + 60000, staging_key: 'staged.pdf', size: 5, name: 'Scan.pdf' }] });
    const response = await request(['groups', 'g', 'uploads', 'id', 'complete'], { processing: 'apple', result: { title: 'Receipt', fields: { total: 42 } } });
    expect(response.status).toBe(201);
    expect(mocks.complete).toHaveBeenCalledWith('id', 'Receipt.pdf', { total: 42 }, null);
    expect(after).not.toHaveBeenCalled();
});
it('rejects invalid local fields before promoting a PDF', async () => {
    mocks.group.mockResolvedValue({ schema: { type: 'object', properties: { total: { type: 'number' } }, required: ['total'] } });
    const response = await request(['groups', 'g', 'uploads', 'id', 'complete'], { processing: 'apple', result: { title: 'Receipt', fields: { total: 'invalid' } } });
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect(mocks.promote).not.toHaveBeenCalled();
    expect(mocks.add).not.toHaveBeenCalled();
});
