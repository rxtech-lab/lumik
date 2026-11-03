import { ApiError as BaseError } from '@/lib/contracts';
export class ApiError extends BaseError {
  constructor(status: number, public code: string, message: string) { super(status, message); }
}
export function noStoreJson(body: unknown, init: ResponseInit = {}) {
  const headers = new Headers(init.headers);
  headers.set('cache-control', 'no-store');
  return Response.json(body, { ...init, headers });
}
