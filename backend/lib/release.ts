export type AppRelease = { version: string | null; download: string | null; notes: string };
const releases = 'https://github.com/rxtech-lab/lumik/releases';

export async function getAppRelease(): Promise<AppRelease> {
    const fallback = { version: null, download: null, notes: releases };
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
        const installer = typeof download === 'string' && download.startsWith(`${releases}/download/${encodeURIComponent(tag)}/`) ? download : null;
        return { version: tag.replace(/^v/, ''), download: installer, notes: `${releases}/tag/${encodeURIComponent(tag)}` };
    } catch {
        return fallback;
    }
}
