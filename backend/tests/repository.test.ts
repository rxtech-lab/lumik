import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beforeEach, afterEach, describe, expect, it } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { migrate } from '../lib/db';
import { purgeExpiredGroups, Repository } from '../lib/repository';
import { pdfName, validateSchema, validateData } from '../lib/contracts';
let dir: string;
let client: Client;
let alice: Repository;
let bob: Repository;
const draft = { name: 'Invoices', instructions: 'Extract invoice details', namingTemplate: '{vendor}-{title}', schema: { type: 'object', properties: { vendor: { type: 'string' }, total: { type: 'number' } }, required: ['vendor', 'total'], additionalProperties: false } };
beforeEach(async () => { dir = mkdtempSync(join(tmpdir(), 'scanner-test-')); client = createClient({ url: 'file:' + join(dir, 'test.db') }); await migrate(client); alice = new Repository('alice', client); bob = new Repository('bob', client); });
afterEach(() => { client.close(); rmSync(dir, { recursive: true, force: true }); });
describe('tenant isolation and document lifecycle', () => {
    it('never exposes another owner’s groups or documents', async () => {
        const group = await alice.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'original.pdf', 100);
        expect(await bob.groups()).toEqual([]);
        await expect(bob.group(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.documents(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.document(doc.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.deleteGroup(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.editDocument(doc.id, 'changed.pdf', { vendor: 'X', total: 1 })).rejects.toMatchObject({ status: 404 });
        expect((await alice.documents(group.id)).length).toBe(1);
    });
    it('rejects invalid extracted data and concurrent processing', async () => {
        const group = await alice.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        await expect(alice.editDocument(doc.id, 'bad.pdf', { vendor: 'A', total: 'not a number' })).rejects.toMatchObject({ status: 422 });
        await alice.claimDocument(doc.id);
        await expect(alice.claimDocument(doc.id)).rejects.toMatchObject({ status: 409 });
        await alice.fail(doc.id);
        await alice.claimDocument(doc.id);
        await alice.complete(doc.id, 'renamed.pdf', { vendor: 'A', total: 42 });
        expect((await alice.document(doc.id)).status).toBe('ready');
    });
    it('hides a deleted group and keeps its PDFs until restored', async () => {
        const group = await alice.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        await alice.deleteGroup(group.id);
        expect(await alice.groups()).toEqual([]);
        await expect(alice.group(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(alice.document(doc.id)).rejects.toMatchObject({ status: 404 });
        await expect(alice.addDocument(group.id, 'doc-b', 'b.pdf', 100)).rejects.toMatchObject({ status: 404 });
        expect((await alice.sandboxData()).documents).toEqual([]);
        expect((await client.execute('SELECT * FROM gc')).rows).toHaveLength(0);
        const [deleted] = await alice.deletedGroups();
        expect(deleted).toMatchObject({ id: group.id, documentCount: 1 });
        expect(new Date(deleted.purgeAt).getTime() - new Date(deleted.deletedAt).getTime()).toBe(30 * 24 * 60 * 60 * 1000);
        expect(await alice.restoreGroup(group.id)).toMatchObject({ id: group.id, documentCount: 1 });
        expect(await alice.deletedGroups()).toEqual([]);
        expect((await alice.document(doc.id)).id).toBe(doc.id);
    });
    it('keeps the Recycle Bin private to its owner', async () => {
        const group = await alice.createGroup(draft);
        await alice.deleteGroup(group.id);
        expect(await bob.deletedGroups()).toEqual([]);
        await expect(bob.restoreGroup(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.purgeGroup(group.id)).rejects.toMatchObject({ status: 404 });
        expect(await alice.deletedGroups()).toHaveLength(1);
    });
    it('refuses to restore or purge a group that is not in the Recycle Bin', async () => {
        const group = await alice.createGroup(draft);
        await expect(alice.restoreGroup(group.id)).rejects.toMatchObject({ status: 404 });
        await expect(alice.purgeGroup(group.id)).rejects.toMatchObject({ status: 404 });
        expect(await alice.groups()).toHaveLength(1);
    });
    it('purges only groups deleted at least 30 days ago', async () => {
        const expired = await alice.createGroup(draft);
        const recent = await bob.createGroup(draft);
        const active = await alice.createGroup(draft);
        await alice.addDocument(expired.id, 'doc-a', 'a.pdf', 100);
        await bob.addDocument(recent.id, 'doc-b', 'b.pdf', 100);
        await alice.addDocument(active.id, 'doc-c', 'c.pdf', 100);
        await alice.deleteGroup(expired.id);
        await bob.deleteGroup(recent.id);
        const daysAgo = (days: number) => new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
        await client.execute({ sql: 'UPDATE groups SET deleted_at=? WHERE id=?', args: [daysAgo(31), expired.id] });
        await client.execute({ sql: 'UPDATE groups SET deleted_at=? WHERE id=?', args: [daysAgo(29), recent.id] });
        // Past the deadline it is gone from the bin even before the purge runs.
        expect(await alice.deletedGroups()).toEqual([]);
        await expect(alice.restoreGroup(expired.id)).rejects.toMatchObject({ status: 404 });
        await purgeExpiredGroups(client);
        expect((await client.execute('SELECT storage_key FROM gc')).rows.map(r => r.storage_key)).toEqual(['doc-a.pdf']);
        expect((await client.execute('SELECT id FROM documents ORDER BY id')).rows.map(r => r.id)).toEqual(['doc-b', 'doc-c']);
        expect(await bob.deletedGroups()).toHaveLength(1);
        expect(await alice.groups()).toHaveLength(1);
    });
    it('queues every purged PDF for cleanup', async () => {
        const group = await alice.createGroup(draft);
        await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        await alice.addDocument(group.id, 'doc-b', 'b.pdf', 100);
        await alice.deleteGroup(group.id);
        await alice.purgeGroup(group.id);
        expect(await alice.deletedGroups()).toEqual([]);
        expect((await client.execute('SELECT * FROM documents')).rows).toHaveLength(0);
        expect((await client.execute('SELECT * FROM gc')).rows).toHaveLength(2);
    });
});
describe('agent approvals', () => {
    it('does not mutate before approval and applies once', async () => {
        const proposal = await alice.propose({ action: 'create_group', group: draft });
        expect(await alice.groups()).toHaveLength(0);
        await expect(bob.resolveProposal(proposal.id, true)).rejects.toMatchObject({ status: 404 });
        await alice.resolveProposal(proposal.id, true);
        expect(await alice.groups()).toHaveLength(1);
        await expect(alice.resolveProposal(proposal.id, true)).rejects.toMatchObject({ status: 404 });
    });
    it('rejects without mutating and safely deletes on approval', async () => {
        const group = await alice.createGroup(draft);
        await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        const rejected = await alice.propose({ action: 'delete_group', groupId: group.id });
        await alice.resolveProposal(rejected.id, false);
        expect(await alice.groups()).toHaveLength(1);
        const approved = await alice.propose({ action: 'delete_group', groupId: group.id });
        await alice.resolveProposal(approved.id, true);
        expect(await alice.groups()).toHaveLength(0);
        expect(await alice.deletedGroups()).toHaveLength(1);
    });
});
describe('schemas and filenames', () => {
    it('supports nested schemas and checks data types', () => {
        const schema = { type: 'object', properties: { items: { type: 'array', items: { type: 'object', properties: { price: { type: 'number' } }, required: ['price'] } } }, required: ['items'] };
        expect(() => validateData(schema, { items: [{ price: 5 }] })).not.toThrow();
        expect(() => validateData(schema, { items: [{ price: '5' }] })).toThrow();
        expect(() => validateSchema({ type: 'object', properties: { x: { $ref: 'https://evil.example/schema' } } })).toThrow();
    });
    it('sanitizes filenames and substitutes missing fields deterministically', () => {
        expect(pdfName('{vendor}-{missing}-{title}', { vendor: '../A/B' }, 'Receipt')).toBe('-A-B-unknown-Receipt.pdf');
    });
});
