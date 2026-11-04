import { z } from 'zod';

const sortSchema = z.object({
    sortBy: z.enum(['name', 'createdAt', 'size']).default('createdAt'),
    sortDirection: z.enum(['asc', 'desc']).default('desc'),
});
export type DocumentSort = z.infer<typeof sortSchema>;
export function parseDocumentSort(url: string): DocumentSort {
    return sortSchema.parse(Object.fromEntries(new URL(url).searchParams));
}
/** Only allowlisted SQL fragments; ID breaks ties for future pagination. */
export function documentOrder(sort: Partial<DocumentSort> = {}): string {
    const { sortBy, sortDirection } = sortSchema.parse(sort);
    const columns = { name: 'd.name COLLATE NOCASE', createdAt: 'd.created_at', size: 'd.size' };
    const direction = sortDirection === 'asc' ? 'ASC' : 'DESC';
    return `${columns[sortBy]} ${direction}, d.id ${direction}`;
}
