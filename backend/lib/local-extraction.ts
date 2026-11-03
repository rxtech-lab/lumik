import { z } from 'zod';
import { pdfName, validateData, type Group } from './contracts';
import type { Repository } from './repository';

export function validateLocalExtraction(group: Group, input: unknown) {
    const result = z.object({ title: z.string().trim().min(1).max(255), fields: z.record(z.string(), z.unknown()), facts: z.record(z.string(), z.unknown()).optional() }).strict().parse(input);
    validateData(group.schema, result.fields);
    return result;
}
export async function saveLocalExtraction(repo: Repository, group: Group, id: string, input: unknown) {
    const result = validateLocalExtraction(group, input);
    const previous = (await repo.documents(group.id)).some(d => d.id !== id && d.status === 'ready' && d.name !== d.originalName);
    const facts = group.extractAdditional ? result.facts ?? {} : {};
    const additional = group.extractAdditional ? { facts, spec: { root: 'facts', elements: {
        facts: { type: 'Text', props: { text: Object.entries(facts).map(([key, value]) => `${key.replaceAll('_', ' ')}: ${typeof value === 'string' ? value : JSON.stringify(value)}`).join('\n') || 'No additional facts found.' }, children: [] },
    } } } : null;
    return repo.complete(id, pdfName(previous ? '{title}' : group.namingTemplate, result.fields, result.title), result.fields, additional);
}
