import { ArrowDownCircle, ChevronRight, CircleArrowDown, RotateCw } from "lucide-react";
import { demo } from "@/lib/demo";


/// The MacUp dropdown, open, as live HTML with the sample data the app also renders in its screenshots.
/// Sizes and spacing follow the app: 15 pt title, 13 pt rows, 11 pt captions, 30 pt icons, 14 pt margins.
/// `compact` shows the first manager only plus a "more" row, for small screens.
export function Panel({ compact = false, className = "" }: { compact?: boolean; className?: string }) {
  const sections = compact ? demo.sections.slice(0, 1) : demo.sections;
  const more = demo.sections.slice(1).reduce((n, s) => n + s.rows.length, 0);
  return (
    <div className={`w-[320px] max-w-full rounded-[14px] bg-background/85 py-1.5 text-[13px] leading-[1.25] tracking-normal antialiased shadow-2xl ring-1 ring-foreground/10 backdrop-blur-xl ${className}`}>
      <div className="flex items-center justify-between px-[14px] pt-2 pb-2.5">
        <div>
          <div className="text-[15px] font-semibold">{demo.count} updates ready</div>
          <div className="mt-px text-[12px] text-muted-foreground">{demo.checked}</div>
        </div>
        <div className="mr-0.5 flex items-center gap-2.5 text-foreground/70">
          <CircleArrowDown size={20} strokeWidth={1.75} className="fill-foreground/70 text-background" aria-label={`Update all ${demo.count}`} />
          <RotateCw size={16} strokeWidth={1.75} aria-hidden />
        </div>
      </div>
      {sections.map((s) => (
        <div key={s.manager}>
          <Divider />
          <div className="flex items-center justify-between px-[14px] pt-2 pb-1 text-[12px] font-semibold text-muted-foreground">
            <span>{s.manager}</span>
            {s.updateAll && <span className="font-normal">Update All</span>}
          </div>
          {s.rows.map((r) => (
            <div key={r.name} className="flex items-center gap-[10px] px-[14px] py-[5px]">
              <span className={`flex size-[30px] shrink-0 items-center justify-center rounded-full text-white ${r.security ? "bg-[#ff453a]" : "bg-[#0a84ff]"}`}>
                <s.icon size={14} strokeWidth={2} aria-hidden />
              </span>
              <div className="min-w-0 flex-1">
                <div className="truncate">{r.name}</div>
                <div className="truncate text-[11px] text-muted-foreground tabular-nums">
                  {r.from} → {r.to} · {r.age} · updated {r.updated}
                </div>
              </div>
              <ArrowDownCircle size={20} strokeWidth={1.5} className="shrink-0 text-foreground/70" aria-hidden />
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
  return <div className="mx-[10px] my-[5px] h-px bg-foreground/10" />;
}

function Row({ children, muted = false }: { children: React.ReactNode; muted?: boolean }) {
  return (
    <div className={`mx-[5px] flex items-center justify-between rounded-[6px] px-[9px] py-[6px] hover:bg-foreground/10 ${muted ? "text-muted-foreground" : ""}`}>
      {children}
    </div>
  );
}
