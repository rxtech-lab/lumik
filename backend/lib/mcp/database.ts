import { drizzle } from 'drizzle-orm/libsql';
import { db } from '@/lib/db';
export function getDatabase() { return drizzle(db()); }
export type Database = ReturnType<typeof getDatabase>;
