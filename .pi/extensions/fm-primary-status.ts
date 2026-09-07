// Add session and account-quota rows beside Pi's stock footer. No footer override,
// Calm handler, persisted setting, conversation event, or supervision integration.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { cleanStatusText, QuotaCache, quotaProviderFor, quotaSegments } from "./lib/fm-quota-status.ts";

export const STATUS_WIDGET = "firstmate-session-quota";

export function statusLines(ctx: Pick<ExtensionContext, "model" | "thinkingLevel" | "getContextUsage">, cache: QuotaCache, width: number, now: number): string[] {
  if (width < 1) return [];
  const usage = ctx.getContextUsage();
  const percent = usage?.percent;
  const context = typeof percent === "number" && Number.isFinite(percent) && percent >= 0
    ? `${Number(percent.toFixed(1))}% USED` : "unknown";
  const model = cleanStatusText(ctx.model?.id ?? "unknown");
  const effort = cleanStatusText(ctx.thinkingLevel ?? "unknown");
  const provider = quotaProviderFor(ctx.model);
  const segments = [
    `Model ${model} | Effort ${effort} | Context ${context}`,
    ...(provider ? quotaSegments(cache.get(provider), now) : ["Account quota unavailable (unsupported provider/endpoint)"]),
  ];
  // Keep complete windows visible: wrapping must never hide a short-window
  // exhaustion behind a later weekly reading or truncate a safety qualifier.
  const rows: string[] = [];
  let line = "";
  for (const segment of segments) {
    const joined = line ? `${line} | ${segment}` : segment;
    if (line && visibleWidth(joined) > width) { rows.push(line); line = ""; }
    if (visibleWidth(segment) > width) {
      rows.push(...wrapTextWithAnsi(segment, width).map(row => truncateToWidth(row, width, "")));
    } else line = line ? `${line} | ${segment}` : segment;
  }
  if (line) rows.push(line);
  return rows;
}

export function installStatus(pi: ExtensionAPI, makeCache = () => new QuotaCache(), now = Date.now): void {
  let stop: (() => Promise<void>) | undefined;
  let update = () => {};
  pi.on("session_start", async (_event, ctx) => {
    await stop?.();
    stop = undefined;
    if (ctx.mode !== "tui") return;
    const cache = makeCache();
    let active = true;
    let timer: ReturnType<typeof setInterval> | undefined;
    let redraw = () => {};
    const refresh = () => {
      if (!active) return;
      void cache.refresh(quotaProviderFor(ctx.model)).then(() => { if (active) redraw(); });
    };
    const dispose = async () => {
      if (!active) return;
      active = false;
      clearInterval(timer);
      await cache.dispose();
    };
    stop = dispose;
    update = () => { redraw(); refresh(); };
    ctx.ui.setWidget(STATUS_WIDGET, (tui, theme) => {
      let last: string[] = [];
      let width = tui.terminal.columns;
      redraw = () => {
        if (!active) return;
        const next = statusLines(ctx, cache, width, now());
        if (next.join("\n") !== last.join("\n")) tui.requestRender();
      };
      return {
        render(columns) {
          width = columns;
          last = statusLines(ctx, cache, columns, now());
          return last.map(line => theme.fg("muted", line));
        },
        invalidate() { last = []; },
        dispose() { void dispose(); },
      };
    }, { placement: "belowEditor" });
    // Countdown ticks are local. QuotaCache gates actual reads to once/minute;
    // render/token events never fetch. The timer belongs to this session only.
    timer = setInterval(() => { redraw(); refresh(); }, 1000);
    timer.unref();
    refresh();
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    await stop?.();
    stop = undefined;
    update = () => {};
    if (ctx.mode === "tui") ctx.ui.setWidget(STATUS_WIDGET, undefined);
  });
  pi.on("model_select", () => { update(); });
  pi.on("thinking_level_select", () => { update(); });
}

export default function (pi: ExtensionAPI): void { installStatus(pi); }
