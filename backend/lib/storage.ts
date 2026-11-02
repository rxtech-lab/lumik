import { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { ApiError } from './contracts';
function local() { return process.env.NODE_ENV !== 'production' ? process.env.LOCAL_STORAGE_DIR : undefined; }
function s3() {
    if (!process.env.S3_BUCKET)
        throw new ApiError(503, 'Private PDF storage is not configured');
    return new S3Client({ region: process.env.S3_REGION ?? 'auto', endpoint: process.env.S3_ENDPOINT || undefined, forcePathStyle: !!process.env.S3_ENDPOINT });
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
