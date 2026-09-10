import type { Metadata } from "next";
import "./globals.css";
import { site } from "@/lib/site";
import { ThemeProvider } from "@/components/theme-provider";

export const metadata: Metadata = {
  title: `${site.name} – ${site.tagline}`,
  description:
    "MacUp is a free, open source macOS menu bar app that finds the package managers on your Mac, shows what is outdated, and updates it in one click.",
  openGraph: { title: site.name, description: site.tagline, type: "website" },
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
