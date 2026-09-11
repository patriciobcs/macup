import { ChevronRight, RotateCw } from "lucide-react";
import { ArrowGlyph } from "@/components/desktop/arrow-glyph";
import { demo } from "@/lib/demo";

/// The MacUp dropdown, open, as live HTML with the sample data the app also renders in its screenshots.
/// Sizes and spacing follow the app: 15 pt title, 13 pt rows, 11 pt captions, 30 pt icons, 14 pt margins.
/// `compact` shows the first manager only plus a "more" row, for small screens. The caller sets the width.
export function Panel({ compact = false, className = "" }: { compact?: boolean; className?: string }) {
  const sections = compact ? demo.sections.slice(0, 1) : demo.sections;
  const more = demo.sections.slice(1).reduce((n, s) => n + s.rows.length, 0);
  return (
    <div
      className={`bg-background/90 rounded-[12px] py-1.5 text-[13px] leading-[1.25] tracking-normal antialiased shadow-[0_18px_50px_rgba(0,0,0,0.45)] ring-1 ring-white/15 backdrop-blur-2xl ${className}`}
    >
      <div className="flex items-center justify-between px-[14px] pt-2 pb-2.5">
        <div>
          <div className="text-[13px] font-semibold">{demo.count} updates ready</div>
          <div className="text-muted-foreground mt-px text-[11px]">{demo.checked}</div>
        </div>
        <div className="text-foreground/70 mr-0.5 flex items-center gap-2.5">
          <ArrowGlyph size={20} filled className="text-foreground/70" />
          <RotateCw size={16} strokeWidth={1.75} aria-hidden />
        </div>
      </div>
      {sections.map((s) => (
        <div key={s.manager}>
          <Divider />
          <div className="text-muted-foreground flex items-center justify-between px-[14px] pt-2 pb-1 text-[11px] font-semibold">
            <span>{s.manager}</span>
            {s.updateAll && <span className="font-normal">Update All</span>}
          </div>
          {s.rows.map((r) => (
            <div key={r.name} className="flex items-center gap-[10px] px-[14px] py-[5px]">
              <span
                className={`flex size-[28px] shrink-0 items-center justify-center rounded-full text-white ${r.security ? "bg-[#ff453a]" : "bg-[#0a84ff]"}`}
              >
                <s.icon size={13} strokeWidth={2} aria-hidden />
              </span>
              <div className="min-w-0 flex-1">
                <div className="truncate">{r.name}</div>
                <div className="text-muted-foreground truncate text-[11px] tabular-nums">
                  {r.from} → {r.to} · {r.age} · updated {r.updated}
                </div>
              </div>
              <ArrowGlyph size={20} className="text-foreground/70 shrink-0" />
            </div>
          ))}
        </div>
      ))}
      {compact && more > 0 && (
        <>
          <Divider />
          <Row muted>
            <span>{more} more updates</span>
            <ChevronRight size={14} aria-hidden />
          </Row>
        </>
      )}
      <Divider />
      <Row muted>
        <span>{demo.waiting} waiting for minimum age</span>
        <ChevronRight size={14} aria-hidden />
      </Row>
      <Divider />
      <Row>Settings</Row>
      <Row>Open MacUp</Row>
      <Divider />
      <Row>Quit</Row>
    </div>
  );
}

function Divider() {
  return <div className="bg-foreground/15 mx-[14px] my-[6px] h-px" />;
}

function Row({ children, muted = false }: { children: React.ReactNode; muted?: boolean }) {
  return (
    <div
      className={`hover:bg-foreground/10 mx-[6px] flex items-center justify-between rounded-[6px] px-[8px] py-[7px] ${muted ? "text-muted-foreground" : ""}`}
    >
      {children}
    </div>
  );
}
