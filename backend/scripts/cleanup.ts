import './env';
import { db } from '../lib/db';
import { removePDF } from '../lib/storage';
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
