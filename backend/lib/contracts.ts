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
export const groupInput = z.object({ name: z.string().trim().min(1).max(100), instructions: z.string().max(4000).default(''), namingTemplate: z.string().min(1).max(200).default('{date}-{title}'), schema: z.record(z.string(), z.unknown()).refine(s => { validateSchema(s); return true; }) });
export type GroupInput = z.infer<typeof groupInput>;
export type Group = GroupInput & {
    id: string;
    createdAt: string;
    documentCount: number;
};
export type Document = {
    id: string;
    groupId: string;
    name: string;
    originalName: string;
    status: string;
    data: unknown;
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
export const mutationInput = z.discriminatedUnion('action', [
    z.object({ action: z.literal('create_group'), group: groupInput }),
    z.object({ action: z.literal('update_group'), groupId: z.string(), group: groupInput }),
    z.object({ action: z.literal('delete_group'), groupId: z.string() }),
    z.object({ action: z.literal('delete_document'), documentId: z.string() }),
    z.object({ action: z.literal('update_document'), documentId: z.string(), name: z.string().min(1).max(150), data: z.record(z.string(), z.unknown()) }),
]);
