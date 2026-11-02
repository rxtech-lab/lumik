import { getQuickJS, shouldInterruptAfterDeadline } from 'quickjs-emscripten';
import { ApiError } from './contracts';
/** Runs agent-written JavaScript in QuickJS (WASM). It has no I/O and sees only `globals`. */
export async function runJS(code: string, globals: Record<string, unknown>, timeoutMs = 3000) {
    const QuickJS = await getQuickJS();
    const runtime = QuickJS.newRuntime();
    runtime.setMemoryLimit(64 * 1024 * 1024);
    runtime.setMaxStackSize(1024 * 1024);
    runtime.setInterruptHandler(shouldInterruptAfterDeadline(Date.now() + timeoutMs));
    const vm = runtime.newContext();
    const logs: string[] = [];
    try {
        const log = vm.newFunction('log', (...args) => { if (logs.length < 100) logs.push(args.map(vm.dump).map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ')); });
        const consoleHandle = vm.newObject();
        vm.setProp(consoleHandle, 'log', log);
        vm.setProp(vm.global, 'console', consoleHandle);
        log.dispose();
        consoleHandle.dispose();
        // The double stringify makes the data a string literal that code cannot escape from.
        const setup = Object.entries(globals).map(([name, value]) => `globalThis[${JSON.stringify(name)}]=JSON.parse(${JSON.stringify(JSON.stringify(value))});`).join('');
        const result = vm.evalCode(`${setup}JSON.stringify((function(){"use strict";\n${code}\n})())`);
        if (result.error) {
            const error = vm.dump(result.error);
            result.error.dispose();
            throw new ApiError(422, `JavaScript error: ${typeof error === 'object' ? error?.message ?? 'failed' : error}`);
        }
        const text: unknown = vm.dump(result.value);
        result.value.dispose();
        return { result: typeof text === 'string' ? JSON.parse(text) as unknown : null, logs };
    }
    finally {
        vm.dispose();
        runtime.dispose();
    }
}
