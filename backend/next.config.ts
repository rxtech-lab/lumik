import type { NextConfig } from 'next';
const config: NextConfig = {
    // These load WASM at runtime, so they must not be bundled.
    serverExternalPackages: ['quickjs-emscripten', 'sql.js'],
    // The SQL worker is started by path, which file tracing cannot see.
    outputFileTracingIncludes: { '/api/**': ['./legal/*.md', './workers/**', './node_modules/sql.js/dist/sql-wasm.js', './node_modules/sql.js/dist/sql-wasm.wasm'] },
};
export default config;
