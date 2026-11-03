import { validateLocalExtraction, saveLocalExtraction } from '@/lib/local-extraction';
import { account, purgeAccounts } from '@/lib/account';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { after } from 'next/server';
import { zipSync, strToU8 } from 'fflate';
import { z } from 'zod';
import { principal } from '@/lib/auth';
import { purgeExpiredGroups, Repository } from '@/lib/repository';
import { ApiError, safeName } from '@/lib/contracts';
import { getPDF, putPDF, removePDF, presignPDF, promoteUpload } from '@/lib/storage';
import { chat, chatContext, draftSchema, processDocument, processUploadedDocument, suggestDocumentName, suggestDocumentGroup } from '@/lib/ai';
import { errorResponse, jsonBody } from '@/lib/http';
import { db, expirePDFUploads } from '@/lib/db';
export const runtime = 'nodejs';
export const maxDuration = 120;
async function cleanup() { try {
    await purgeAccounts();
    await purgeExpiredGroups();
    await expirePDFUploads();
}
catch { /* retried on the next mutation */ } const r = await db().execute('SELECT storage_key FROM gc LIMIT 25'); for (const row of r.rows) {
    try {
        await removePDF(String(row.storage_key));
        await db().execute({ sql: 'DELETE FROM gc WHERE storage_key=?', args: [row.storage_key] });
    }
    catch { /* queued for the next mutation */ }
} }
async function route(req: Request, { params }: {
    params: Promise<{
        path: string[];
    }>;
}) {
    try {
        const repo = new Repository(await principal(req));
        const p = (await params).path;
        const method = req.method;
        if (p.join('/') === 'account' && ['GET','POST','DELETE'].includes(method)) return Response.json(await account(repo.owner,method));
        if (p.length===2 && p[0]==='legal' && ['terms','privacy'].includes(p[1]) && method==='GET') return Response.json({markdown:await readFile(join(process.cwd(),'legal',p[1]+'.md'),'utf8')});
        if (p[0] === 'groups' && p.length === 1) {
            if (method === 'GET')
                return Response.json(await repo.groups());
            if (method === 'POST')
                return Response.json(await repo.createGroup(await jsonBody(req)), { status: 201 });
        }
        if (p[0] === 'groups' && p.length === 2) {
            if (method === 'GET')
                return Response.json(await repo.group(p[1]));
            if (method === 'PATCH')
                return Response.json(await repo.updateGroup(p[1], await jsonBody(req)));
            if (method === 'DELETE') {
                await repo.deleteGroup(p[1]);
                await cleanup();
                return Response.json({ ok: true });
            }
        }
        if (p.join('/') === 'inbox' && method === 'POST')
            return Response.json(await repo.inbox());
        if (p[0] === 'deleted-groups') {
            if (p.length === 1 && method === 'GET')
                return Response.json(await repo.deletedGroups());
            if (p.length === 2 && method === 'DELETE') {
                await repo.purgeGroup(p[1]);
                await cleanup();
                return Response.json({ ok: true });
            }
            if (p.length === 3 && p[2] === 'restore' && method === 'POST')
                return Response.json(await repo.restoreGroup(p[1]));
        }
        if (p[0] === 'groups' && p[2] === 'uploads' && method === 'POST') {
            await repo.group(p[1]);
            if (p.length === 3) {
                const input = z.object({ name: z.string().min(1).max(255), size: z.number().int().min(5) }).parse(await jsonBody(req));
                const id = randomUUID();
                const stagingKey = `${randomUUID()}.pdf`;
                const url = await presignPDF(stagingKey, input.size);
                if (!url) return Response.json({ mode: 'local' });
                await db().execute({ sql: 'INSERT INTO pdf_uploads VALUES(?,?,?,?,?,?,?)', args: [id, repo.owner, p[1], input.name, input.size, stagingKey, Date.now() + 86_400_000] });
                return Response.json({ mode: 'direct', id, url });
            }
            if (p.length === 5 && p[4] === 'complete') {
                const raw = await req.text();
                const options = z.discriminatedUnion('processing', [
                    z.object({ processing: z.literal('cloud').default('cloud') }).strict(),
                    z.object({ processing: z.literal('apple'), result: z.unknown() }).strict(),
                ]).parse({ processing: 'cloud', ...(raw ? JSON.parse(raw) : {}) });
                const group = await repo.group(p[1]);
                const local = options.processing === 'apple' ? validateLocalExtraction(group, options.result) : null;
                const pending = await db().execute({ sql: 'SELECT * FROM pdf_uploads WHERE id=? AND owner=? AND group_id=?', args: [p[3], repo.owner, p[1]] });
                const upload = pending.rows[0];
                if (!upload) throw new ApiError(404, 'Upload not found');
                // Retrying completion must not create or process a second document.
                const existing = await db().execute({ sql: 'SELECT id FROM documents WHERE id=? AND owner=?', args: [p[3], repo.owner] });
                if (existing.rows.length) return Response.json(await repo.document(p[3]));
                if (Number(upload.expires_at) < Date.now()) throw new ApiError(410, 'Upload expired. Save again to retry.');
                await promoteUpload(String(upload.staging_key), `${p[3]}.pdf`, Number(upload.size));
                await repo.addDocument(p[1], p[3], String(upload.name), Number(upload.size));
                await db().execute({ sql: 'INSERT OR IGNORE INTO gc VALUES(?)', args: [upload.staging_key] });
                if (local) return Response.json(await saveLocalExtraction(repo, group, p[3], local), { status: 201 });
                await repo.claimDocument(p[3]);
                after(() => processUploadedDocument(repo, p[3]));
                return Response.json(await repo.document(p[3]), { status: 201 });
            }
        }
        if (p[0] === 'groups' && p[2] === 'documents' && p.length === 3) {
            if (method === 'GET')
                return Response.json((await repo.documents(p[1])).map(({ storageKey, ...d }) => d));
            if (method === 'POST') {
                await repo.group(p[1]);
                const form = await req.formData();
                const localValue = form.get('localResult');
                const group = await repo.group(p[1]);
                const local = localValue === null ? null : validateLocalExtraction(group, JSON.parse(String(localValue)));
                const file = form.get('file');
                if (!(file instanceof File) || file.size < 5)
                    throw new ApiError(400, 'Choose a PDF');
                const bytes = new Uint8Array(await file.arrayBuffer());
                if (new TextDecoder().decode(bytes.slice(0, 5)) !== '%PDF-')
                    throw new ApiError(400, 'Only PDF documents are supported');
                const id = randomUUID();
                await putPDF(`${id}.pdf`, bytes);
                try {
                    await repo.addDocument(p[1], id, file.name, file.size);
                }
                catch (e) {
                    await removePDF(`${id}.pdf`);
                    throw e;
                }
                if (local) return Response.json(await saveLocalExtraction(repo, group, id, local), { status: 201 });
                // Claim before responding so clients see "processing" and know to poll.
                await repo.claimDocument(id);
                after(() => processUploadedDocument(repo, id));
                return Response.json(await repo.document(id), { status: 201 });
            }
        }
        if (p[0] === 'groups' && p[2] === 'export' && p.length === 3 && method === 'GET') {
            const g = await repo.group(p[1]);
            const docs = await repo.documents(p[1]);
            if (docs.reduce((s, d) => s + d.size, 0) > 100 * 1024 * 1024)
                throw new ApiError(413, 'This group exceeds the 100 MB export limit. Export smaller groups.');
            const files: Record<string, Uint8Array> = {};
            for (const d of docs)
                files[`${d.id.slice(0, 8)}-${safeName(d.name)}`] = await getPDF(d.storageKey);
            files['manifest.json'] = strToU8(JSON.stringify({ group: g, documents: docs.map(({ storageKey, ...d }) => d) }, null, 2));
            return new Response(Buffer.from(zipSync(files)), { headers: { 'Content-Type': 'application/zip', 'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(safeName(g.name))}.zip`, 'Cache-Control': 'private, no-store' } });
        }
        if (p[0] === 'groups' && p[2] === 'views') {
            if (p.length === 3 && method === 'GET')
                return Response.json(await repo.views(p[1]));
            if (p[3] === 'preview' && p.length === 4 && method === 'POST') {
                const view = await repo.checkView(p[1], await jsonBody(req));
                return Response.json({ state: await repo.viewState(p[1], view) });
            }
            if (p.length === 4 && method === 'DELETE') {
                await repo.deleteView(p[1], p[3]);
                return Response.json({ ok: true });
            }
            if (p[4] === 'state' && p.length === 5 && method === 'GET')
                return Response.json({ state: await repo.viewState(p[1], await repo.view(p[1], p[3])) });
            if (p[4] === 'run' && p.length === 5 && method === 'POST') {
                const b = z.object({ values: z.record(z.string(), z.union([z.string().max(1000), z.number(), z.boolean(), z.null()])) }).parse(await jsonBody(req));
                return Response.json(await repo.runFilter(p[1], p[3], b.values));
            }
        }
        if (p[0] === 'documents' && p.length === 2) {
            if (method === 'GET')
                return Response.json(await repo.document(p[1]));
            if (method === 'PATCH') {
                const b = z.object({ name: z.string().min(1).max(150), data: z.record(z.string(), z.unknown()) }).parse(await jsonBody(req));
                return Response.json(await repo.editDocument(p[1], b.name, b.data));
            }
            if (method === 'DELETE') {
                await repo.deleteDocument(p[1]);
                await cleanup();
                return Response.json({ ok: true });
            }
        }
        if (p[0] === 'documents' && p.length === 3) {
            if (p[2] === 'suggest-group' && method === 'POST')
                return Response.json(await suggestDocumentGroup(repo, p[1]));
            if (p[2] === 'process' && method === 'POST')
                return Response.json(await processDocument(repo, p[1]));
            if (p[2] === 'rename' && method === 'POST') {
                const b = z.object({ name: z.string().trim().min(1).max(150) }).parse(await jsonBody(req));
                const { storageKey, ...document } = await repo.renameDocument(p[1], b.name);
                return Response.json(document);
            }
            if (p[2] === 'move' && method === 'POST') {
                const b = z.object({ groupId: z.string().min(1) }).parse(await jsonBody(req));
                const { document: { storageKey, ...document }, reread } = await repo.moveDocument(p[1], b.groupId);
                if (reread)
                    after(() => processUploadedDocument(repo, p[1]));
                return Response.json(document);
            }
            if (p[2] === 'suggest-name' && method === 'POST')
                return Response.json(await suggestDocumentName(repo, p[1]));
            if (p[2] === 'pdf' && method === 'GET') {
                const d = await repo.document(p[1]);
                return new Response(Buffer.from(await getPDF(d.storageKey)), { headers: { 'Content-Type': 'application/pdf', 'Cache-Control': 'private, no-store', 'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(d.name)}` } });
            }
        }
        if (p.join('/') === 'schema/draft' && method === 'POST') {
            const b = z.object({ prompt: z.string().min(5).max(4000) }).parse(await jsonBody(req));
            return Response.json(await draftSchema(b.prompt));
        }
        if (p.join('/') === 'chat' && method === 'POST') {
            const b = z.object({ conversationId: z.string().min(1).max(64).optional(), messages: z.array(z.object({ role: z.enum(['user', 'assistant']), content: z.string().min(1).max(8000) })).min(1).max(40), context: chatContext.optional() }).parse(await jsonBody(req));
            // Builds that predate saved chats send no ID, so each of their messages starts a conversation.
            const conversationId = b.conversationId ?? randomUUID();
            const last = b.messages[b.messages.length - 1];
            // Saved first, so the user's message survives a failed reply.
            if (last.role === 'user')
                await repo.addChatMessage(conversationId, 'user', last.content);
            const reply = await chat(repo, b.messages, b.context);
            await repo.addChatMessage(conversationId, 'assistant', reply.text || 'I’ve prepared a change for your review.', reply.activity);
            return Response.json(reply);
        }
        if (p.join('/') === 'chat/messages' && method === 'GET')
            return Response.json(await repo.latestConversation());
        if (p.join('/') === 'proposals' && method === 'GET')
            return Response.json(await repo.proposals());
        if (p[0] === 'proposals' && p.length === 2 && method === 'POST') {
            const b = z.object({ approve: z.boolean() }).parse(await jsonBody(req));
            const { reread, ...result } = await repo.resolveProposal(p[1], b.approve);
            if (reread.length)
                after(() => Promise.all(reread.map(id => processUploadedDocument(repo, id))));
            await cleanup();
            return Response.json(result);
        }
        throw new ApiError(404, 'Route not found');
    }
    catch (e) {
        return errorResponse(e);
    }
}
export { route as GET, route as POST, route as PATCH, route as DELETE };
