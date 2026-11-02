import './env';
import { migrate } from '../lib/db';
await migrate();
console.log('Scanner Buddy database migrated.');
