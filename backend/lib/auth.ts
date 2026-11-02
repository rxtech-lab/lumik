import { createRemoteJWKSet, jwtVerify } from 'jose';
import { ApiError } from './contracts';
const keys = new Map<string, ReturnType<typeof createRemoteJWKSet>>();
export async function principal(request: Request) {
    const token = request.headers.get('authorization')?.match(/^Bearer (.+)$/)?.[1];
    if (!token)
        throw new ApiError(401, 'Sign in with RxLab to continue');
    const issuer = process.env.AUTH_ISSUER?.replace(/\/$/, '');
    const clients = (process.env.RXLAB_ALLOWED_CLIENT_IDS ?? '').split(',').map(x => x.trim()).filter(Boolean);
    if (!issuer || !clients.length)
        throw new ApiError(503, 'RxLab authentication is not configured');
    let key = keys.get(issuer);
    if (!key) {
        key = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));
        keys.set(issuer, key);
    }
    return verifyAccessToken(token, issuer, clients, key);
}
export async function verifyAccessToken(token: string, issuer: string, clients: string[], key: Parameters<typeof jwtVerify>[1]) {
    try {
        const { payload } = await jwtVerify(token, key, { issuer, algorithms: ['RS256'], requiredClaims: ['sub', 'exp', 'client_id'] });
        if (!payload.sub || !clients.includes(String(payload.client_id)))
            throw new Error('Wrong client');
        return payload.sub;
    }
    catch {
        throw new ApiError(401, 'Your session expired. Sign in again.');
    }
}
