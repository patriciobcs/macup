import { Box } from "lucide-react";

/// The same package outline the app shows in the menu bar, in the current text color.
export function Logo({ size = 24, className = "" }: { size?: number; className?: string }) {
  return <Box size={size} strokeWidth={1.75} aria-hidden className={className} />;
}
