import { randomUUID } from 'node:crypto';
import { formSectionsInput, type FormField, type FormSection, type PDFWidget, type Placement } from './contracts';

/** A PDF form field: the widgets sharing a name fill together, and radio widgets become its options. */
export type LogicalWidget = { ref: string; name: string; label: string; type: FormField['type']; pageIndex: number; top: number; left: number; field: FormField };

const box = ({ page, x, y, w, h }: Placement): Placement => ({ page, x, y, w, h });
export function humanLabel(name: string) {
    const leaf = name.split('.').pop()!.replace(/\[\d+\]/g, '');
    const words = leaf.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[_-]+/g, ' ').trim();
    return words ? words[0].toUpperCase() + words.slice(1) : 'Field';
}

export function groupWidgets(widgets: PDFWidget[]): LogicalWidget[] {
    const named = new Map<string, PDFWidget[]>();
    widgets.forEach((widget, index) => {
        const key = widget.name || `unnamed-${index}`;
        named.set(key, [...named.get(key) ?? [], widget]);
    });
    return [...named.entries()].map(([name, group], index) => {
        const first = group[0];
        const states = [...new Set(group.filter(w => w.onState).map(w => w.onState!))];
        const isChoiceButtons = (first.kind === 'radio' || first.kind === 'checkbox') && (first.kind === 'radio' || states.length > 1);
        const label = (group.find(w => w.label)?.label ?? humanLabel(name)).slice(0, 200);
        const field: FormField = { id: `f${index + 1}`, label, type: 'text', required: false, placements: [], options: [], widgets: [name], defaultValue: first.value || null };
        if (isChoiceButtons) {
            field.type = 'choice';
            field.options = states.map(state => ({ value: state, label: humanLabel(state), placements: group.filter(w => w.onState === state).map(box) }));
        } else {
            field.type = first.kind === 'radio' ? 'choice' : first.kind;
            field.placements = group.map(box);
            field.options = first.options.map(option => ({ value: option, label: option, placements: [] }));
            if (first.kind === 'checkbox')
                field.defaultValue = !!first.value && first.value === first.onState;
        }
        return { ref: `w${index + 1}`, name, label, type: field.type, pageIndex: first.page, top: first.y, left: first.x, field };
    });
}

/** What the AI returns: labels and sections, pointing at PDF fields by ref or at boxes it found on the page. */
export type FormDraft = {
    title: string;
    sections: {
        title: string;
        footer: string | null;
        fields: {
            label: string;
            type: FormField['type'];
            required: boolean;
            help: string | null;
            ref: string | null;
            placements: Placement[];
            options: { label: string; value: string | null; placement: Placement | null }[];
        }[];
    }[];
};

function clampBox(p: Placement, pageCount: number): Placement | null {
    if (!Number.isInteger(p.page) || p.page < 0 || p.page >= pageCount)
        return null;
    const x = Math.min(Math.max(p.x, 0), 0.995);
    const y = Math.min(Math.max(p.y, 0), 0.995);
    const w = Math.min(Math.max(p.w, 0.005), 1 - x);
    const h = Math.min(Math.max(p.h, 0.005), 1 - y);
    return { page: p.page, x, y, w, h };
}

/** Sections by page in reading order, used when the AI is unavailable: a PDF form never needs it to work. */
export function sectionsFromWidgets(widgets: LogicalWidget[]): FormSection[] {
    const pages = new Map<number, LogicalWidget[]>();
    for (const widget of widgets)
        pages.set(widget.pageIndex, [...pages.get(widget.pageIndex) ?? [], widget]);
    return [...pages.entries()].sort(([a], [b]) => a - b).map(([page, group]) => ({
        id: `s${page + 1}`, title: `Page ${page + 1}`, footer: null,
        fields: group.sort((a, b) => Math.abs(a.top - b.top) < 0.008 ? a.left - b.left : a.top - b.top).map(w => w.field),
    }));
}

/**
 * Trusts the AI for wording and order only. Every PDF field stays mapped, because one it leaves out
 * is added back, and any box is clamped to a page that exists.
 */
export function sectionsFromDraft(draft: FormDraft, widgets: LogicalWidget[], pageCount: number): FormSection[] {
    const byRef = new Map(widgets.map(w => [w.ref, w]));
    const used = new Set<string>();
    let next = 1;
    const sections: FormSection[] = draft.sections.map((section, index) => ({
        id: `s${index + 1}`, title: section.title.trim().slice(0, 120) || `Section ${index + 1}`, footer: section.footer?.slice(0, 500) || null,
        fields: section.fields.flatMap((field): FormField[] => {
            const label = field.label.trim().slice(0, 200) || 'Field';
            const help = field.help?.slice(0, 500) || null;
            const widget = field.ref ? byRef.get(field.ref) : undefined;
            if (widget) {
                if (used.has(widget.ref))
                    return [];
                used.add(widget.ref);
                const options = widget.field.options.map(option => ({ ...option, label: field.options.find(o => o.value === option.value)?.label.slice(0, 200) || option.label }));
                const type = widget.field.type === 'text' && ['multiline', 'date', 'number'].includes(field.type) ? field.type : widget.field.type;
                return [{ ...widget.field, label, help, type, options, required: field.required }];
            }
            if (widgets.length)
                return [];
            const placements = field.placements.map(p => clampBox(p, pageCount)).filter(p => p !== null);
            const options = field.options.map(option => {
                const placement = option.placement && clampBox(option.placement, pageCount);
                return { value: option.value?.slice(0, 300) || option.label.slice(0, 300), label: option.label.slice(0, 200), placements: placement ? [placement] : [] };
            });
            if (!placements.length && !options.some(o => o.placements.length))
                return [];
            return [{ id: `f${next++}`, label, type: field.type, required: field.required, help, placements, options, widgets: [], defaultValue: null }];
        }),
    })).filter(section => section.fields.length);
    const missing = widgets.filter(w => !used.has(w.ref));
    if (missing.length)
        sections.push({ id: 'more', title: 'More fields', footer: null, fields: sectionsFromWidgets(missing).flatMap(s => s.fields) });
    return formSectionsInput.parse(sections);
}

export const newId = () => randomUUID();
