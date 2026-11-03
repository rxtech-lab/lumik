import { db } from './db';
import { ApiError } from './contracts';
export async function account(owner: string, method = 'GET') {
    const client = db();
    if (method === 'POST') await client.execute({sql: 'INSERT OR IGNORE INTO account_deletions(owner,delete_at) VALUES(?,?)', args:[owner, Date.now()+7*86400000]});
    if (method === 'DELETE') await client.execute({sql:'DELETE FROM account_deletions WHERE owner=? AND delete_at>? AND completed=0',args:[owner,Date.now()]});
    const rows = await client.execute({sql:'SELECT delete_at,completed FROM account_deletions WHERE owner=?',args:[owner]});
    const deletion = rows.rows[0];
    if (deletion && Number(deletion.delete_at)<=Date.now()) throw new ApiError(403,'This Lumik account has been deleted.');
    const usage = await client.execute({sql:'SELECT COALESCE(SUM(size),0) used FROM documents WHERE owner=?',args:[owner]});
    return {usedBytes:Number(usage.rows[0].used),limitBytes:null,deleteAt:deletion ? Number(deletion.delete_at):null};
}
export async function purgeAccounts() {
    const client=db();
    const expired='SELECT owner FROM account_deletions WHERE delete_at<=? AND completed=0';
    const args=[Date.now()];
    await client.batch([
        {sql:`INSERT OR IGNORE INTO gc SELECT storage_key FROM documents WHERE owner IN (${expired})`,args},
        {sql:`INSERT OR IGNORE INTO gc SELECT staging_key FROM pdf_uploads WHERE owner IN (${expired})`,args},
        ...['documents','group_views','groups','proposals','pdf_uploads','chat_messages'].map(table=>({sql:`DELETE FROM ${table} WHERE owner IN (${expired})`,args})),
        {sql:'UPDATE account_deletions SET completed=1 WHERE delete_at<=?',args},
    ],'write');
}
export async function assertAccountActive(owner:string) {
    const r=await db().execute({sql:'SELECT owner FROM account_deletions WHERE owner=? AND delete_at<=?',args:[owner,Date.now()]});
    if(r.rows.length) throw new ApiError(403,'This Lumik account has been deleted.');
}
