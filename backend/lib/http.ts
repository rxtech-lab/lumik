import { ZodError } from 'zod';
import { ApiError } from './contracts';
export function errorResponse(e: unknown) {
    const status = e instanceof ApiError ? e.status : e instanceof ZodError || e instanceof SyntaxError ? 400 : 500;
    return Response.json({ error: status === 500 ? 'The request could not be completed. Please try again.' : (e as Error).message }, { status });
}
export async function boundedBody(request: Request, limit: number) {
    if (Number(request.headers.get('content-length') ?? 0) > limit)
        throw new ApiError(413, 'Request too large');
    const reader = request.body?.getReader();
    if (!reader)
        return new Uint8Array();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done)
                break;
            size += value.byteLength;
            if (size > limit) {
                await reader.cancel();
                throw new ApiError(413, 'Request too large');
            }
            chunks.push(value);
        }
    }
    finally {
        reader.releaseLock();
    }
    const result = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        result.set(chunk, offset);
        offset += chunk.byteLength;
    }
    return result;
}
export async function jsonBody(request: Request) { return JSON.parse(new TextDecoder().decode(await boundedBody(request, 64000))); }
