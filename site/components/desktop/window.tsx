/// A macOS window: 12 px traffic lights with 8 px gaps, centered title, rounded corners, deep shadow.
export function Window({
  title,
  children,
  className = "",
  padded = true,
  mobileCard = false,
}: {
  title: string;
  children: React.ReactNode;
  className?: string;
  padded?: boolean;
  /// Below the large breakpoint, drop the title bar and read as a plain card.
  mobileCard?: boolean;
}) {
  return (
    <section
      className={`bg-background text-foreground overflow-hidden rounded-[14px] shadow-[0_22px_70px_4px_rgba(0,0,0,0.35)] ring-1 ring-black/10 dark:ring-white/15 ${className}`}
      aria-label={title}
    >
      <div
        className={`border-foreground/10 bg-muted/80 relative h-[30px] items-center border-b px-3 ${mobileCard ? "hidden lg:flex" : "flex"}`}
      >
        <div className="flex gap-2" aria-hidden>
          <span className="size-3 rounded-full bg-[#ff5f57] ring-1 ring-black/15 ring-inset" />
          <span className="size-3 rounded-full bg-[#febc2e] ring-1 ring-black/15 ring-inset" />
          <span className="size-3 rounded-full bg-[#28c840] ring-1 ring-black/15 ring-inset" />
        </div>
        <div className="text-foreground/70 pointer-events-none absolute inset-x-0 text-center text-[13px] font-semibold">
          {title}
        </div>
      </div>
      <div className={padded ? "p-4" : ""}>{children}</div>
    </section>
  );
}
