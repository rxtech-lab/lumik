import { defineCatalog, defineSchema, validateSpec, type Spec } from '@json-render/core';
import { z } from 'zod';
import { ApiError } from './contracts';
// The Apple app draws these specs natively (ios/Lumik/JSONRender.swift), so every
// component and expression allowed here must also be implemented there.
const schema = defineSchema(s => ({
    spec: s.object({
        root: s.string(),
        elements: s.record(s.object({
            type: s.ref('catalog.components'),
            props: s.propsOf('catalog.components'),
            children: s.array(s.string()),
            visible: { ...s.any(), ...s.optional() },
            repeat: { ...s.any(), ...s.optional() },
        })),
    }),
    catalog: s.object({ components: s.map({ props: s.zod(), description: s.string() }) }),
}), { promptTemplate: ({ catalog, formatZodType, options }) => {
    const { components } = catalog as { components: Record<string, { props: z.ZodType; description: string }> };
    const list = Object.entries(components).map(([name, c]) => `- ${name}: ${formatZodType(c.props)} - ${c.description}`).join('\n');
    return `A UI is one JSON object: { "root": "<key>", "elements": { "<key>": { "type": "<component>", "props": {}, "children": ["<key>"] } }, "state": {} }.
Every element needs type, props, and children ([] for a leaf). Every child key must exist in elements. Use only these components:
${list}

Any prop can be an expression instead of a literal:
- { "$state": "/path/0/field" } reads state with a JSON Pointer. Never use dot notation.
- { "$bindState": "/path" } reads and writes state. Use it for the value of input components.
- { "$template": "Total: \${/path}" } builds a string from state.
Lists: add "repeat": { "statePath": "/rows", "key": "id" } to a container to draw its children once per array item. Inside it, { "$item": "field" } reads the item and { "$index": true } is its position.
Conditions: add "visible": { "$state": "/path", "eq": "x" } to an element. Operators are eq, neq, gt, gte, lt, lte, and "not": true. Use $item instead of $state inside a repeat. Combine with [ ... ], { "$and": [ ... ] }, or { "$or": [ ... ] }.
There are no actions or events; do not use "on" or "watch". Never use sample, placeholder, or invented data.
${(options.customRules ?? []).join('\n')}`;
} });
// Props may be expressions, so a literal's type can only be checked once it is drawn.
const dynamic = z.unknown();
const format = z.enum(['number', 'currency', 'percent', 'date']).optional();
export const uiCatalog = defineCatalog(schema, { components: {
    Stack: { props: z.object({ direction: z.enum(['vertical', 'horizontal']).optional(), gap: z.enum(['small', 'medium', 'large']).optional() }), description: 'Lays out children in a row or column' },
    Grid: { props: z.object({}), description: 'Wraps children into as many equal columns as fit. Use for Metrics.' },
    Card: { props: z.object({ title: dynamic.optional(), subtitle: dynamic.optional() }), description: 'Groups children in a titled box' },
    Heading: { props: z.object({ text: dynamic }), description: 'Section title' },
    Text: { props: z.object({ text: dynamic, tone: z.enum(['default', 'secondary', 'positive', 'negative', 'warning']).optional() }), description: 'Paragraph' },
    Badge: { props: z.object({ text: dynamic, tone: z.enum(['default', 'positive', 'negative', 'warning']).optional() }), description: 'Short status label' },
    Divider: { props: z.object({}), description: 'Separator line' },
    Metric: { props: z.object({ label: dynamic, value: dynamic, format, currency: dynamic.optional(), detail: dynamic.optional() }), description: 'One large number. currency is an ISO code such as USD; percent values are 0-100.' },
    KeyValue: { props: z.object({ items: dynamic }), description: 'Label and value rows. items is [{ label, value }].' },
    Table: { props: z.object({ columns: z.array(z.object({ key: z.string(), label: z.string(), format, currency: z.string().optional() })), rows: dynamic }), description: 'rows is an array of objects keyed by column key.' },
    BarChart: { props: z.object({ title: dynamic.optional(), data: dynamic, xKey: z.string(), yKey: z.string() }), description: 'Compares categories. data is an array of objects. Keep it under 30 rows.' },
    LineChart: { props: z.object({ title: dynamic.optional(), data: dynamic, xKey: z.string(), yKey: z.string() }), description: 'Shows a value over time, oldest row first.' },
    PieChart: { props: z.object({ title: dynamic.optional(), data: dynamic, xKey: z.string(), yKey: z.string() }), description: 'Shares of a whole. Use at most 6 rows.' },
    TextInput: { props: z.object({ label: dynamic, value: dynamic, placeholder: dynamic.optional() }), description: 'Text field. Bind value with $bindState.' },
    NumberInput: { props: z.object({ label: dynamic, value: dynamic }), description: 'Number field. Bind value with $bindState.' },
    DateInput: { props: z.object({ label: dynamic, value: dynamic }), description: 'Optional date stored as YYYY-MM-DD. Bind value with $bindState.' },
    Select: { props: z.object({ label: dynamic, value: dynamic, options: dynamic }), description: 'Single choice. options is [{ label, value }] or strings, and may read query results. Bind value with $bindState.' },
    Toggle: { props: z.object({ label: dynamic, value: dynamic }), description: 'On or off. Bind value with $bindState.' },
} });
export const uiSpec = z.object({ root: z.string(), elements: z.record(z.string(), z.unknown()), state: z.record(z.string(), z.unknown()).optional() });
export type UISpec = z.infer<typeof uiSpec>;
const unsupported = ['$bindItem', '$cond', '$computed'];
export function validateUISpec(spec: unknown): UISpec {
    const fail = (message: string): never => { throw new ApiError(422, `Invalid UI spec: ${message}`); };
    if (JSON.stringify(spec ?? null).length > 200000)
        fail('it is too large');
    const parsed = uiSpec.safeParse(spec);
    if (!parsed.success)
        return fail('expected root, elements, and an optional state object');
    const checked = uiCatalog.validate(parsed.data);
    if (!checked.success)
        fail(checked.error?.message ?? 'it does not match the catalog');
    const structure = validateSpec(parsed.data as unknown as Spec);
    if (!structure.valid)
        fail(structure.issues.map(i => i.message).join(' '));
    const elements = parsed.data.elements as Record<string, { children: string[]; props: unknown; on?: unknown; watch?: unknown; slots?: unknown }>;
    if (Object.keys(elements).length > 300)
        fail('it has more than 300 elements');
    function scan(value: unknown) {
        if (Array.isArray(value))
            value.forEach(scan);
        else if (value && typeof value === 'object')
            for (const [key, inner] of Object.entries(value)) {
                if (unsupported.includes(key))
                    fail(`${key} is not supported`);
                scan(inner);
            }
    }
    function walk(key: string, path: string[]) {
        if (path.includes(key) || path.length > 20)
            fail('elements must form a tree at most 20 levels deep');
        for (const child of elements[key]?.children ?? [])
            walk(child, [...path, key]);
    }
    for (const [key, element] of Object.entries(elements)) {
        if (element.on || element.watch || element.slots)
            fail(`${key} uses on, watch, or slots, which are not supported`);
        scan(element.props);
    }
    walk(parsed.data.root, []);
    return parsed.data;
}
export function uiPrompt(...customRules: string[]) { return uiCatalog.prompt({ customRules }); }
