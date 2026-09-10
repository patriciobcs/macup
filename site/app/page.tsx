import { CalendarClock, Download, Hourglass, Radar, Terminal } from "lucide-react";
import { Button } from "@/components/ui/button";
import { LatestVersion } from "@/components/latest-version";
import { Logo } from "@/components/logo";
import { MenuBarLeft, StatusCluster } from "@/components/desktop/menu-bar";
import { Panel } from "@/components/desktop/panel";
import { Window } from "@/components/desktop/window";
import { demo } from "@/lib/demo";
import { site } from "@/lib/site";

const points = [
  { icon: Radar, title: "Finds every manager", body: "Homebrew, npm, pip, Cargo and 15 more. No setup." },
  { icon: Hourglass, title: "Waits for releases to settle", body: "A day for updates, four hours for security fixes." },
  { icon: CalendarClock, title: "Shows dates and advisories", body: "Release date, install date, known vulnerabilities." },
  { icon: Terminal, title: "Runs the real commands", body: "Each manager's own tools, output on screen." },
];

const links = [
  { label: "Source", href: site.github },
  { label: "Releases", href: site.releases },
  { label: "License", href: site.license },
];

export default function Home() {
  return (
    // One grid for menu bar and desktop: the second column is as wide as the status cluster, so the
    // open dropdown sits exactly under the MacUp item and the window keeps the rest of the width.
    <div className="wallpaper grid min-h-screen grid-cols-[minmax(0,1fr)_auto] grid-rows-[1.5rem_1fr] gap-x-4 px-4 text-foreground lg:gap-x-6 lg:px-6">
      <MenuBarLeft />
      <StatusCluster count={demo.count} />

      {/* On desktop the window floats centered in its area at a typical app size instead of filling it. */}
      <main className="col-span-2 flex min-w-0 flex-col gap-4 pt-2 pb-8 lg:col-span-1 lg:items-center lg:justify-center lg:pb-16">
        {/* Phone: the dropdown is the hero, hanging under the menu bar in a compact form. */}
        <div className="flex justify-end lg:hidden"><Panel compact className="w-full sm:w-[320px]" /></div>

        <Window title="MacUp" mobileCard className="w-full lg:w-[1440px] lg:max-w-full">
          <div className="grid gap-7 p-1 lg:min-h-[520px] lg:grid-cols-[minmax(0,5fr)_minmax(0,4fr)] lg:gap-16 lg:px-10 lg:py-12">
            <div className="flex flex-col lg:justify-center">
              <div className="flex items-center gap-3">
                <Logo size={52} className="lg:size-14" />
                <span className="text-2xl font-semibold tracking-tight lg:text-3xl">{site.name}</span>
              </div>
              <h1 className="mt-5 text-[26px] leading-tight font-semibold tracking-tight text-balance lg:text-4xl">{site.tagline}</h1>
              <p className="mt-3 text-muted-foreground lg:text-lg">
                Every package manager on your Mac, in one place. See what is outdated and update it in one click.
              </p>
              <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-center sm:gap-4">
                <Button variant="secondary" size="lg" className="h-11 w-full px-4 text-[15px] sm:w-auto sm:h-10" nativeButton={false} render={<a href={site.download} />}>
                  <Download data-icon="inline-start" aria-hidden />
                  Download for Mac
                </Button>
                <span className="text-center text-sm text-muted-foreground sm:text-left">Free, open source, MIT · macOS 14+</span>
              </div>
              <nav className="mt-auto hidden gap-4 pt-8 text-sm text-muted-foreground lg:flex" aria-label="Links">
                {links.map((l) => (
                  <a key={l.label} href={l.href} className="underline-offset-4 hover:text-foreground hover:underline">{l.label}</a>
                ))}
                <LatestVersion />
              </nav>
            </div>
            <dl className="grid content-center gap-4 border-t border-foreground/10 pt-6 sm:grid-cols-2 lg:gap-8 lg:border-0 lg:pt-0">
              {points.map((p) => (
                <div key={p.title} className="flex gap-3 lg:flex-col lg:gap-3">
                  <span className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg bg-muted text-foreground/80 lg:size-10 lg:rounded-xl">
                    <p.icon size={16} aria-hidden className="lg:size-5" />
                  </span>
                  <div>
                    <dt className="text-sm font-medium lg:text-base">{p.title}</dt>
                    <dd className="mt-0.5 text-sm text-muted-foreground lg:text-[15px]">{p.body}</dd>
                  </div>
                </div>
              ))}
            </dl>
          </div>
        </Window>

        {/* Phone footer links (on desktop they live inside the window). */}
        <nav className="flex justify-center gap-5 pt-2 text-sm text-white/85 drop-shadow lg:hidden" aria-label="Links">
          {links.map((l) => (
            <a key={l.label} href={l.href} className="underline-offset-4 hover:underline">{l.label}</a>
          ))}
        </nav>
      </main>

      {/* The open dropdown, left-aligned with its status item directly above. */}
      <aside className="hidden pt-2 lg:block">
        <Panel />
      </aside>
    </div>
  );
}
