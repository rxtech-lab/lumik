import { afterEach, describe, expect, it, vi } from 'vitest';
import { getAppRelease } from '../lib/release';

afterEach(() => vi.unstubAllGlobals());

describe('landing page release availability', () => {
    it('uses the version and installer from the same published release', async () => {
        const download = 'https://github.com/rxtech-lab/lumik/releases/download/v1.2.3/Lumik.dmg';
        vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({
            tag_name: 'v1.2.3', assets: [{ name: 'Lumik.dmg', browser_download_url: download }],
        })));
        expect(await getAppRelease()).toEqual({ version: '1.2.3', download, notes: 'https://github.com/rxtech-lab/lumik/releases/tag/v1.2.3' });
    });
    it('does not invent an installer when there are no releases', async () => {
        vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status: 404 })));
        expect((await getAppRelease()).download).toBeNull();
    });
    it('keeps the page available during a network outage', async () => {
        vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')));
        expect((await getAppRelease()).download).toBeNull();
    });
    it('does not offer untrusted asset URLs', async () => {
        vi.stubGlobal('fetch', vi.fn().mockResolvedValue(Response.json({
            tag_name: 'v1.2.3', assets: [{ name: 'Lumik.dmg', browser_download_url: 'https://example.com/app.dmg' }],
        })));
        expect((await getAppRelease()).download).toBeNull();
    });
});
