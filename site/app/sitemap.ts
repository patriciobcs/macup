import type { MetadataRoute } from "next";
import { site } from "@/lib/site";

/// Written once at build time: the site is a static export, so there is no request to vary on.
export const dynamic = "force-static";

/// Emitted as /sitemap.xml at build time. One page, so one entry; lastModified is the build date,
/// which is the only honest answer for a statically exported site.
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: `${site.url}/`,
      lastModified: new Date(),
      changeFrequency: "monthly",
      priority: 1,
    },
  ];
}
