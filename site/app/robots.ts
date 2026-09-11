import type { MetadataRoute } from "next";
import { site } from "@/lib/site";

/// Written once at build time: the site is a static export, so there is no request to vary on.
export const dynamic = "force-static";

/// Emitted as /robots.txt at build time. There is nothing to hide on a one-page site, so the only
/// job here is pointing crawlers at the sitemap.
export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: "*", allow: "/" }],
    sitemap: `${site.url}/sitemap.xml`,
    host: site.url,
  };
}
