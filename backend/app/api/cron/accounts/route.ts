import { purgeAccounts } from '@/lib/account';
import { db } from '@/lib/db';
import { removePDF } from '@/lib/storage';
export const runtime = 'nodejs';
export async function GET(request: Request) {
    if (!process.env.CRON_SECRET || request.headers.get('authorization') !== `Bearer ${process.env.CRON_SECRET}`) return new Response(null,{status:401});
    await purgeAccounts();
    const rows=await db().execute('SELECT storage_key FROM gc LIMIT 1000');
    let failed=0;
    for(const row of rows.rows) {
        try { await removePDF(String(row.storage_key)); await db().execute({sql:'DELETE FROM gc WHERE storage_key=?',args:[row.storage_key]}); }
        catch { failed++; }
    }
    return Response.json({processed:rows.rows.length,failed},{status:failed ? 503:200});
}
