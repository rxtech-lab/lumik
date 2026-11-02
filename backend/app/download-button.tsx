'use client';

import { useId, useRef } from 'react';
import type { AppRelease } from '../lib/release';

export function DownloadButton({ release, compact = false }: { release: AppRelease; compact?: boolean }) {
    const titleId = useId();
    const dialog = useRef<HTMLDialogElement>(null);
    return <>
        <button className={`button ${compact ? 'button-small' : ''}`} onClick={() => dialog.current?.showModal()}>
            {compact ? 'Get Lumik' : 'Download Lumik'} <span aria-hidden="true">↗</span>
        </button>
        <dialog ref={dialog} aria-labelledby={titleId} onClick={event => { if (event.target === event.currentTarget) dialog.current?.close(); }}>
            <div className="dialog-content">
                <button className="close-button" aria-label="Close download dialog" onClick={() => dialog.current?.close()}>×</button>
                <span className="eyebrow">YOUR NEXT CLEAR STEP</span>
                <h2 id={titleId}>Make room for clarity.</h2>
                <p>Lumik for Mac {release.version && <span className="version">v{release.version}</span>}</p>
                <p className="muted">Requires macOS 26 or later. For Apple silicon and Intel Macs.</p>
                {release.download ? <a className="button" href={release.download}>Download for Mac <span aria-hidden="true">↓</span></a> : <div className="release-notice"><strong>Release in preparation</strong><p>The Mac installer isn’t available here yet. Visit releases to check availability.</p></div>}
                <a className="text-link" href={release.notes}>View releases <span aria-hidden="true">↗</span></a>
                <div className="mobile-note">iPhone & iPad <span>Download details coming soon</span></div>
            </div>
        </dialog>
    </>;
}
