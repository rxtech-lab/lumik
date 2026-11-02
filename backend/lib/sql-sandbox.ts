import { join } from 'node:path';
import { Worker } from 'node:worker_threads';
import { ApiError } from './contracts';
export type SandboxData = { groups: Record<string, unknown>[]; documents: Record<string, unknown>[] };
export type SQLParam = string | number | null;
export type SQLResult = { columns: string[]; rows: Record<string, unknown>[] };
export const sqlTables = 'documents(id, group_id, name, original_name, status, size, created_at, data, additional) and groups(id, name, instructions, created_at). data is the JSON of the schema fields and additional is the JSON of other facts; read them with json_extract(data, \'$.field\') and json_each. created_at is the upload time as ISO 8601. SQLite syntax. Named parameters look like :vendor. At most 1000 rows return.';
/**
 * Runs agent-written SQL on a private copy of only `data`. Turso is never exposed to it, so a
 * query cannot reach another account's rows however it is written.
 */
export function runSQL(data: SandboxData, queries: Record<string, { sql: string; params?: Record<string, SQLParam> }>, timeoutMs = 3000): Promise<Record<string, SQLResult>> {
    return new Promise((resolve, reject) => {
        const worker = new Worker(join(process.cwd(), 'workers/sql-sandbox.cjs'), { workerData: { ...data, queries }, env: {}, resourceLimits: { maxOldGenerationSizeMb: 128 } });
        const finish = (settle: () => void) => { clearTimeout(timer); void worker.terminate(); settle(); };
        const timer = setTimeout(() => finish(() => reject(new ApiError(422, 'The query took too long'))), timeoutMs);
        worker.once('message', (message: { results?: Record<string, SQLResult>; error?: string }) => finish(() => message.results ? resolve(message.results) : reject(new ApiError(422, `SQL error in ${message.error}`))));
        worker.once('error', () => finish(() => reject(new ApiError(422, 'The query could not be completed'))));
    });
}
