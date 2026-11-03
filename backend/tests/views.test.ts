import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createClient, type Client } from '@libsql/client';
import { generateText } from 'ai';
import { agentTools, chat, processUploadedDocument } from '../lib/ai';
import { migrate } from '../lib/db';
import { runJS } from '../lib/js-sandbox';
import { Repository } from '../lib/repository';
import { runSQL } from '../lib/sql-sandbox';
import { validateUISpec } from '../lib/ui-catalog';
vi.mock('ai', async original => ({ ...await original<typeof import('ai')>(), generateText: vi.fn() }));
vi.mock('../lib/storage', () => ({ getPDF: vi.fn(async () => new Uint8Array([1])) }));
const draft = { name: 'Bills', instructions: '', namingTemplate: '{title}', schema: { type: 'object', properties: { kind: { type: 'string' }, amount: { type: 'number' }, paid_on: { type: 'string' } }, required: ['kind', 'amount'] } };
const text = (value: unknown) => ({ type: 'Text', props: { text: value }, children: [] });
const spec = { root: 'a', elements: { a: text({ $state: '/queries/total/0/sum' }) } };
const statistic = { kind: 'statistic', title: 'Total', spec, queries: { total: "SELECT sum(json_extract(data,'$.amount')) sum FROM documents" } };
const filter = {
    kind: 'filter', title: 'By kind',
    spec: { root: 'a', elements: { a: { type: 'TextInput', props: { label: 'Kind', value: { $bindState: '/kind' } }, children: [] } }, state: { kind: null } },
    queries: { documents: "SELECT id FROM documents WHERE (:kind IS NULL OR json_extract(data,'$.kind')=:kind)" },
};
const tool = (name: string) => (agentTools(alice) as unknown as Record<string, { execute(input: unknown): Promise<never> }>)[name];
let dir: string;
let client: Client;
let alice: Repository;
let bob: Repository;
let groupId: string;
let ids: string[];
beforeEach(async () => {
    vi.stubEnv('AI_GATEWAY_API_KEY', 'test');
    vi.mocked(generateText).mockReset();
    dir = mkdtempSync(join(tmpdir(), 'scanner-test-'));
    client = createClient({ url: 'file:' + join(dir, 'test.db') });
    await migrate(client);
    alice = new Repository('alice', client);
    bob = new Repository('bob', client);
    groupId = (await alice.createGroup(draft)).id;
    ids = [];
    for (const [i, [kind, amount, paid_on]] of ([['electricity', 80, '2026-10-01'], ['electricity', 70.5, '2026-07-01'], ['electricity', 999, '2025-01-01'], ['water', 20, '2026-09-01']] as const).entries()) {
        const doc = await alice.addDocument(groupId, `doc-${i}`, `${i}.pdf`, 10);
        await alice.complete(doc.id, `${i}.pdf`, { kind, amount, paid_on });
        ids.push(doc.id);
    }
    const other = await bob.createGroup(draft);
    const secret = await bob.addDocument(other.id, 'doc-bob', 'secret.pdf', 10);
    await bob.complete(secret.id, 'secret.pdf', { kind: 'secret', amount: 1000000 });
});
afterEach(() => { vi.unstubAllEnvs(); client.close(); rmSync(dir, { recursive: true, force: true }); });
describe('agent SQL', () => {
    it('only sees this owner’s rows, whatever it asks for', async () => {
        const { rows } = await tool('run_sql').execute({ sql: "SELECT count(*) n, sum(name='secret.pdf') leaked FROM documents" }) as { rows: unknown[] };
        expect(rows).toEqual([{ n: 4, leaked: 0 }]);
        await expect(tool('run_sql').execute({ sql: 'SELECT * FROM proposals' })).rejects.toMatchObject({ status: 422 });
        await expect(tool('run_sql').execute({ sql: 'SELECT storage_key FROM documents' })).rejects.toMatchObject({ status: 422 });
        await expect(tool('run_sql').execute({ sql: 'SELECT 1 FROM documents', groupId: 'not-mine' })).rejects.toMatchObject({ status: 404 });
    });
    it('cannot touch files or change anything', async () => {
        const data = await alice.sandboxData();
        const dbFile = join(dir, 'test.db');
        await expect(runSQL(data, { q: { sql: `ATTACH '${dbFile}' AS real` } })).rejects.toMatchObject({ status: 422 });
        await expect(runSQL(data, { q: { sql: 'DELETE FROM documents' } })).rejects.toMatchObject({ status: 422 });
        await expect(runSQL(data, { q: { sql: "SELECT load_extension('x')" } })).rejects.toMatchObject({ status: 422 });
        // Only the first statement runs, and writes never reach Turso.
        const r = await runSQL(data, { q: { sql: 'SELECT count(*) n FROM documents; DROP TABLE documents' } });
        expect(r.q.rows).toEqual([{ n: 4 }]);
        expect(await alice.documents(groupId)).toHaveLength(4);
    });
    it('stops a query that never ends', async () => {
        const started = Date.now();
        await expect(runSQL(await alice.sandboxData(), { q: { sql: 'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c' } }, 500)).rejects.toMatchObject({ status: 422, message: 'The query took too long' });
        expect(Date.now() - started).toBeLessThan(3000);
    });
});
describe('agent JavaScript', () => {
    it('adds up electricity paid in the last 6 months', async () => {
        const code = "return documents.filter(d => d.data.kind === 'electricity' && d.data.paid_on >= '2026-05-02').reduce((sum, d) => sum + d.data.amount, 0);";
        const { result } = await tool('run_js').execute({ code, groupId }) as { result: number };
        expect(result).toBe(150.5);
    });
    it('has no host access, and stops runaway code', async () => {
        const { result } = await runJS("console.log('hi'); return [typeof process, typeof require, typeof fetch, typeof globalThis.documents];", { documents: [] });
        expect(result).toEqual(['undefined', 'undefined', 'undefined', 'object']);
        await expect(runJS('while (true) {}', {}, 200)).rejects.toMatchObject({ status: 422 });
        await expect(runJS('const a = []; while (true) a.push(new Array(1000000).fill(1));', {})).rejects.toMatchObject({ status: 422 });
    });
    it('keeps injected data from escaping into code', async () => {
        const { result } = await runJS('return documents[0];', { documents: ['"); globalThis.hacked = 1; ("</script>'] });
        expect(result).toBe('"); globalThis.hacked = 1; ("</script>');
    });
});
describe('group views', () => {
    it('are created only after approval and show live data', async () => {
        const proposal = await alice.propose({ action: 'create_view', groupId, view: statistic });
        expect(await alice.views(groupId)).toEqual([]);
        await alice.resolveProposal(proposal.id, true);
        const [view] = await alice.views(groupId);
        expect(view).toMatchObject({ title: 'Total', kind: 'statistic' });
        expect(await alice.viewState(groupId, view)).toMatchObject({ queries: { total: [{ sum: 1169.5 }] } });
    });
    it('reject broken SQL and specs before they reach review', async () => {
        await expect(alice.propose({ action: 'create_view', groupId, view: { ...statistic, queries: { total: 'SELECT nope FROM documents' } } })).rejects.toMatchObject({ status: 422 });
        await expect(alice.propose({ action: 'create_view', groupId, view: { ...statistic, spec: { root: 'a', elements: { a: { type: 'Script', props: {}, children: [] } } } } })).rejects.toMatchObject({ status: 422 });
        await expect(alice.propose({ action: 'create_view', groupId, view: { ...filter, queries: { documents: 'SELECT name FROM documents' } } })).rejects.toMatchObject({ status: 422 });
        expect(await alice.proposals()).toEqual([]);
    });
    it('filters documents with bound values, so input is never SQL', async () => {
        const view = await alice.createView(groupId, filter);
        expect((await alice.runFilter(groupId, view.id, { kind: 'water' })).documentIds).toEqual([ids[3]]);
        expect((await alice.runFilter(groupId, view.id, { kind: '' })).documentIds).toHaveLength(4);
        expect((await alice.runFilter(groupId, view.id, { kind: "' OR 1=1 --" })).documentIds).toEqual([]);
    });
    it('are private to their owner and removed with the group', async () => {
        const view = await alice.createView(groupId, statistic);
        await expect(bob.views(groupId)).rejects.toMatchObject({ status: 404 });
        await expect(bob.view(groupId, view.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.deleteView(groupId, view.id)).rejects.toMatchObject({ status: 404 });
        await expect(bob.createView(groupId, statistic)).rejects.toMatchObject({ status: 404 });
        await alice.deleteGroup(groupId);
        await alice.purgeGroup(groupId);
        expect((await client.execute('SELECT * FROM group_views')).rows).toEqual([]);
    });
});
describe('UI specs', () => {
    it('accept the catalog and expressions, and refuse anything else', () => {
        expect(() => validateUISpec({ root: 'a', elements: { a: { type: 'Card', props: { title: { $template: 'x ${/y}' } }, repeat: { statePath: '/r' }, children: ['b'] }, b: text({ $item: 'z' }) }, state: { r: [] } })).not.toThrow();
        for (const bad of [
            { root: 'a', elements: { a: { type: 'WebView', props: {}, children: [] } } },
            { root: 'a', elements: { a: { ...text('x'), on: { press: { action: 'setState' } } } } },
            { root: 'a', elements: { a: text({ $computed: 'x' }) } },
            { root: 'a', elements: { a: { ...text('x'), children: ['missing'] } } },
            { root: 'a', elements: { a: { type: 'Card', props: {}, children: ['b'] }, b: { type: 'Card', props: {}, children: ['a'] } } },
        ])
            expect(() => validateUISpec(bad)).toThrow(/Invalid UI spec/);
    });
});
describe('extracting beyond the schema', () => {
    const fields = { output: { title: 'Bill', fields: { kind: 'gas', amount: 5 } } };
    const additional = { facts: { meter: 'A-1' }, spec: { root: 'a', elements: { a: text('Meter A-1') } } };
    async function upload(extractAdditional: boolean) {
        const group = await alice.createGroup({ ...draft, extractAdditional });
        const doc = await alice.addDocument(group.id, 'doc-new', 'Scan.pdf', 10);
        await alice.claimDocument(doc.id);
        return doc.id;
    }
    it('stays off unless the group asks for it', async () => {
        vi.mocked(generateText).mockResolvedValue(fields as never);
        const id = await upload(false);
        await processUploadedDocument(alice, id);
        expect(generateText).toHaveBeenCalledTimes(1);
        expect((await alice.document(id)).additional).toBeNull();
    });
    it('saves the facts and their view, and retries a rejected view', async () => {
        vi.mocked(generateText).mockImplementation((async (options: { output?: { name?: string }; system?: string }) => {
            if (!options.system?.startsWith('Find what'))
                return fields;
            return vi.mocked(generateText).mock.calls.filter(c => (c[0].system as string).startsWith('Find what')).length === 1 ? { output: { facts: {}, spec: { root: 'a', elements: {} } } } : { output: additional };
        }) as never);
        const id = await upload(true);
        await processUploadedDocument(alice, id);
        expect(await alice.document(id)).toMatchObject({ status: 'ready', data: { kind: 'gas' }, additional });
        const { rows } = await tool('run_sql').execute({ sql: "SELECT json_extract(additional,'$.meter') meter FROM documents WHERE id='doc-new'" }) as { rows: unknown[] };
        expect(rows).toEqual([{ meter: 'A-1' }]);
    });
    it('still saves the requested fields when the extra part fails', async () => {
        vi.spyOn(console, 'error').mockImplementation(() => {});
        vi.mocked(generateText).mockImplementation((async (options: { system?: string }) => {
            if (options.system?.startsWith('Find what'))
                throw new Error('gateway down');
            return fields;
        }) as never);
        const id = await upload(true);
        await processUploadedDocument(alice, id);
        expect(await alice.document(id)).toMatchObject({ status: 'ready', data: { kind: 'gas' }, additional: null });
    });
});
describe('chat', () => {
    const reply = { text: 'Done', steps: [] };
    it('gives the agent what the user has open, and tolerates a stale ID', async () => {
        vi.mocked(generateText).mockResolvedValue(reply as never);
        await chat(alice, [{ role: 'user', content: 'how much?' }], { documentId: ids[0] });
        const system = vi.mocked(generateText).mock.lastCall?.[0].system as string;
        expect(system).toContain(ids[0]);
        expect(system).toContain(groupId);
        expect(system).toContain('reading this PDF');
        await expect(chat(alice, [{ role: 'user', content: 'hi' }], { groupId: 'gone', documentId: 'gone' })).resolves.toMatchObject({ text: 'Done' });
        // Another account's IDs must not leak their contents into the prompt.
        const foreign = (await bob.groups())[0].id;
        await chat(alice, [{ role: 'user', content: 'hi' }], { groupId: foreign });
        expect(vi.mocked(generateText).mock.lastCall?.[0].system).not.toContain(foreign);
    });
    it('returns a selection limited to the open group, and reports tool use', async () => {
        vi.mocked(generateText).mockImplementation((async (options: { tools: Record<string, { execute(input: unknown): Promise<unknown> }> }) => {
            await options.tools.select_documents.execute({ documentIds: [ids[0], 'doc-bob'], label: 'Electricity' });
            return { text: 'Filtered', steps: [{ toolCalls: [{ toolName: 'run_js', input: { code: 'return 1' } }] }] };
        }) as never);
        const result = await chat(alice, [{ role: 'user', content: 'show' }], { groupId });
        expect(result.selection).toEqual({ groupId, documentIds: [ids[0]], label: 'Electricity' });
        expect(result.activity).toEqual([{ tool: 'run_js', detail: 'return 1' }]);
    });
});
describe('migration', () => {
    it('upgrades an existing database and can run again', async () => {
        const old = createClient({ url: 'file:' + join(dir, 'old.db') });
        await old.executeMultiple(`CREATE TABLE groups (id TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL, instructions TEXT NOT NULL, naming_template TEXT NOT NULL, schema_json TEXT NOT NULL, created_at TEXT NOT NULL);
            INSERT INTO groups VALUES ('g','alice','Old','','{title}','{"type":"object","properties":{}}','2026-01-01');
            CREATE TABLE documents (id TEXT PRIMARY KEY, group_id TEXT NOT NULL, owner TEXT NOT NULL, name TEXT NOT NULL, original_name TEXT NOT NULL, storage_key TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL, data_json TEXT, error TEXT, processing_started_at TEXT, created_at TEXT NOT NULL);`);
        await migrate(old);
        await migrate(old);
        const repo = new Repository('alice', old);
        expect((await repo.groups())[0]).toMatchObject({ name: 'Old', extractAdditional: false });
        old.close();
    });
});

describe('saved statistics post-processing', () => {
    it('persists and recomputes scripts over scoped SQL rows', async () => {
        const saved = await alice.createView(groupId, { ...statistic, spec: { ...spec, postProcess: 'return { doubled: queries.total[0].sum * 2 };' } });
        const loaded = await alice.view(groupId, saved.id);
        expect(await alice.viewState(groupId, loaded)).toMatchObject({ processed: { doubled: 2339 } });
        await expect(bob.viewState(groupId, loaded)).rejects.toMatchObject({ status: 404 });
    });
    it('rejects invalid scripts before saving', async () => {
        for (const postProcess of ['return [];', 'throw new Error("bad script");', 'return fetch("https://example.com");']) {
            await expect(alice.createView(groupId, { ...statistic, spec: { ...spec, postProcess } })).rejects.toMatchObject({ status: 422 });
        }
        expect(await alice.views(groupId)).toEqual([]);
    });
});

describe('statistics input parameters', () => {
    it('uses the default year and recomputes each selected year without changing the saved default', async () => {
        const saved = await alice.createView(groupId, { ...statistic, spec: { ...spec, state: { year: '2026' } }, queries: { total: "SELECT count(*) AS count, sum(json_extract(data, '$.amount')) AS sum FROM documents WHERE substr(json_extract(data, '$.paid_on'), 1, 4) = :year" } });
        expect(await alice.viewState(groupId, saved)).toMatchObject({ year: '2026', queries: { total: [{ count: 3, sum: 170.5 }] } });
        expect(await alice.viewState(groupId, saved, { year: '2025' })).toMatchObject({ year: '2025', queries: { total: [{ count: 1, sum: 999 }] } });
        expect(await alice.viewState(groupId, saved, { year: '2024' })).toMatchObject({ queries: { total: [{ count: 0, sum: null }] } });
        expect((await alice.view(groupId, saved.id)).spec.state).toEqual({ year: '2026' });
        await expect(bob.viewState(groupId, saved, { year: '2025' })).rejects.toMatchObject({ status: 404 });
    });
});
