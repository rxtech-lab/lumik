// Runs one SQL request against a throwaway copy of the caller's rows, in SQLite compiled to WASM.
// It has no access to Turso or the host filesystem, and the parent terminates it on a timeout.
const { parentPort, workerData } = require('node:worker_threads');
const initSqlJs = require('sql.js');
const MAX_ROWS = 1000;
function load(db, table, columns, rows) {
    db.run(`CREATE TABLE ${table} (${columns.join(',')})`);
    const insert = db.prepare(`INSERT INTO ${table} VALUES (${columns.map(() => '?').join(',')})`);
    for (const row of rows)
        insert.run(columns.map(column => row[column] ?? null));
    insert.free();
}
function run(db, { sql, params }) {
    if (!/^\s*(select|with)\b/i.test(sql))
        throw new Error('Only SELECT statements are allowed');
    const statement = db.prepare(sql);
    try {
        statement.bind(Object.fromEntries(Object.entries(params ?? {}).map(([key, value]) => [`:${key}`, value])));
        const columns = statement.getColumnNames();
        if (!columns.length)
            throw new Error('Only SELECT statements are allowed');
        const rows = [];
        while (rows.length < MAX_ROWS && statement.step()) {
            const row = statement.getAsObject();
            for (const key of Object.keys(row))
                if (row[key] instanceof Uint8Array)
                    row[key] = null;
            rows.push(row);
        }
        return { columns, rows };
    }
    finally {
        statement.free();
    }
}
initSqlJs().then(SQL => {
    const db = new SQL.Database();
    load(db, 'groups', ['id', 'parent_id', 'kind', 'name', 'instructions', 'created_at'], workerData.groups);
    load(db, 'documents', ['id', 'group_id', 'name', 'original_name', 'status', 'size', 'created_at', 'data', 'additional'], workerData.documents);
    const results = {};
    for (const [name, query] of Object.entries(workerData.queries)) {
        try {
            results[name] = run(db, query);
        }
        catch (error) {
            parentPort.postMessage({ error: `${name}: ${error.message}` });
            return;
        }
    }
    parentPort.postMessage({ results });
}).catch(error => parentPort.postMessage({ error: error.message }));
