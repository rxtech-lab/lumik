import './env';
import { migrate } from '../lib/db';
await migrate();
console.log('Lumik database migrated.');
