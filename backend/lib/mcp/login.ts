import { createRemoteJWKSet } from 'jose';
import { verifyAccessToken } from '@/lib/auth';
const keys = new Map<string, ReturnType<typeof createRemoteJWKSet>>();
export async function verifyLogin(token: string, issuer: string, client: string) {
  let key = keys.get(issuer);
  if (!key) { key = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`)); keys.set(issuer, key); }
  return { sub: await verifyAccessToken(token, issuer, [client], key) };
}
