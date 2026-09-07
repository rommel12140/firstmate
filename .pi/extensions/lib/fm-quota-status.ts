// Read-only quota-axi display boundary. Never retain account/auth/error payloads.
import { spawn } from "node:child_process";

export const QUOTA_REFRESH_MS = 60_000;
export const QUOTA_FRESH_MS = 120_000;
export const QUOTA_TIMEOUT_MS = 15_000;
export type QuotaProvider = "codex" | "claude";
export type QuotaWindow = {
  label: string;
  kind: string;
  used?: number;
  left?: number;
  reset?: number;
  seconds?: number;
};
export type QuotaSnapshot = {
  provider: QuotaProvider;
  at?: number;
  state: "fresh" | "stale" | "unknown" | "error" | "timeout";
  windows: QuotaWindow[];
};
type RecordValue = Record<string, unknown>;
const record = (value: unknown): RecordValue =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : {};
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
const percent = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
const timestamp = (value: unknown): number | undefined => {
  // No timezone-less timestamps, numeric coercion, or date-only guesses.
  if (typeof value !== "string" || !/T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return undefined;
  const result = Date.parse(value);
  return Number.isFinite(result) ? result : undefined;
};
export const cleanStatusText = (text: string): string => text
  .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
  .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
  .replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, " ")
  .replace(/\s+/g, " ").trim().slice(0, 160);

// Pi's built-in provider metadata owns this relationship, never the model name.
// Matching an endpoint establishes a provider surface, not an account binding.
export function quotaProviderFor(model?: { provider: string; api: string; baseUrl: string }): QuotaProvider | undefined {
  if (typeof model?.baseUrl !== "string") return undefined;
  if (model?.provider === "openai-codex" && model.api === "openai-codex-responses" &&
      model.baseUrl.replace(/\/$/, "") === "https://chatgpt.com/backend-api") return "codex";
  if (model?.provider === "anthropic" && model.api === "anthropic-messages" &&
      model.baseUrl.replace(/\/$/, "") === "https://api.anthropic.com") return "claude";
  return undefined;
}

export function parseQuota(value: unknown, provider: QuotaProvider): QuotaSnapshot {
  const root = record(value);
  const unknown: QuotaSnapshot = { provider, state: "unknown", windows: [] };
  if (root.schemaVersion !== 5) return unknown;
  const matches = array(root.providers).map(record).filter(p => p.provider === provider);
  if (matches.length !== 1) return unknown;
  const report = matches[0];
  const state = record(report.state);
  const at = timestamp(state.refreshedAt ?? root.generatedAt);
  if (!['fresh', 'stale'].includes(String(state.status))) return { ...unknown, state: "error" };
  const untrusted = array(state.untrustedWindowIds);
  if (!Array.isArray(report.windows) || report.windows.length > 16) return unknown;
  const windows = report.windows.map(value => {
    const window = record(value);
    const kind = typeof window.kind === "string" ? window.kind : "unknown";
    const label = typeof window.label === "string" ? cleanStatusText(window.label) : "window unknown";
    let used: number | undefined;
    let left: number | undefined;
    // Percent fields are normalized comparable percentages in schema 5. Do not
    // derive from money, credits, pace, context tokens, or unknown/untrusted kinds.
    if (["session", "weekly", "monthly", "model"].includes(kind) && !untrusted.includes(window.id)) {
      const validLeft = percent(window.percentRemaining);
      const validUsed = percent(window.percentUsed);
      const invalidSupplied = (window.percentRemaining !== undefined && !validLeft) ||
        (window.percentUsed !== undefined && !validUsed);
      if (!invalidSupplied && (validLeft || validUsed) &&
          !(validLeft && validUsed && Math.abs(Number(window.percentRemaining) + Number(window.percentUsed) - 100) > 0.1)) {
        left = validLeft ? window.percentRemaining as number : 100 - (window.percentUsed as number);
        used = validUsed ? window.percentUsed as number : 100 - left;
      }
    }
    return {
      label: label || "window unknown", kind, used, left,
      reset: timestamp(window.resetsAt),
      seconds: typeof window.windowSeconds === "number" && Number.isFinite(window.windowSeconds) && window.windowSeconds > 0
        ? window.windowSeconds : undefined,
    };
  });
  return { provider, at, state: state.status === "fresh" && state.stale === false ? "fresh" : "stale", windows };
}

// Subprocess isolation here is only for bounded process-tree cleanup. This child
// stays attached through pipes and an awaited promise; it is never a daemon.
export function readQuota(provider: QuotaProvider, signal: AbortSignal, timeoutMs = QUOTA_TIMEOUT_MS): Promise<QuotaSnapshot> {
  return new Promise(resolve => {
    if (signal.aborted) return resolve({ provider, state: "error", windows: [] });
    let stdout = "";
    let bytes = 0;
    let failure: "error" | "timeout" | undefined;
    const grouped = process.platform !== "win32";
    const child = spawn("quota-axi", ["--provider", provider, "--json"], {
      detached: grouped, stdio: ["ignore", "pipe", "ignore"],
    });
    const kill = () => {
      try {
        if (grouped && child.pid) process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch { /* Already exited. */ }
    };
    const cancel = () => { failure = "error"; kill(); };
    const timeout = setTimeout(() => { failure = "timeout"; kill(); }, timeoutMs);
    signal.addEventListener("abort", cancel, { once: true });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 512 * 1024) { failure = "error"; kill(); return; }
      stdout += chunk;
    });
    let finished = false;
    const finish = (code: number | null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      signal.removeEventListener("abort", cancel);
      kill(); // Also retire a fallback app-server descendant after parent exit.
      child.stdout.destroy();
      let result: QuotaSnapshot = { provider, state: failure ?? "error", windows: [] };
      if (!failure && code === 0) {
        try { result = parseQuota(JSON.parse(stdout), provider); } catch { /* Unknown output stays an error. */ }
      }
      stdout = "";
      resolve(result);
    };
    child.once("error", () => finish(null));
    // Kill descendants on parent exit, then drain all stdout before parsing.
    // Their inherited pipe handles cannot hold the close event open.
    child.once("exit", kill);
    child.once("close", finish);
  });
}

export type QuotaReader = typeof readQuota;
export class QuotaCache {
  private cache = new Map<QuotaProvider, QuotaSnapshot>();
  private attempted = new Map<QuotaProvider, number>();
  private flight?: { provider: QuotaProvider; abort: AbortController; promise: Promise<void> };
  private stopped = false;
  private desired?: QuotaProvider;
  constructor(private reader: QuotaReader = readQuota, private now = Date.now) {}
  get(provider: QuotaProvider): QuotaSnapshot {
    return this.cache.get(provider) ?? { provider, state: "unknown", windows: [] };
  }
  refresh(provider: QuotaProvider | undefined): Promise<void> {
    if (this.stopped) return Promise.resolve();
    this.desired = provider;
    if (this.flight) {
      if (this.flight.provider === provider) return this.flight.promise;
      this.flight.abort.abort();
      return this.flight.promise.then(() => {
        if (this.desired === provider) return this.refresh(provider);
      });
    }
    if (!provider) return Promise.resolve();
    const now = this.now();
    const last = this.attempted.get(provider);
    if (last !== undefined && now >= last && now - last < QUOTA_REFRESH_MS) return Promise.resolve();
    this.attempted.set(provider, now);
    const abort = new AbortController();
    const flight = { provider, abort, promise: Promise.resolve() };
    this.flight = flight;
    flight.promise = Promise.resolve().then(() => this.reader(provider, abort.signal)).then(result => {
      if (this.stopped || abort.signal.aborted) return;
      // An unsuccessful read cannot make an old reading look fresh. A valid
      // empty response clears old limits, including account/plan changes.
      const old = this.cache.get(provider);
      this.cache.set(provider, result.state === "error" || result.state === "timeout"
        ? { ...result, at: old?.at, windows: old?.windows ?? [] } : result);
    }).catch(() => {
      if (!this.stopped && !abort.signal.aborted) {
        const old = this.cache.get(provider);
        this.cache.set(provider, { provider, state: "error", at: old?.at, windows: old?.windows ?? [] });
      }
    }).finally(() => { if (this.flight === flight) this.flight = undefined; });
    return flight.promise;
  }
  async dispose(): Promise<void> {
    this.stopped = true;
    this.flight?.abort.abort();
    await this.flight?.promise;
    this.cache.clear();
    this.attempted.clear();
  }
}

export function resetCountdown(reset: number, now: number): string {
  const minutes = Math.ceil((reset - now) / 60_000);
  if (minutes <= 0) return "passed";
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`;
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  return `${minutes}m`;
}
const pct = (value: number) => Number(value.toFixed(1)).toString();
export function quotaSegments(snapshot: QuotaSnapshot, now: number): string[] {
  // Account-level data, not an assertion that Pi uses the same credentials.
  // Model-specific and short windows belong in the full quota report, not here.
  const prefix = `${snapshot.provider === "codex" ? "Codex" : "Claude"} account week`;
  const current = snapshot.state === "fresh" && snapshot.at !== undefined && now >= snapshot.at && now - snapshot.at < QUOTA_FRESH_MS;
  const state = current ? "" : snapshot.state === "fresh" || snapshot.state === "stale" ? "STALE" : snapshot.state.toUpperCase();
  const weekly = snapshot.windows.filter(w => w.kind === "weekly");
  // Never substitute a model's week or guess between multiple account windows.
  if (weekly.length !== 1) return [`${prefix}: ${state || "unavailable"}`];
  const w = weekly[0];
  if (w.reset !== undefined && now >= w.reset) return [`${prefix}: remaining unknown | reset passed`];
  const value = w.left !== undefined ? `${pct(w.left)}% left` : "remaining unknown";
  const reset = w.reset === undefined ? "reset unknown" : `reset ${resetCountdown(w.reset, now)}`;
  return [`${prefix}: ${current ? "" : `${state} last `}${value} | ${reset}`];
}
