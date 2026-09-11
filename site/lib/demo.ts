import { Beer, Box, ShieldAlert, Wrench, type LucideIcon } from "lucide-react";

/// Sample data shown in the open dropdown on the landing page (the same fixture the app renders).
export type DemoRow = {
  name: string;
  from: string;
  to: string;
  age: string;
  updated: string;
  security?: boolean;
};
export type DemoSection = { manager: string; icon: LucideIcon; updateAll?: boolean; rows: DemoRow[] };

export const demo: { count: number; checked: string; waiting: number; sections: DemoSection[] } = {
  count: 5,
  checked: "Checked 2 minutes ago",
  waiting: 3,
  sections: [
    {
      manager: "Homebrew",
      icon: Beer,
      updateAll: true,
      rows: [
        { name: "ghostty", from: "1.2.3", to: "1.3.1", age: "6d ago", updated: "5w" },
        { name: "jq", from: "1.7.1", to: "1.8.2", age: "12d ago", updated: "4mo" },
      ],
    },
    {
      manager: "npm",
      icon: Box,
      rows: [{ name: "npm", from: "10.9.7", to: "12.0.2", age: "4w ago", updated: "6mo" }],
    },
    {
      manager: "Cargo",
      icon: ShieldAlert,
      rows: [
        {
          name: "cargo-nextest",
          from: "0.9.67",
          to: "0.9.143",
          age: "5w ago",
          updated: "1y",
          security: true,
        },
      ],
    },
    {
      manager: "Self-installed tools",
      icon: Wrench,
      rows: [{ name: "uv", from: "0.7.8", to: "0.12.10", age: "4d ago", updated: "1y" }],
    },
  ],
};
