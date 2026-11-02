import './env';
import { db, expirePDFUploads } from '../lib/db';
import { purgeExpiredGroups } from '../lib/repository';
import { removePDF } from '../lib/storage';
await purgeExpiredGroups();
    await expirePDFUploads();
const rows = await db().execute('SELECT storage_key FROM gc LIMIT 1000');
let failed = 0;
for (const row of rows.rows) {
    try {
        await removePDF(String(row.storage_key));
        await db().execute({ sql: 'DELETE FROM gc WHERE storage_key=?', args: [row.storage_key] });
    }
    catch {
        failed++;
    }
}
console.log(`Processed ${rows.rows.length} queued files; ${failed} remain for retry.`);
process.exitCode = failed ? 1 : 0;
