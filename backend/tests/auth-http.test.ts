import { describe, expect, it } from 'vitest';
import { generateKeyPair, SignJWT } from 'jose';
import { principal, verifyAccessToken } from '../lib/auth';
import { boundedBody } from '../lib/http';
describe('RxLab token boundary', () => {
    it('requires a bearer token', async () => { await expect(principal(new Request('https://scanner.test/api/v1/groups'))).rejects.toMatchObject({ status: 401 }); });
    it('checks signature, issuer, expiration, subject and allowed client', async () => {
        const keys = await generateKeyPair('RS256');
        const other = await generateKeyPair('RS256');
        const sign = (client = 'scanner', issuer = 'https://auth.rxlab.app', expiry = '5m') => new SignJWT({ client_id: client }).setProtectedHeader({ alg: 'RS256' }).setIssuer(issuer).setSubject('alice').setExpirationTime(expiry).sign(keys.privateKey);
        const token = await sign();
        expect(await verifyAccessToken(token, 'https://auth.rxlab.app', ['scanner'], keys.publicKey)).toBe('alice');
        await expect(verifyAccessToken(token, 'https://auth.rxlab.app', ['scanner'], other.publicKey)).rejects.toMatchObject({ status: 401 });
        await expect(verifyAccessToken(await sign('unrelated'), 'https://auth.rxlab.app', ['scanner'], keys.publicKey)).rejects.toMatchObject({ status: 401 });
        await expect(verifyAccessToken(await sign('scanner', 'https://wrong.test'), 'https://auth.rxlab.app', ['scanner'], keys.publicKey)).rejects.toMatchObject({ status: 401 });
        await expect(verifyAccessToken(await sign('scanner', 'https://auth.rxlab.app', '-1m'), 'https://auth.rxlab.app', ['scanner'], keys.publicKey)).rejects.toMatchObject({ status: 401 });
    });
});
it('enforces actual body size without trusting Content-Length', async () => {
    const request = new Request('https://scanner.test', { method: 'POST', body: '12345678' });
    await expect(boundedBody(request, 4)).rejects.toMatchObject({ status: 413 });
    expect(new TextDecoder().decode(await boundedBody(new Request('https://scanner.test', { method: 'POST', body: '1234' }), 4))).toBe('1234');
});
