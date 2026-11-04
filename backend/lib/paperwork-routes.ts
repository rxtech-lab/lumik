import { parseDocumentSort } from './document-sort';
import { randomUUID } from 'node:crypto';
import { after } from 'next/server';
import { z } from 'zod';
import { createFormTemplate, processUploadedDocument } from './ai';
import { ApiError, formSave, signatureMethodInput, signingComplete, signingCreate, signingUploads, templateEdit, templateRequest } from './contracts';
import { Forms } from './forms';
import { jsonBody } from './http';
import type { Repository } from './repository';
import { getPDF, presignPDF, promoteUpload, putPDF, removePDF } from './storage';

const largeBody = 1_500_000;
const pdfFile = (bytes: Uint8Array, name: string) => new Response(Buffer.from(bytes), { headers: { 'Content-Type': 'application/pdf', 'Cache-Control': 'private, no-store', 'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(name)}` } });
async function uploadedPDF(req: Request) {
    const form = await req.formData();
    const file = form.get('file');
    if (!(file instanceof File) || file.size < 5)
        throw new ApiError(400, 'Choose a PDF');
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (new TextDecoder().decode(bytes.slice(0, 5)) !== '%PDF-')
        throw new ApiError(400, 'Only PDF documents are supported');
    return { form, file, bytes };
}
/** Makes a version current, then starts reading it if this is the first time. */
async function becomeCurrent(repo: Repository, forms: Forms, documentId: string, versionId: string) {
    const { needsExtraction } = await forms.setCurrentVersion(documentId, versionId);
    if (needsExtraction) {
        await repo.claimDocument(documentId);
        after(() => processUploadedDocument(repo, documentId));
    }
}

/** Forms, signing, and versions. Returns null when the path belongs to the main API routes. */
export async function paperworkRoute(repo: Repository, req: Request, p: string[]): Promise<Response | null> {
    const method = req.method;
    const forms = new Forms(repo.owner);
    if (method === 'GET' && ((p[0] === 'library' && p.length === 1) ||
        (p[0] === 'groups' && p[2] === 'overview' && p.length === 3))) {
        const [groups, requests, overview] = await Promise.all([
            repo.groups(), forms.signingRequests(),
            p[0] === 'groups' ? forms.overview(p[1], parseDocumentSort(req.url)) : Promise.resolve({ documents: [], views: [], forms: [] }),
        ]);
        return Response.json({ ...overview, groups, requests });
    }
    if (p[0] === 'form-templates' && p.length === 2 && method === 'PATCH') {
        const b = templateEdit.parse(await jsonBody(req, largeBody));
        return Response.json(await forms.updateTemplate(p[1], b.title, b.sections));
    }
    if (p[0] === 'forms' && p.length === 2) {
        if (method === 'GET')
            return Response.json(await forms.form(p[1]));
        if (method === 'PATCH') {
            const b = formSave.parse(await jsonBody(req, largeBody));
            return Response.json(await forms.saveValues(p[1], b.revision, b.values, b.title));
        }
        if (method === 'DELETE') {
            await forms.deleteForm(p[1]);
            return Response.json({ ok: true });
        }
    }
    if (p[0] === 'forms' && p[2] === 'signed-pdf' && p.length === 3 && method === 'GET') {
        const { key, name } = await forms.signedFile(p[1]);
        return pdfFile(await getPDF(key), name);
    }
    // Without presigned storage, as in local development, the signed PDF comes through the API.
    if (p[0] === 'forms' && p[2] === 'sign' && p.length === 3 && method === 'POST') {
        const requestId = await forms.signingContext(p[1]);
        const { form, file, bytes } = await uploadedPDF(req);
        const uploadId = randomUUID();
        await putPDF(`${uploadId}.pdf`, bytes);
        await forms.markSigned(requestId, [{ formId: p[1], uploadId, key: `${uploadId}.pdf`, size: file.size, method: signatureMethodInput.parse(form.get('method')) }]);
        return Response.json({ requests: await forms.signingRequests() });
    }
    if (p[0] === 'signing-requests') {
        if (p.length === 1 && method === 'GET')
            return Response.json({ requests: await forms.signingRequests() });
        if (p.length === 1 && method === 'POST') {
            const b = signingCreate.parse(await jsonBody(req));
            const id = await forms.addToSigning(b.formIds, b.requestId, b.title);
            return Response.json({ id, requests: await forms.signingRequests() }, { status: 201 });
        }
        if (p.length === 2 && method === 'DELETE') {
            await forms.deleteSigningRequest(p[1]);
            return Response.json({ requests: await forms.signingRequests() });
        }
        if (p[2] === 'remove' && p.length === 3 && method === 'POST') {
            const b = z.object({ formId: z.string().min(1) }).parse(await jsonBody(req));
            await forms.removeFromSigning(p[1], b.formId);
            return Response.json({ requests: await forms.signingRequests() });
        }
        if (p[2] === 'uploads' && p.length === 3 && method === 'POST') {
            const b = signingUploads.parse(await jsonBody(req));
            const items = await Promise.all(b.items.map(async item => {
                const stagingKey = `${randomUUID()}.pdf`;
                return { ...item, uploadId: randomUUID(), stagingKey, url: await presignPDF(stagingKey, item.size) };
            }));
            if (items.some(item => !item.url))
                return Response.json({ mode: 'local', uploads: [] });
            await forms.stageSignedUploads(p[1], items);
            return Response.json({ mode: 'direct', uploads: items.map(({ formId, uploadId, url }) => ({ formId, uploadId, url })) });
        }
        if (p[2] === 'complete' && p.length === 3 && method === 'POST') {
            const b = signingComplete.parse(await jsonBody(req));
            const uploads = await forms.pendingSignedUploads(p[1], b.items);
            await Promise.all(uploads.map(u => promoteUpload(u.stagingKey, `${u.uploadId}.pdf`, u.size)));
            const methods = new Map(b.items.map(item => [item.formId, item.method]));
            await forms.markSigned(p[1], uploads.map(u => ({ formId: u.formId, uploadId: u.uploadId, key: `${u.uploadId}.pdf`, size: u.size, method: methods.get(u.formId)!, stagingKey: u.stagingKey })));
            return Response.json({ requests: await forms.signingRequests() });
        }
    }
    if (p[0] !== 'documents')
        return null;
    const id = p[1];
    if (p[2] === 'workspace' && p.length === 3 && method === 'GET')
        return Response.json(await forms.workspace(id));
    if (p[2] === 'form-template' && p.length === 3 && method === 'POST') {
        const { widgets, pageCount, regenerate, textRegions } = templateRequest.parse(await jsonBody(req, largeBody));
        const context = await forms.templateContext(id);
        const run = async (progress: (message: string) => void = () => {}) => {
            const template = (!regenerate && context.template) || await createFormTemplate(forms, context.document, context.versionId, widgets, pageCount, textRegions, progress, req.signal);
            const form = await forms.createForm(id, template.id, null, true);
            return { template, form };
        };
        if (req.headers.get('accept')?.includes('application/x-ndjson')) {
            const encoder = new TextEncoder();
            const stream = new ReadableStream({
                async start(controller) {
                    const send = (event: unknown) => controller.enqueue(encoder.encode(JSON.stringify(event) + '\n'));
                    try {
                        const result = await run(message => send({ type: 'progress', message }));
                        send({ type: 'result', result });
                    } catch (error) {
                        send({ type: 'error', message: error instanceof ApiError ? error.message : 'Form generation failed. Please try again.' });
                    } finally { controller.close(); }
                },
            });
            return new Response(stream, { headers: { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store' } });
        }
        return Response.json(await run(), { status: 201 });
    }
    if (p[2] === 'forms' && p.length === 3 && method === 'POST') {
        const b = z.object({ templateId: z.string().min(1), title: z.string().trim().min(1).max(150).nullish() }).parse(await jsonBody(req));
        return Response.json(await forms.createForm(id, b.templateId, b.title), { status: 201 });
    }
    if (p[2] !== 'versions')
        return null;
    if (p.length === 3 && method === 'POST') {
        const document = await repo.document(id);
        if (document.status === 'processing')
            throw new ApiError(409, 'Wait for processing to finish');
        const { form, file, bytes } = await uploadedPDF(req);
        const versionId = randomUUID();
        await putPDF(`${versionId}.pdf`, bytes);
        try {
            await forms.addVersion(id, versionId, file.name, file.size);
        } catch (e) {
            await removePDF(`${versionId}.pdf`);
            throw e;
        }
        if (form.get('makeCurrent') === 'true')
            await becomeCurrent(repo, forms, id, versionId);
        return Response.json(await forms.workspace(id), { status: 201 });
    }
    if (p[3] === 'uploads' && method === 'POST') {
        if (p.length === 4) {
            const input = z.object({ name: z.string().min(1).max(255), size: z.number().int().min(5) }).parse(await jsonBody(req));
            const document = await repo.document(id);
            const uploadId = randomUUID();
            const stagingKey = `${randomUUID()}.pdf`;
            const url = await presignPDF(stagingKey, input.size);
            if (!url)
                return Response.json({ mode: 'local' });
            await forms.stageVersionUpload(id, document.groupId, uploadId, input.name, input.size, stagingKey);
            return Response.json({ mode: 'direct', id: uploadId, url });
        }
        if (p.length === 6 && p[5] === 'complete') {
            const b = z.object({ makeCurrent: z.boolean().default(true) }).parse(await jsonBody(req));
            const upload = await forms.stagedVersion(id, p[4]);
            // A retry after a lost response finds the version already saved.
            if (!upload.already) {
                if (Number(upload.expires_at) < Date.now())
                    throw new ApiError(410, 'Upload expired. Upload again to retry.');
                await promoteUpload(String(upload.staging_key), `${p[4]}.pdf`, Number(upload.size));
                await forms.addVersion(id, p[4], String(upload.name), Number(upload.size), String(upload.staging_key));
            }
            if (b.makeCurrent)
                await becomeCurrent(repo, forms, id, p[4]);
            return Response.json(await forms.workspace(id), { status: 201 });
        }
    }
    if (p[3] && p.length === 4 && method === 'DELETE') {
        await forms.deleteVersion(id, p[3]);
        return Response.json(await forms.workspace(id));
    }
    if (p[3] && p[4] === 'current' && p.length === 5 && method === 'POST') {
        await becomeCurrent(repo, forms, id, p[3]);
        return Response.json(await forms.workspace(id));
    }
    if (p[3] && p[4] === 'pdf' && p.length === 5 && method === 'GET') {
        const { key, name } = await forms.versionKey(id, p[3]);
        return pdfFile(await getPDF(key), name);
    }
    return null;
}
