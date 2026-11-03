import { ImageResponse } from 'next/og';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export const alt = 'Lumik — A little clarity. A lot less clutter. Document scanning and organization for Mac, iPhone, and iPad.';
export const size = { width: 1200, height: 630 };
export const contentType = 'image/png';
export const dynamic = 'force-static';

export default async function OpenGraphImage() {
    const artwork = await readFile(join(process.cwd(), 'public/images/lumik-paperwork.png'));
    return new ImageResponse(
        <div style={{ width: '100%', height: '100%', display: 'flex', background: '#fffaf4', color: '#302a25', padding: 64, alignItems: 'center' }}>
            <div style={{ display: 'flex', flexDirection: 'column', width: 650 }}>
                <div style={{ display: 'flex', fontSize: 42, fontWeight: 700, marginBottom: 38 }}>lumik<span style={{ color: '#984321' }}>.</span></div>
                <div style={{ display: 'flex', flexDirection: 'column', fontSize: 64, fontWeight: 700, letterSpacing: -3, lineHeight: 1.08 }}>
                    <span>A little clarity.</span>
                    <span style={{ color: '#984321' }}>A lot less clutter.</span>
                </div>
                <div style={{ fontSize: 25, lineHeight: 1.4, marginTop: 24, color: '#71675e' }}>Scan, organize, and understand your documents.</div>
                <div style={{ display: 'flex', fontSize: 20, marginTop: 38, color: '#984321' }}>Mac · iPhone · iPad</div>
                <div style={{ fontSize: 18, marginTop: 14, color: '#71675e' }}>lumik.dev</div>
            </div>
            <img src={`data:image/png;base64,${artwork.toString('base64')}`} width={450} height={450} style={{ objectFit: 'contain' }} />
        </div>,
        size,
    );
}
