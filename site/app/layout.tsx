import type { Metadata } from "next";
import "./globals.css";
import { site } from "@/lib/site";
import { ThemeProvider } from "@/components/theme-provider";

const base = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

export const metadata: Metadata = {
  // metadataBase turns every relative URL below into an absolute one, which Open Graph and the
  // canonical link both require.
  metadataBase: new URL(site.url),
  title: `${site.name} — ${site.headline}`,
  description: site.description,
  applicationName: site.name,
  authors: [{ name: "Patricio Calderon", url: "https://github.com/patriciobcs" }],
  creator: "Patricio Calderon",
  alternates: { canonical: "/" },
  // max-image-preview lets Google show the screenshot full width in a result instead of a thumbnail.
  robots: {
    index: true,
    follow: true,
    googleBot: { index: true, follow: true, "max-image-preview": "large", "max-snippet": -1 },
  },
  openGraph: {
    title: `${site.name} — ${site.headline}`,
    description: site.tagline,
    type: "website",
    url: "/",
    siteName: site.name,
    locale: "en_US",
    images: [{ url: site.ogImage, width: 1492, height: 844, alt: `${site.name} listing outdated packages` }],
  },
  twitter: {
    card: "summary_large_image",
    title: `${site.name} — ${site.headline}`,
    description: site.tagline,
    images: [site.ogImage],
  },
  icons: {
    // The app's dark rendition, exported from MacUp.icon: a dark square with a light glyph reads on a
    // light tab strip and a dark one alike, so it needs no per-theme pair.
    icon: [{ url: `${base}/icon-dark.png` }],
    apple: `${base}/apple-icon.png`,
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
          {children}
        </ThemeProvider>
      </body>
    </html>
  );
}
