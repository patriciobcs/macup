"use client";

import { Check, Copy } from "lucide-react";
import { useState } from "react";
import { site } from "@/lib/site";

/// The Homebrew one-liner, as a button: clicking anywhere on it copies the command.
export function InstallCommand() {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(site.install);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // A denied clipboard leaves the command on screen to select by hand.
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={copied ? "Command copied" : `Copy: ${site.install}`}
      className="border-foreground/10 bg-muted/60 text-foreground/80 hover:bg-muted group flex w-full items-center gap-2 rounded-lg border px-3 py-2 text-left font-mono text-[12.5px] transition-colors lg:text-[13px]"
    >
      <span className="min-w-0 flex-1 truncate">{site.install}</span>
      {copied ? (
        <Check size={14} className="shrink-0 text-emerald-600 dark:text-emerald-400" aria-hidden />
      ) : (
        <Copy size={14} className="text-muted-foreground group-hover:text-foreground shrink-0" aria-hidden />
      )}
    </button>
  );
}
