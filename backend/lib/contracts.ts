import { z } from 'zod';
import Ajv from 'ajv';
export class ApiError extends Error {
    constructor(public status: number, message: string) { super(message); }
}
export type Schema = Record<string, unknown>;
const ajv = new Ajv({ strict: false, allErrors: true, validateFormats: false });
export function validateSchema(schema: Schema) {
    if (JSON.stringify(schema).length > 24000)
        throw new ApiError(400, 'Schema is too large');
    function visit(node: unknown, depth = 0) {
        if (depth > 10)
            throw new ApiError(400, 'Schema is too deeply nested');
        if (node && typeof node === 'object')
            for (const [key, value] of Object.entries(node)) {
                if (['$ref', '$dynamicRef', 'pattern', 'patternProperties'].includes(key))
                    throw new ApiError(400, `${key} is not supported`);
                visit(value, depth + 1);
            }
    }
    visit(schema);
    if (schema.type !== 'object' || !schema.properties || Array.isArray(schema.properties) || typeof schema.properties !== 'object')
        throw new ApiError(400, 'Schema must describe an object with properties');
    try {
        ajv.compile(schema);
    }
    catch {
        throw new ApiError(400, 'Invalid JSON Schema');
    }
    return schema;
}
export function validateData(schema: Schema, data: unknown) {
    validateSchema(schema);
    const validate = ajv.compile(schema);
    if (!validate(data))
        throw new ApiError(422, ajv.errorsText(validate.errors));
}
export const groupInput = z.object({ name: z.string().trim().min(1).max(100), instructions: z.string().max(4000).default(''), namingTemplate: z.string().min(1).max(200).default('{date}-{title}'), extractAdditional: z.boolean().default(false), schema: z.record(z.string(), z.unknown()).refine(s => { validateSchema(s); return true; }) });
export type GroupInput = z.infer<typeof groupInput>;
/** A group's place in the tree is set when it is created. */
export const newGroupInput = groupInput.extend({ parentId: z.string().min(1).nullish().describe('Create this as a subgroup of that group') });
export type Group = GroupInput & {
    id: string;
    parentId: string | null;
    /** The inbox holds scans that have not been filed yet. Each account has one. */
    kind: 'group' | 'inbox';
    createdAt: string;
    documentCount: number;
};
export type DeletedGroup = Group & { deletedAt: string; purgeAt: string };
export type Additional = { facts: Record<string, unknown>; spec: Record<string, unknown> };
export type Document = {
    id: string;
    groupId: string;
    name: string;
    originalName: string;
    status: string;
    data: unknown;
    /** Facts beyond the schema and a generated view of them, when the group asks for them. */
    additional: Additional | null;
    error: string | null;
    createdAt: string;
    size: number;
    storageKey: string;
};
export function safeName(value: string) { return value.normalize('NFKC').replace(/[\x00-\x1f\\/:*?"<>|]/g, '-').replace(/^\.+/, '').trim().slice(0, 150) || 'document'; }
export function pdfName(template: string, data: Record<string, unknown>, title: string) {
    const values = { ...data, title, date: new Date().toISOString().slice(0, 10) };
    return safeName(template.replace(/\{([^}]+)\}/g, (_, key) => String(values[key as keyof typeof values] ?? 'unknown')).replace(/\.pdf$/i, '')) + '.pdf';
}
export const viewInput = z.object({
    kind: z.enum(['statistic', 'filter']),
    title: z.string().trim().min(1).max(100),
    spec: z.record(z.string(), z.unknown()),
    // Each SQL result is exposed to the spec at /queries/<name>. A filter's "documents" query selects its results.
    queries: z.record(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/), z.string().min(1).max(8000)).refine(q => Object.keys(q).length <= 12, 'Use at most 12 queries'),
});
export type GroupView = z.infer<typeof viewInput> & { id: string; groupId: string; createdAt: string };
const organizeGroup = z.object({
    ref: z.string().trim().min(1).max(64).describe('Your label for this new group. Moves and later new groups point to it.'),
    parent: z.string().min(1).optional().describe('Makes this a subgroup: an existing group ID, or the ref of an earlier new group'),
    name: z.string().trim().min(1).max(100),
    instructions: z.string().max(4000).optional(),
    namingTemplate: z.string().min(1).max(200).optional(),
    extractAdditional: z.boolean().optional(),
    schema: z.record(z.string(), z.unknown()).refine(s => { validateSchema(s); return true; }).optional().describe('Required without a parent. A subgroup that omits it uses its parent\'s fields, instructions, and naming.'),
});
export type OrganizeGroup = z.infer<typeof organizeGroup>;
export const mutationInput = z.discriminatedUnion('action', [
    z.object({ action: z.literal('create_view'), groupId: z.string(), view: viewInput }),
    z.object({ action: z.literal('update_view'), groupId: z.string(), viewId: z.string(), view: viewInput }),
    z.object({ action: z.literal('delete_view'), groupId: z.string(), viewId: z.string() }),
    z.object({ action: z.literal('create_group'), group: newGroupInput }),
    z.object({ action: z.literal('update_group'), groupId: z.string(), group: groupInput }),
    z.object({ action: z.literal('delete_group'), groupId: z.string() }),
    z.object({ action: z.literal('delete_document'), documentId: z.string() }),
    z.object({ action: z.literal('update_document'), documentId: z.string(), name: z.string().min(1).max(150), data: z.record(z.string(), z.unknown()) }),
    z.object({ action: z.literal('rename_document'), documentId: z.string(), name: z.string().min(1).max(150) }),
    z.object({
        action: z.literal('organize_documents'),
        newGroups: z.array(organizeGroup).max(20).default([]).describe('Groups and subgroups to create first, parents before their children'),
        moves: z.array(z.object({ documentId: z.string(), target: z.string().min(1).describe('An existing group ID, or the ref of a new group') })).max(100).default([]),
    }),
]);
