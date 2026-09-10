import { CircleArrowUp } from "lucide-react";

/// The same symbol the app shows in the menu bar (an up arrow in a circle), in the current text color.
export function Logo({ size = 24, className = "" }: { size?: number; className?: string }) {
  return <CircleArrowUp size={size} strokeWidth={1.75} aria-hidden className={className} />;
}
