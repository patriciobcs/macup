"use client";

import { useEffect, useState } from "react";
import { site } from "@/lib/site";

/// Shows the newest release tag when GitHub's API is reachable (public repo); renders nothing otherwise.
export function LatestVersion() {
  const [tag, setTag] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    fetch(`https://api.github.com/repos/${site.repo}/releases/latest`, {
      signal: controller.signal,
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((json) => {
        if (json && typeof json.tag_name === "string") setTag(json.tag_name);
      })
      .catch(() => {});
    return () => controller.abort();
  }, []);

  if (!tag) return null;
  return (
    <a href={site.releases} className="underline-offset-4 hover:text-foreground hover:underline">
      Latest {tag}
    </a>
  );
}
