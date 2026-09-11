import type { Metadata } from "next";
import "./globals.css";
import { site } from "@/lib/site";
import { ThemeProvider } from "@/components/theme-provider";

const base = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

export const metadata: Metadata = {
  title: `${site.name} – ${site.tagline}`,
  description:
    "MacUp is a free, open source macOS menu bar app that finds the package managers on your Mac, shows what is outdated, and updates it in one click.",
  openGraph: { title: site.name, description: site.tagline, type: "website" },
  icons: {
    // Theme-specific icons first for browsers that honour `media`; the plain one last for those that
    // take the final <link>, and a touch icon for iOS bookmarks.
    icon: [
      { url: `${base}/icon-light.png`, media: "(prefers-color-scheme: light)" },
      { url: `${base}/icon-dark.png`, media: "(prefers-color-scheme: dark)" },
      { url: `${base}/icon-light.png` },
    ],
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
