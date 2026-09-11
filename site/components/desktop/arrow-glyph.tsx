import { useId } from "react";

/// The app's arrow.up.circle symbol, drawn to the SF Symbols proportions. `filled` is the solid disc
/// with the arrow cut out; otherwise a circle outline with the arrow inside. Colour comes from the text colour.
export function ArrowGlyph({ size = 20, filled = false, className = "" }: { size?: number; filled?: boolean; className?: string }) {
  const id = useId();
  const arrow = "M12 17.2V7 M8.1 10.9 12 7l3.9 3.9";
  const shrink = "translate(12 12.1) scale(0.88) translate(-12 -12.1)";
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden className={className}>
      {filled ? (
        <>
          <defs>
            <mask id={id}>
              <rect width="24" height="24" fill="white" />
              <path d={arrow} fill="none" stroke="black" strokeWidth="2.15" strokeLinecap="round" strokeLinejoin="round" transform={shrink} />
            </mask>
          </defs>
          <circle cx="12" cy="12" r="10" fill="currentColor" mask={`url(#${id})`} />
        </>
      ) : (
        <>
          <circle cx="12" cy="12" r="9.25" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d={arrow} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" transform={shrink} />
        </>
      )}
    </svg>
  );
}
