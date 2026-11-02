import { DownloadButton } from './download-button';
import { getAppRelease } from '../lib/release';

export default async function Home() {
    const release = await getAppRelease();
    return <>
        <a className="skip-link" href="#main">Skip to content</a>
        <header className="site-header wrap">
            <a className="brand" href="#" aria-label="Lumik home"><img className="brand-icon" src="/icon.png" width="40" height="40" alt="" /> lumik<span className="brand-dot">.</span></a>
            <nav aria-label="Main navigation"><a href="#features">Why Lumik</a><a href="#how-it-works">How it works</a></nav>
            <DownloadButton release={release} compact />
        </header>
        <main id="main">
            <section className="hero wrap" aria-labelledby="hero-title">
                <div className="hero-copy">
                    <span className="eyebrow"><span className="little-star" aria-hidden="true">✳</span> LESS PAPERWORK. MORE POSSIBILITY.</span>
                    <h1 id="hero-title">A little clarity.<br />A lot less <span>clutter.</span></h1>
                    <p className="hero-description">Meet a brighter home for your documents. Scan the paper, find the details, and let Lumik put everything in its place.</p>
                    <div className="hero-actions"><DownloadButton release={release} /><a className="text-link" href="#how-it-works">Take a look <span aria-hidden="true">↓</span></a></div>
                    <p className="release-caption"><span className="status-dot" />v{release.version} <span>·</span> {release.download ? 'Available for Mac' : 'Mac release in preparation'}</p>
                </div>
                <div className="hero-art">
                    <div className="art-orbit" aria-hidden="true" />
                    <span className="art-label">A SPACE FOR EVERYTHING</span>
                    <img src="/images/lumik-paperwork.png" width="1024" height="1024" alt="A soft orange folder holding neatly arranged papers and a receipt, with a floating yellow sparkle" fetchPriority="high" />
                    <div className="floating-tag tag-top"><span aria-hidden="true">✦</span> A little help from AI</div>
                    <div className="floating-tag tag-bottom"><span className="check" aria-hidden="true">✓</span><div>Nicely filed.<small>One less thing on your mind.</small></div></div>
                    <span className="art-caption">FROM PAPER PILES TO PEACE OF MIND</span>
                </div>
            </section>
            <div className="platforms wrap"><span>Feels at home on your devices.</span><div>Mac <span aria-hidden="true">/</span> iPhone <span aria-hidden="true">/</span> iPad</div><span className="platform-note">Thoughtfully native. Naturally simple.</span></div>
            <section className="features wrap" id="features" aria-labelledby="features-title">
                <div className="section-heading"><div><span className="eyebrow">SMALL EFFORT. BIG EXHALE.</span><h2 id="features-title">Life has enough admin.</h2></div><p>Your receipts, records, and everyday paperwork.<br />A little more organized. A lot more useful.</p></div>
                <div className="feature-grid">
                    <article className="feature-card peach"><span className="feature-icon" aria-hidden="true">⌑</span><h3>Paper, meet pixels.</h3><p>Scan with your iPhone or iPad, import a PDF, or connect a compatible scanner on Mac.</p><div className="scan-visual" aria-hidden="true"><div className="mini-paper"><span /><span /><span /><span /></div><div className="scan-line" /></div><span className="card-footnote">CAPTURE THE EVERYDAY</span></article>
                    <article className="feature-card yellow"><span className="feature-icon" aria-hidden="true">✧</span><h3>The details, handled.</h3><p>Lumik extracts the information you need and names new documents to match the way you already file.</p><div className="data-visual" aria-hidden="true"><div><span>Merchant</span><strong>Sunday Coffee</strong></div><div><span>Total</span><strong>$12.50</strong></div><div><span>Status</span><strong className="ready">✓ Extracted</strong></div></div><span className="card-footnote">LESS TYPING, MORE LIVING</span></article>
                    <article className="feature-card sage"><span className="feature-icon" aria-hidden="true">↗</span><h3>Find a little insight.</h3><p>Ask Buddy about your documents. Review suggested changes in a dedicated view before applying them.</p><div className="chat-visual" aria-hidden="true"><div>What’s the total on this receipt?</div><div><span>✳</span> Sunday Coffee · $12.50</div></div><span className="card-footnote">A BUDDY FOR YOUR PAPERWORK</span></article>
                </div>
            </section>
            <section className="workflow wrap" id="how-it-works" aria-labelledby="workflow-title"><div><span className="eyebrow">A SIMPLE LITTLE ROUTINE</span><h2 id="workflow-title">In with the paper.<br />Out with the busywork.</h2><p>Give your documents a place to belong.<br />Lumik takes it from there.</p></div><ol><li><span>01</span><div><h3>Make a space.</h3><p>Create a group for receipts, invoices, or anything you keep. Choose the details that matter.</p></div></li><li><span>02</span><div><h3>Drop it in.</h3><p>Scan or upload a PDF. Extraction and naming start automatically.</p></div></li><li><span>03</span><div><h3>Carry on.</h3><p>Review the details, ask Buddy a question, or export your group when you need it.</p></div></li></ol></section>
            <section className="closing wrap"><span className="closing-star" aria-hidden="true">✳</span><span className="eyebrow">A LIGHTER WAY TO KEEP THINGS</span><h2>A fresh start for<br />your paper trail.</h2><DownloadButton release={release} /><p>Built for Mac, iPhone, and iPad.</p></section>
        </main>
        <footer className="wrap"><a className="brand" href="#"><img className="brand-icon" src="/icon.png" width="40" height="40" alt="" />lumik<span className="brand-dot">.</span></a><p>A little order. A little light.</p><a href={release.notes}>Releases <span aria-hidden="true">↗</span></a><span>Made by RxLab</span></footer>
    </>;
}
