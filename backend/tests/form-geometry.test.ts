import { expect, test } from 'vitest';
import { avoidPrintedText } from '../lib/form-geometry';
const cell = { page: 0, x: 0.1, y: 0.1, w: 0.4, h: 0.06 };
test('uses space beside a bilingual heading filling the cell height', () => {
    const result = avoidPrintedText(cell, [{ ...cell, w: 0.12 }]);
    expect(result.x).toBeGreaterThan(0.22);
    expect(result.x + result.w).toBeCloseTo(0.5);
});
test('preserves clear boxes and ignores other pages', () => {
    expect(avoidPrintedText(cell, [{ ...cell, page: 1 }])).toEqual(cell);
});
test('rejects a fully printed cell instead of saving overlapping ink', () => {
    expect(() => avoidPrintedText(cell, [cell])).toThrow('clear writing area');
});
