import { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand, CopyObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { ApiError } from './contracts';
function local() { return process.env.NODE_ENV !== 'production' ? process.env.LOCAL_STORAGE_DIR : undefined; }
function s3() {
    if (!process.env.S3_BUCKET)
        throw new ApiError(503, 'Private PDF storage is not configured');
    return new S3Client({ requestChecksumCalculation: 'WHEN_REQUIRED', region: process.env.S3_REGION ?? 'auto', endpoint: process.env.S3_ENDPOINT || undefined, forcePathStyle: !!process.env.S3_ENDPOINT });
}
function path(key: string) { if (!/^[a-f0-9-]+\.pdf$/.test(key))
    throw new Error('Invalid storage key'); return join(local()!, key); }
export async function putPDF(key: string, bytes: Uint8Array) {
    if (local()) {
        await mkdir(local()!, { recursive: true });
        await writeFile(path(key), bytes);
        return;
    }
    await s3().send(new PutObjectCommand({ Bucket: process.env.S3_BUCKET, Key: key, Body: bytes, ContentType: 'application/pdf' }));
}
export async function getPDF(key: string): Promise<Uint8Array> {
    if (local())
        return new Uint8Array(await readFile(path(key)));
    const result = await s3().send(new GetObjectCommand({ Bucket: process.env.S3_BUCKET, Key: key }));
    if (!result.Body)
        throw new ApiError(404, 'PDF not found');
    return result.Body.transformToByteArray();
}
export async function removePDF(key: string) {
    if (local()) {
        try {
            await unlink(path(key));
        }
        catch (e) {
            if ((e as NodeJS.ErrnoException).code !== 'ENOENT')
                throw e;
        }
        return;
    }
    await s3().send(new DeleteObjectCommand({ Bucket: process.env.S3_BUCKET, Key: key }));
}

export async function presignPDF(key: string, size: number) {
    if (local()) return null;
    return getSignedUrl(s3(), new PutObjectCommand({ Bucket: process.env.S3_BUCKET, Key: key,
        ContentType: 'application/pdf', ContentLength: size }), { expiresIn: 600 });
}
/**
 * Copies a staged upload inside the bucket, so its size never has to fit in function memory.
 * Validates the copy because the upload URL can still overwrite the staged object, but not this key.
 */
export async function promoteUpload(stagingKey: string, key: string, size: number) {
    const client = s3();
    const Bucket = process.env.S3_BUCKET;
    await client.send(new CopyObjectCommand({ Bucket, Key: key, CopySource: `${Bucket}/${stagingKey}`, ContentType: 'application/pdf' }));
    const head = await client.send(new GetObjectCommand({ Bucket, Key: key, Range: 'bytes=0-4' }));
    const magic = await head.Body?.transformToString();
    const problem = Number(head.ContentRange?.split('/')[1]) !== size ? 'Uploaded PDF size does not match'
        : magic !== '%PDF-' ? 'Only PDF documents are supported' : null;
    if (problem) {
        await removePDF(key);
        throw new ApiError(400, problem);
    }
}
