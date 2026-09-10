"use client";

import { MacOSDock, type DockApp } from "@/components/ui/mac-os-dock";
import { asset, site } from "@/lib/site";

const links: Record<string, string> = {
  download: site.download,
  source: site.github,
  releases: site.releases,
  issues: site.issues,
  license: site.license,
};

const apps: DockApp[] = [
  { id: "macup", name: "MacUp", icon: asset("/dock/macup.png") },
  { id: "download", name: "Download MacUp", icon: asset("/dock/download.svg") },
  { id: "source", name: "Source on GitHub", icon: asset("/dock/source.svg") },
  { id: "releases", name: "Releases", icon: asset("/dock/releases.svg") },
  { id: "issues", name: "Report an issue", icon: asset("/dock/issues.svg") },
  { id: "license", name: "MIT License", icon: asset("/dock/license.svg") },
];

/// The Dock: MacUp shown as the running app (indicator dot), the other tiles are the page's links.
export function Dock() {
  function open(id: string) {
    const href = links[id];
    if (href) window.location.assign(href);
  }
  return <MacOSDock apps={apps} openApps={["macup"]} onAppClick={open} />;
}
