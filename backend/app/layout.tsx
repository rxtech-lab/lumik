import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
    metadataBase: new URL('https://lumik.dev'),
    title: 'Lumik — A little clarity for your paperwork',
    description: 'Scan, organize, and understand your documents with Lumik. A native document workspace for Mac, iPhone, and iPad.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return <html lang="en"><body>{children}</body></html>;
}
