import { BatteryCharging, Bell, Bluetooth, Circle, CloudUpload, Search, SlidersHorizontal, Wifi } from "lucide-react";
import { ModeToggle } from "@/components/mode-toggle";

const bar = "flex h-7 items-center text-[14px] leading-7 text-white antialiased drop-shadow-[0_1px_1px_rgba(0,0,0,0.35)]";
const icon = { size: 19, strokeWidth: 1.9 };

/// Left part of the macOS menu bar: Apple menu, bold app name, app menus.
export function MenuBarLeft() {
  return (
    <div className={`${bar} gap-[22px]`}>
      <svg viewBox="0 0 17 20" width="15" height="18" fill="currentColor" aria-label="Apple menu" className="-mt-px">
        <path d="M14.1 10.6c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.9-3.6.9-.7 0-1.9-.8-3.1-.8C3.7 5.4 1.1 7.5 1.1 11.5c0 1.2.2 2.5.7 3.8.6 1.7 2.6 5.5 4.7 5.5 1.1 0 1.9-.8 3.3-.8s2.1.8 3.4.8c2.1 0 3.9-3.5 4.5-5.2-2.9-1.4-3.6-3.9-3.6-5zM11.6 3.9c.7-.8 1.1-1.9 1-3-1 0-2.2.7-2.9 1.5-.6.7-1.2 1.9-1 2.9 1.1.1 2.2-.6 2.9-1.4z" />
      </svg>
      <span className="font-bold">MacUp</span>
      <span className="hidden gap-[22px] sm:flex" aria-hidden>
        <span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span>
      </span>
    </div>
  );
}

/// Right part: status items at even spacing. MacUp's is first and highlighted because its dropdown is
/// open; the dropdown below shares this column, so it starts exactly under the item.
export function StatusCluster({ count }: { count: number }) {
  return (
    <div className={`${bar} justify-end gap-[16px]`}>
      <span className="flex h-[24px] items-center gap-1.5 rounded-[6px] bg-white/25 px-1.5" aria-label={`MacUp: ${count} updates ready`}>
        {/* Filled when updates are waiting, like the app's arrow.up.circle.fill: a solid disc with the arrow cut out. */}
        <svg width="20" height="20" viewBox="0 0 24 24" aria-hidden>
          <defs>
            {/* The arrow is a hole in the disc, so whatever is behind the pill shows through. */}
            <mask id="macup-arrow-cutout">
              <rect width="24" height="24" fill="white" />
              {/* Proportions of SF's arrow.up.circle.fill: shorter, thicker shaft and a wider 90° head. */}
              <path d="M12 16.7V7.7 M7.3 12.4l4.7-4.7 4.7 4.7" fill="none" stroke="black" strokeWidth="2.7" strokeLinecap="round" strokeLinejoin="round" />
            </mask>
          </defs>
          <circle cx="12" cy="12" r="10" fill="white" mask="url(#macup-arrow-cutout)" />
        </svg>
        <span className="text-[13px] font-semibold tabular-nums">{count}</span>
      </span>
      <span className="hidden items-center gap-[16px] lg:flex" aria-hidden>
        <Circle {...icon} />
        <Bell {...icon} />
        <CloudUpload {...icon} />
        <Bluetooth {...icon} />
      </span>
      <ModeToggle />
      <Wifi {...icon} aria-hidden className="hidden sm:block" />
      <BatteryCharging size={21} strokeWidth={1.9} aria-hidden className="hidden sm:block" />
      <Search {...icon} aria-hidden className="hidden sm:block" />
      <SlidersHorizontal {...icon} aria-hidden className="hidden sm:block" />
      <span className="tabular-nums">10 Sep&nbsp;&nbsp;15:39</span>
    </div>
  );
}
