import { ApiError, type Placement } from './contracts';

/** Subtract printed text from the AI's proposed cell, never moving into another cell. */
export function avoidPrintedText(box: Placement, regions: Placement[]): Placement {
    let candidates = [box];
    for (const region of regions) {
        if (region.page !== box.page) continue;
        const left = region.x - 0.002, top = region.y - 0.002;
        const right = region.x + region.w + 0.002, bottom = region.y + region.h + 0.002;
        candidates = candidates.flatMap(p => {
            const x2 = p.x + p.w, y2 = p.y + p.h;
            if (left >= x2 || right <= p.x || top >= y2 || bottom <= p.y) return [p];
            return [
                { ...p, w: left - p.x },
                { ...p, x: right, w: x2 - right },
                { ...p, h: top - p.y },
                { ...p, y: bottom, h: y2 - bottom },
            ].filter(r => r.w >= 0.025 && r.h >= 0.01);
        }).sort((a, b) => b.w * b.h - a.w * a.h).slice(0, 64);
    }
    const best = candidates.sort((a, b) => b.w * b.h - a.w * a.h)[0];
    if (!best) throw new ApiError(422, 'Could not locate a clear writing area for every field. Please regenerate the form or use a PDF with embedded fields.');
    return best;
}
