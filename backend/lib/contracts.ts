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
const unit = z.number().min(0).max(1);
/** A box on a page as fractions of the page as displayed: rotated and cropped, with y running down. */
export const placementInput = z.object({ page: z.number().int().min(0).max(10000), x: unit, y: unit, w: unit, h: unit, manual: z.boolean().optional().describe('The user positioned this box by hand'), part: z.enum(['day', 'month', 'year']).optional().describe('The piece of a date written here, when a date spans several boxes') });
export type Placement = z.infer<typeof placementInput>;
export const fieldTypes = ['text', 'multiline', 'date', 'number', 'checkbox', 'choice', 'signature'] as const;
export const formFieldInput = z.object({
    id: z.string().min(1).max(64),
    label: z.string().trim().min(1).max(200),
    type: z.enum(fieldTypes),
    required: z.boolean().default(false),
    help: z.string().max(500).nullish(),
    placements: z.array(placementInput).max(50).default([]).describe('Where the value is written; a repeated field has several'),
    options: z.array(z.object({ value: z.string().max(300), label: z.string().max(200), placements: z.array(placementInput).max(10).default([]) })).max(200).default([]).describe('Choices; an option with placements is marked there, like a radio button'),
    widgets: z.array(z.string().max(500)).max(50).default([]).describe('Names of the PDF form fields this one replaces'),
    defaultValue: z.union([z.string().max(20000), z.boolean()]).nullish(),
});
export type FormField = z.infer<typeof formFieldInput>;
export const formSectionsInput = z.array(z.object({
    id: z.string().min(1).max(64),
    title: z.string().trim().min(1).max(120),
    footer: z.string().max(500).nullish(),
    fields: z.array(formFieldInput).max(500),
})).max(100).refine(sections => {
    const ids = sections.flatMap(s => s.fields.map(f => f.id));
    return ids.length <= 2000 && new Set(ids).size === ids.length;
}, 'Field IDs must be unique, with at most 2000 fields');
export type FormSection = z.infer<typeof formSectionsInput>[number];
/** What the app finds in a PDF's own form, one entry per widget on a page. */
export const pdfWidgetInput = placementInput.extend({
    name: z.string().max(500),
    kind: z.enum(['text', 'multiline', 'checkbox', 'radio', 'choice', 'signature']),
    label: z.string().max(500).nullish(),
    value: z.string().max(20000).nullish(),
    onState: z.string().max(300).nullish(),
    options: z.array(z.string().max(300)).max(200).default([]),
});
export type PDFWidget = z.infer<typeof pdfWidgetInput>;
export const templateRequest = z.object({ textRegions: z.array(placementInput).max(10000).default([]), regenerate: z.boolean().default(false), pageCount: z.number().int().min(1).max(10000), widgets: z.array(pdfWidgetInput).max(3000).default([]) });
export const templateEdit = z.object({ title: z.string().trim().min(1).max(150), sections: formSectionsInput });
/** Autosave keeps only values, keyed by field ID. */
export const formSave = z.object({
    revision: z.number().int().min(0),
    title: z.string().trim().min(1).max(150).optional(),
    values: z.record(z.string().max(64), z.union([z.string().max(20000), z.boolean(), z.null()])).refine(v => Object.keys(v).length <= 2000, 'Too many values'),
});
const formIds = z.array(z.string().min(1).max(64)).min(1).max(100);
export const signingCreate = z.object({ formIds, requestId: z.string().min(1).nullish(), title: z.string().trim().min(1).max(150).nullish() });
export const signingUploads = z.object({ items: z.array(z.object({ formId: z.string().min(1), size: z.number().int().min(5) })).min(1).max(100) });
const signatureMethod = z.enum(['drawn', 'trackpad', 'typed']);
export const signingComplete = z.object({ items: z.array(z.object({ formId: z.string().min(1), uploadId: z.string().min(1), method: signatureMethod })).min(1).max(100) });
export const signatureMethodInput = signatureMethod;
