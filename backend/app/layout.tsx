import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
    metadataBase: new URL('https://lumik.dev'),
    title: 'Lumik — A little clarity for your paperwork',
    description: 'Scan, organize, and understand your documents with Lumik. A native document workspace for Mac, iPhone, and iPad.',
    applicationName: 'Lumik',
    alternates: { canonical: '/' },
    openGraph: {
        type: 'website',
        url: '/',
        siteName: 'Lumik',
        locale: 'en_US',
        title: 'Lumik — A little clarity for your paperwork',
        description: 'Scan, organize, and understand your documents. A brighter home for your paperwork on Mac, iPhone, and iPad.',
    },
    twitter: {
        card: 'summary_large_image',
        title: 'Lumik — A little clarity for your paperwork',
        description: 'Scan, organize, and understand your documents. A brighter home for your paperwork on Mac, iPhone, and iPad.',
        images: [{ url: '/opengraph-image', alt: 'Lumik — A little clarity. A lot less clutter. Document scanning and organization for Mac, iPhone, and iPad.' }],
    },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return <html lang="en"><body>{children}</body></html>;
}
