import nextEnv from '@next/env';
import { fileURLToPath } from 'node:url';

// Standalone scripts do not get Next.js's automatic .env loading.
nextEnv.loadEnvConfig(fileURLToPath(new URL('../', import.meta.url)), process.env.NODE_ENV !== 'production');
