import { version } from '../package.json';

export type AppRelease = { version: string; download: string | null; notes: string };
const releases = 'https://github.com/rxtech-lab/lumik/releases';

export async function getAppRelease(): Promise<AppRelease> {
    const fallback = { version, download: null, notes: releases };
    try {
        const response = await fetch('https://api.github.com/repos/rxtech-lab/lumik/releases/latest', {
            headers: { Accept: 'application/vnd.github+json' },
            next: { revalidate: 300 },
            signal: AbortSignal.timeout(4000),
        });
        if (!response.ok) return fallback;
        const release = await response.json();
        const asset = release.assets?.find((item: { name: string }) => item.name === 'Lumik.dmg');
        const tag = release.tag_name;
        if (release.draft || release.prerelease || typeof tag !== 'string' || !/^v?\d+\.\d+\.\d+$/.test(tag)) return fallback;
        const download = asset?.browser_download_url;
        if (typeof download !== 'string' || !download.startsWith(`${releases}/download/`)) return fallback;
        return { version: tag.replace(/^v/, ''), download, notes: `${releases}/tag/${encodeURIComponent(tag)}` };
    } catch {
        return fallback;
    }
}
