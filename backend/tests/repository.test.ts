import { Forms } from '../lib/forms';
import { parseDocumentSort } from '../lib/document-sort';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beforeEach, afterEach, describe, expect, it } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { migrate } from '../lib/db';
import { purgeExpiredGroups, Repository } from '../lib/repository';
import { pdfName, validateSchema, validateData } from '../lib/contracts';
import { runSQL } from '../lib/sql-sandbox';
let dir: string;
let client: Client;
let alice: Repository;
let bob: Repository;
const draft = { name: 'Invoices', instructions: 'Extract invoice details', namingTemplate: '{vendor}-{title}', schema: { type: 'object', properties: { vendor: { type: 'string' }, total: { type: 'number' } }, required: ['vendor', 'total'], additionalProperties: false } };
beforeEach(async () => { dir = mkdtempSync(join(tmpdir(), 'scanner-test-')); client = createClient({ url: 'file:' + join(dir, 'test.db') }); await migrate(client); alice = new Repository('alice', client); bob = new Repository('bob', client); });
afterEach(() => { client.close(); rmSync(dir, { recursive: true, force: true }); });
describe('saved chat messages', () => {
    it('returns the latest conversation in order, for its owner only', async () => {
        expect(await alice.latestConversation()).toEqual({ conversationId: null, messages: [] });
        await alice.addChatMessage('old', 'user', 'first conversation');
        await alice.addChatMessage('new', 'user', 'how much?');
        await alice.addChatMessage('new', 'assistant', '$12', [{ tool: 'run_sql', detail: 'SELECT 1' }]);
        const latest = await alice.latestConversation();
        expect(latest.conversationId).toBe('new');
        expect(latest.messages.map(m => [m.role, m.content])).toEqual([['user', 'how much?'], ['assistant', '$12']]);
        expect(latest.messages[1].activity).toEqual([{ tool: 'run_sql', detail: 'SELECT 1' }]);
        expect(await bob.latestConversation()).toEqual({ conversationId: null, messages: [] });
    });
    it('keeps only the last 100 messages of a long conversation', async () => {
        for (let i = 0; i < 101; i++)
            await alice.addChatMessage('long', 'user', `m${i}`);
        const { messages } = await alice.latestConversation();
        expect(messages.length).toBe(100);
        expect(messages[0].content).toBe('m1');
        expect(messages[99].content).toBe('m100');
    });
});
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
    it('renames a document without touching its status or data', async () => {
        const group = await alice.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        await expect(bob.renameDocument(doc.id, 'stolen')).rejects.toMatchObject({ status: 404 });
        expect(await alice.renameDocument(doc.id, 'March/invoice.PDF')).toMatchObject({ name: 'March-invoice.pdf', originalName: 'a.pdf', status: 'uploaded', data: null });
        await alice.claimDocument(doc.id);
        await expect(alice.renameDocument(doc.id, 'busy')).rejects.toMatchObject({ status: 409 });
        await alice.complete(doc.id, 'done.pdf', { vendor: 'A', total: 42 });
        expect(await alice.renameDocument(doc.id, 'kept')).toMatchObject({ name: 'kept.pdf', status: 'ready', data: { vendor: 'A', total: 42 } });
    });
    it('applies a proposed rename only once it is approved', async () => {
        const group = await alice.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        const proposal = await alice.propose({ action: 'rename_document', documentId: doc.id, name: 'Proposed' });
        expect((await alice.document(doc.id)).name).toBe('a.pdf');
        await alice.resolveProposal(proposal.id, true);
        expect(await alice.document(doc.id)).toMatchObject({ name: 'Proposed.pdf', status: 'uploaded' });
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
describe('subgroups', () => {
    it('creates a subgroup only inside the owner’s own group', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, name: 'Refunds', parentId: parent.id });
        expect(child).toMatchObject({ parentId: parent.id, kind: 'group' });
        await expect(bob.createGroup({ ...draft, parentId: parent.id })).rejects.toMatchObject({ status: 404 });
    });
    it('sends subgroups to the Recycle Bin and restores them with their parent', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, name: 'Child', parentId: parent.id });
        const grandchild = await alice.createGroup({ ...draft, name: 'Grandchild', parentId: child.id });
        await alice.addDocument(parent.id, 'doc-a', 'a.pdf', 100);
        await alice.addDocument(grandchild.id, 'doc-b', 'b.pdf', 100);
        await alice.deleteGroup(parent.id);
        expect(await alice.groups()).toEqual([]);
        const bin = await alice.deletedGroups();
        expect(bin.map(g => [g.id, g.documentCount])).toEqual([[parent.id, 2]]);
        await expect(alice.restoreGroup(child.id)).rejects.toMatchObject({ status: 404 });
        await alice.restoreGroup(parent.id);
        expect((await alice.groups()).map(g => g.id).sort()).toEqual([parent.id, child.id, grandchild.id].sort());
        expect((await alice.document('doc-b')).groupId).toBe(grandchild.id);
    });
    it('purges a deleted group’s subgroups and queues all of their PDFs', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, parentId: parent.id });
        await alice.addDocument(child.id, 'doc-a', 'a.pdf', 100);
        await alice.deleteGroup(parent.id);
        await alice.purgeGroup(parent.id);
        expect((await client.execute('SELECT id FROM groups')).rows).toHaveLength(0);
        expect((await client.execute('SELECT storage_key FROM gc')).rows.map(r => r.storage_key)).toEqual(['doc-a.pdf']);
    });
    it('restores a subgroup to the top level when its parent is no longer there', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, name: 'Child', parentId: parent.id });
        await alice.deleteGroup(child.id);
        await new Promise(resolve => setTimeout(resolve, 2));
        await alice.deleteGroup(parent.id);
        expect((await alice.deletedGroups()).map(g => g.id).sort()).toEqual([parent.id, child.id].sort());
        expect(await alice.restoreGroup(child.id)).toMatchObject({ id: child.id, parentId: null });
        expect(await alice.restoreGroup(parent.id)).toMatchObject({ id: parent.id });
    });
});
describe('agent SQL', () => {
    it('can read the group hierarchy', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, name: 'Child', parentId: parent.id });
        await alice.inbox();
        const { result } = await runSQL(await alice.sandboxData(), { result: { sql: "SELECT id, parent_id FROM groups WHERE kind='group' AND parent_id IS NOT NULL" } });
        expect(result.rows).toEqual([{ id: child.id, parent_id: parent.id }]);
    });
});
describe('inbox', () => {
    it('gives each owner one inbox that can’t be edited, deleted, or nested into', async () => {
        const inbox = await alice.inbox();
        expect(inbox).toMatchObject({ kind: 'inbox', name: 'Inbox' });
        expect((await alice.inbox()).id).toBe(inbox.id);
        expect((await bob.inbox()).id).not.toBe(inbox.id);
        await expect(alice.deleteGroup(inbox.id)).rejects.toMatchObject({ status: 422 });
        await expect(alice.updateGroup(inbox.id, draft)).rejects.toMatchObject({ status: 422 });
        await expect(alice.createGroup({ ...draft, parentId: inbox.id })).rejects.toMatchObject({ status: 422 });
        expect(() => validateSchema(inbox.schema)).not.toThrow();
    });
});
describe('moving documents', () => {
    it('keeps extracted data when both groups have the same fields', async () => {
        const parent = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, name: 'Child', parentId: parent.id });
        const doc = await alice.addDocument(parent.id, 'doc-a', 'a.pdf', 100);
        await alice.complete(doc.id, 'done.pdf', { vendor: 'A', total: 1 });
        expect(await alice.moveDocument(doc.id, child.id)).toMatchObject({ reread: false, document: { groupId: child.id, status: 'ready', data: { vendor: 'A', total: 1 } } });
        expect(await alice.moveDocument(doc.id, parent.id)).toMatchObject({ reread: false, document: { groupId: parent.id, name: 'done.pdf' } });
        expect(await alice.moveDocument(doc.id, parent.id)).toMatchObject({ reread: false });
    });
    it('clears old fields and marks the PDF for reading when the fields differ', async () => {
        const from = await alice.createGroup(draft);
        const to = await alice.createGroup({ ...draft, schema: { type: 'object', properties: { other: { type: 'string' } } } });
        const doc = await alice.addDocument(from.id, 'doc-a', 'a.pdf', 100);
        await alice.complete(doc.id, 'done.pdf', { vendor: 'A', total: 1 });
        expect(await alice.moveDocument(doc.id, to.id)).toMatchObject({ reread: true, document: { groupId: to.id, status: 'processing', data: null } });
        await expect(alice.moveDocument(doc.id, from.id)).rejects.toMatchObject({ status: 409 });
    });
    it('refuses another owner’s documents and groups, and the inbox as a target', async () => {
        const mine = await alice.createGroup(draft);
        const theirs = await bob.createGroup(draft);
        const doc = await alice.addDocument(mine.id, 'doc-a', 'a.pdf', 100);
        await expect(bob.moveDocument(doc.id, theirs.id)).rejects.toMatchObject({ status: 404 });
        await expect(alice.moveDocument(doc.id, theirs.id)).rejects.toMatchObject({ status: 404 });
        await expect(alice.moveDocument(doc.id, (await alice.inbox()).id)).rejects.toMatchObject({ status: 422 });
    });
});
describe('organize proposals', () => {
    it('creates nested groups and files scans only once approved', async () => {
        const inbox = await alice.inbox();
        const finance = await alice.createGroup({ ...draft, name: 'Finance' });
        const scan = await alice.addDocument(inbox.id, 'scan-a', 'Scan.pdf', 100);
        const other = await alice.addDocument(finance.id, 'doc-b', 'b.pdf', 100);
        const proposal = await alice.propose({
            action: 'organize_documents',
            newGroups: [{ ref: 'taxes', parent: finance.id, name: 'Taxes' }, { ref: '2026', parent: 'taxes', name: '2026' }],
            moves: [{ documentId: scan.id, target: '2026' }, { documentId: other.id, target: 'taxes' }],
        });
        expect(proposal.mutation).toMatchObject({ review: {
            newGroups: [{ path: 'Finance / Taxes', fields: ['vendor', 'total'] }, { path: 'Finance / Taxes / 2026', fields: ['vendor', 'total'] }],
            moves: [{ document: 'Scan.pdf', from: 'Inbox', to: 'Finance / Taxes / 2026', reread: true }, { document: 'b.pdf', from: 'Finance', to: 'Finance / Taxes', reread: false }],
        } });
        expect(await alice.groups()).toHaveLength(2);
        const { reread } = await alice.resolveProposal(proposal.id, true);
        expect(reread).toEqual([scan.id]);
        const groups = await alice.groups();
        const taxes = groups.find(g => g.name === 'Taxes')!;
        const year = groups.find(g => g.name === '2026')!;
        expect(taxes).toMatchObject({ parentId: finance.id, instructions: draft.instructions, namingTemplate: draft.namingTemplate, schema: draft.schema });
        expect(year.parentId).toBe(taxes.id);
        expect(await alice.document(scan.id)).toMatchObject({ groupId: year.id, status: 'processing' });
        expect(await alice.document(other.id)).toMatchObject({ groupId: taxes.id, status: 'uploaded' });
        expect((await alice.groups()).find(g => g.id === inbox.id)?.documentCount).toBe(0);
    });
    it('applies nothing when any part of an approved plan is no longer possible', async () => {
        const group = await alice.createGroup(draft);
        const a = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        const b = await alice.addDocument(group.id, 'doc-b', 'b.pdf', 100);
        const proposal = await alice.propose({ action: 'organize_documents', newGroups: [{ ref: 'sub', parent: group.id, name: 'Sub' }], moves: [{ documentId: a.id, target: 'sub' }, { documentId: b.id, target: 'sub' }] });
        await alice.deleteDocument(b.id);
        await expect(alice.resolveProposal(proposal.id, true)).rejects.toMatchObject({ status: 404 });
        expect(await alice.groups()).toHaveLength(1);
        expect((await alice.document(a.id)).groupId).toBe(group.id);
    });
    it('rejects a plan it could not carry out, so Lumik can fix it', async () => {
        const group = await alice.createGroup(draft);
        const theirs = await bob.createGroup(draft);
        const doc = await alice.addDocument(group.id, 'doc-a', 'a.pdf', 100);
        const plan = (rest: object) => alice.propose({ action: 'organize_documents', ...rest });
        await expect(plan({})).rejects.toMatchObject({ status: 422 });
        await expect(plan({ newGroups: [{ ref: 'x', name: 'No schema' }] })).rejects.toMatchObject({ status: 422 });
        await expect(plan({ newGroups: [{ ref: 'x', parent: theirs.id, name: 'Foreign' }] })).rejects.toMatchObject({ status: 422 });
        await expect(plan({ newGroups: [{ ref: 'x', parent: 'later', name: 'Early' }, { ref: 'later', parent: group.id, name: 'Later' }] })).rejects.toMatchObject({ status: 422 });
        await expect(plan({ moves: [{ documentId: doc.id, target: theirs.id }] })).rejects.toMatchObject({ status: 422 });
        await expect(plan({ moves: [{ documentId: doc.id, target: group.id }] })).rejects.toMatchObject({ status: 422 });
        await expect(plan({ moves: [{ documentId: doc.id, target: (await alice.inbox()).id }] })).rejects.toMatchObject({ status: 422 });
        await expect(bob.propose({ action: 'organize_documents', moves: [{ documentId: doc.id, target: theirs.id }] })).rejects.toMatchObject({ status: 404 });
        await alice.claimDocument(doc.id);
        const other = await alice.createGroup(draft);
        await expect(plan({ moves: [{ documentId: doc.id, target: other.id }] })).rejects.toMatchObject({ status: 409 });
        await expect(alice.proposals()).resolves.toEqual([]);
    });
    it('rejects a subgroup proposed under another owner’s group', async () => {
        const theirs = await bob.createGroup(draft);
        await expect(alice.propose({ action: 'create_group', group: { ...draft, parentId: theirs.id } })).rejects.toMatchObject({ status: 404 });
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

describe('moving groups', () => {
    it('nests and unnests a group while preserving its children', async () => {
        const a = await alice.createGroup(draft);
        const b = await alice.createGroup(draft);
        const child = await alice.createGroup({ ...draft, parentId: a.id });
        expect((await alice.moveGroup(a.id, b.id)).parentId).toBe(b.id);
        expect((await alice.group(child.id)).parentId).toBe(a.id);
        await expect(alice.moveGroup(b.id, child.id)).rejects.toMatchObject({ status: 422 });
        await expect(alice.moveGroup(a.id, a.id)).rejects.toMatchObject({ status: 422 });
        expect((await alice.moveGroup(a.id, null)).parentId).toBeNull();
        await expect(bob.moveGroup(a.id, null)).rejects.toMatchObject({ status: 404 });
        const foreign = await bob.createGroup(draft);
        await expect(alice.moveGroup(a.id, foreign.id)).rejects.toMatchObject({ status: 404 });
    });
});

describe('document ordering', () => {
    it('orders both list and overview with deterministic ties and preserves ownership', async () => {
        const group = await alice.createGroup(draft);
        await alice.addDocument(group.id, 'a', 'Zulu.pdf', 30);
        await alice.addDocument(group.id, 'b', 'alpha.pdf', 10);
        await alice.addDocument(group.id, 'c', 'Alpha.pdf', 10);
        await client.execute({ sql: 'UPDATE documents SET created_at=? WHERE group_id=?', args: ['2026-01-01', group.id] });
        const forms = new Forms('alice', client);
        for (const [sortBy, ascending] of [
            ['name', ['b', 'c', 'a']], ['size', ['b', 'c', 'a']], ['createdAt', ['a', 'b', 'c']],
        ] as const) {
            for (const sortDirection of ['asc', 'desc'] as const) {
                const sort = { sortBy, sortDirection };
                const expected = sortDirection === 'asc' ? [...ascending] : [...ascending].reverse();
                expect((await alice.documents(group.id, sort)).map(d => d.id)).toEqual(expected);
                expect((await forms.overview(group.id, sort)).documents.map(d => d.id)).toEqual(expected);
                await expect(bob.documents(group.id, sort)).rejects.toMatchObject({ status: 404 });
            }
        }
        expect((await alice.documents(group.id)).map(d => d.id)).toEqual(['c', 'b', 'a']);
        expect(parseDocumentSort('https://example.test')).toEqual({ sortBy: 'createdAt', sortDirection: 'desc' });
        expect(() => parseDocumentSort('https://example.test?sortBy=invalid')).toThrow();
        expect(() => parseDocumentSort('https://example.test?sortDirection=invalid')).toThrow();
    });
});
