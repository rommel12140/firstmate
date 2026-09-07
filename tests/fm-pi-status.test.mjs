import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createJiti } from 'jiti';
import { InMemoryCredentialStore } from '@earendil-works/pi-ai';
import {
  createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager,
  SettingsManager, FooterComponent, initTheme,
} from '@earendil-works/pi-coding-agent';
import { TuiMainScreen, Text, visibleWidth } from '@earendil-works/pi-tui';
const jiti = createJiti(import.meta.url);
const root = dirname(fileURLToPath(import.meta.url));
const { QuotaCache, parseQuota, quotaSegments, readQuota, quotaProviderFor, resetCountdown } =
  await jiti.import('./.pi/extensions/lib/fm-quota-status.ts');
const { installStatus, statusLines, STATUS_WIDGET } = await jiti.import('./.pi/extensions/fm-primary-status.ts');
const calm = (await jiti.import('./.pi/extensions/fm-calm.ts')).default;
const epoch = Date.parse('2026-09-07T12:00:00Z');
let now = epoch;
const iso = ms => new Date(ms).toISOString();
const payload = (provider = 'codex', windows = [
  { id: 'short', label: '5h', kind: 'session', percentRemaining: 0, resetsAt: iso(epoch + 75 * 60000), windowSeconds: 18000 },
  { id: 'weekly', label: 'week', kind: 'weekly', percentRemaining: 63, resetsAt: iso(epoch + 3 * 86400000), windowSeconds: 604800 },
  { id: 'spark-short', label: 'GPT-5.3-Codex-Spark session', kind: 'model', percentRemaining: 100, resetsAt: iso(epoch + 18000000) },
  { id: 'spark-week', label: 'GPT-5.3-Codex-Spark week', kind: 'model', percentRemaining: 100, resetsAt: iso(epoch + 604800000) },
]) => ({ schemaVersion: 5, generatedAt: iso(now), providers: [{ provider, state: { status: 'fresh', stale: false }, windows }] });
const snapshot = () => parseQuota(payload(), 'codex');
const output = result => quotaSegments(result, now).join('\n');
assert.equal(output(snapshot()), 'Codex account week: 63% left | reset 3d 0h');
assert.doesNotMatch(output(snapshot()), /Spark|session|short window|Pi link|USED/);
assert.equal(snapshot().windows.length, 4, 'compact rendering does not discard parsed windows');
assert.match(output(parseQuota(payload('claude'), 'claude')), /Claude account week: 63% left/);
const noWeek = payload('codex', payload().providers[0].windows.filter(w => w.kind !== 'weekly'));
assert.equal(output(parseQuota(noWeek, 'codex')), 'Codex account week: unavailable');
const duplicateWeek = payload();
duplicateWeek.providers[0].windows.push({ ...duplicateWeek.providers[0].windows[1], id: 'other-week' });
assert.equal(output(parseQuota(duplicateWeek, 'codex')), 'Codex account week: unavailable');
assert.equal(resetCountdown(epoch + 1, epoch), '1m');
assert.equal(resetCountdown(epoch, epoch), 'passed');
let bad = payload();
bad.providers[0].windows[1].percentRemaining = 0;
assert.match(output(parseQuota(bad, 'codex')), /account week: 0% left/);
bad.providers[0].windows[1].percentRemaining = -1;
assert.match(output(parseQuota(bad, 'codex')), /remaining unknown/);
bad.providers[0].windows[1].percentRemaining = null;
assert.match(output(parseQuota(bad, 'codex')), /remaining unknown/);
bad.providers[0].windows[1].percentRemaining = 40;
bad.providers[0].windows[1].percentUsed = 20;
assert.match(output(parseQuota(bad, 'codex')), /remaining unknown/);
bad = payload(); bad.providers[0].state.untrustedWindowIds = ['weekly'];
assert.match(output(parseQuota(bad, 'codex')), /remaining unknown/);
bad = payload(); bad.providers[0].windows[1].resetsAt = 'invalid';
assert.match(output(parseQuota(bad, 'codex')), /reset unknown/);
bad = payload(); bad.providers[0].state.stale = true;
assert.match(output(parseQuota(bad, 'codex')), /STALE last/);
bad = payload(); bad.providers[0].state.status = 'error';
assert.match(output(parseQuota(bad, 'codex')), /ERROR/);
assert.equal(parseQuota(payload('claude'), 'codex').state, 'unknown');
bad = payload();
bad.providers[0].account = { email: 'PRIVATE-FIXTURE', accountId: 'PRIVATE-FIXTURE' };
bad.providers[0].state.error = 'PRIVATE-FIXTURE';
assert.ok(!JSON.stringify(parseQuota(bad, 'codex')).includes('PRIVATE-FIXTURE'));

bad = payload(); bad.schemaVersion = 900;
assert.equal(parseQuota(bad, 'codex').state, 'unknown');
const saved = snapshot();
now += 121000;
assert.match(output(saved), /STALE/);
now = epoch + 3 * 86400000;
assert.match(output(saved), /remaining unknown \| reset passed/);
now = epoch - 1;
assert.match(output(saved), /STALE/);
now = epoch;
const catalog = await ModelRuntime.create({ credentials: new InMemoryCredentialStore(), modelsPath: null, modelsStorePath: join(root, 'catalog.json'), refreshOnCreate: false, allowModelNetwork: false });
const model = catalog.getModel('openai-codex', 'gpt-6-astra');
assert.ok(model, 'installed Pi must supply the model fixture');
assert.equal(quotaProviderFor(model), 'codex');
assert.equal(quotaProviderFor({ ...model, provider: 'openai' }), undefined);
assert.equal(quotaProviderFor({ ...model, baseUrl: undefined }), undefined);
assert.equal(quotaProviderFor({ ...model, baseUrl: 'https://proxy.invalid' }), undefined);
assert.equal(quotaProviderFor({ ...model, api: 'openai-responses' }), undefined);
console.log('ok - account weekly summary, hidden model windows, exhaustion, unknowns, stale clock and rollover');

let reads = 0;
let release;
const cache = new QuotaCache(async () => { reads++; await new Promise(resolve => { release = resolve; }); return snapshot(); }, () => now);
const a = cache.refresh('codex');
const b = cache.refresh('codex');
assert.equal(a, b);
await new Promise(resolve => setImmediate(resolve));
assert.equal(reads, 1);
release(); await a;
await cache.refresh('codex'); assert.equal(reads, 1);
let context = { model, thinkingLevel: 'high', getContextUsage: () => ({ percent: 42, tokens: 114240, contextWindow: 272000 }) };
for (const width of [1, 8, 20, 40, 80, 120, 208]) {
  const lines = statusLines(context, cache, width, now);
  for (const line of lines) assert.ok(visibleWidth(line) <= width, `overflow ${width}: ${line}`);
  assert.deepEqual(lines, statusLines(context, cache, width, now));
  if (width >= 40) {
    assert.match(lines.join('\n'), /63% left/);
    assert.doesNotMatch(lines.join('\n'), /Spark|short window|Pi link/);
  }
}
context = { ...context, model: { ...model, id: '\x1b[31m模型-é\x1b[0m' } };
for (const line of statusLines(context, cache, 40, now)) assert.ok(visibleWidth(line) <= 40);
assert.match(statusLines({ ...context, getContextUsage: () => undefined }, cache, 208, now).join('\n'), /Context unknown/);
assert.match(statusLines({ ...context, getContextUsage: () => ({ percent: null }) }, cache, 208, now).join('\n'), /Context unknown/);
assert.doesNotMatch(statusLines({ ...context, model: { ...model, provider: 'unsupported' } }, cache, 208, now).join('\n'), /63% left/);
assert.equal(statusLines({ ...context, model }, cache, 208, now).length, 1, 'wide footer is one compact row');
await cache.dispose();

let aborted = false;
const cancellation = new QuotaCache((_provider, signal) => new Promise(resolve => {
  signal.addEventListener('abort', () => { aborted = true; resolve(snapshot()); }, { once: true });
}), () => now);
const pending = cancellation.refresh('codex');
await new Promise(resolve => setImmediate(resolve));
await cancellation.dispose(); await pending;
assert.ok(aborted);
assert.equal(cancellation.get('codex').state, 'unknown');
let result = snapshot();
const errors = new QuotaCache(async () => result, () => now);
await errors.refresh('codex'); now += 60000;
result = { provider: 'codex', state: 'timeout', windows: [] };
await errors.refresh('codex');
assert.match(output(errors.get('codex')), /TIMEOUT/);
assert.match(output(errors.get('codex')), /TIMEOUT last/);
now += 60000; result = parseQuota(payload('codex', []), 'codex');
await errors.refresh('codex'); assert.equal(errors.get('codex').windows.length, 0);
await errors.dispose();
// A rapid switch can cancel a flight, but must never start an obsolete provider.
let releaseSwitch, starts = [];
const switching = new QuotaCache((provider) => new Promise(resolve => {
  starts.push(provider);
  releaseSwitch = () => resolve({ ...snapshot(), provider });
}), () => now);
const initial = switching.refresh('codex');
await new Promise(resolve => setImmediate(resolve));
const switched = switching.refresh('claude');
const unsupported = switching.refresh(undefined);
releaseSwitch(); await Promise.all([initial, switched, unsupported]);
assert.deepEqual(starts, ['codex']);
assert.equal(switching.get('codex').state, 'unknown');
await switching.dispose();
console.log('ok - width, Unicode, stable frames, refresh coalescing, caching, failure and disposal');

// Exercise the real process boundary against an isolated executable, never auth.
writeFileSync(join(root, 'bin/quota-axi'), '#!/usr/bin/env node\n' + `
import fs from 'node:fs';
import { spawn } from 'node:child_process';
if (process.env.QUOTA_TEST_MODE === 'timeout') {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {stdio:'ignore'});
  fs.writeFileSync(process.env.QUOTA_TEST_PID, String(child.pid));
  setInterval(() => {}, 1000);
} else if (process.env.QUOTA_TEST_MODE === 'invalid') {
  process.stdout.write('invalid');
} else { process.stdout.write(${JSON.stringify(JSON.stringify(payload()))}); }
`, { mode: 0o755 });
process.env.PATH = join(root, 'bin') + ':' + process.env.PATH;
let real = await readQuota('codex', new AbortController().signal);
assert.equal(real.state, 'fresh');
process.env.QUOTA_TEST_MODE = 'invalid';
assert.equal((await readQuota('codex', new AbortController().signal)).state, 'error');
process.env.QUOTA_TEST_MODE = 'timeout';
process.env.QUOTA_TEST_PID = join(root, 'child.pid');
let responsiveTicks = 0;
const responsive = setInterval(() => { responsiveTicks++; }, 20);
assert.equal((await readQuota('codex', new AbortController().signal, 1500)).state, 'timeout');
clearInterval(responsive);
assert.ok(responsiveTicks > 5, 'quota child must not block the event loop');
const childPid = Number(readFileSync(process.env.QUOTA_TEST_PID, 'utf8'));
let dead = false;
for (let i = 0; i < 100; i++) {
  try { process.kill(childPid, 0); } catch { dead = true; break; }
  await new Promise(resolve => setTimeout(resolve, 20));
}
assert.ok(dead, 'timeout must retire quota fallback descendants');
delete process.env.QUOTA_TEST_MODE;
console.log('ok - real child output, malformed response, timeout and descendant cleanup');

// Actual Pi SDK, isolated credentials/resources. No real model request is allowed.
now = epoch;
let modelCalls = 0, sdkReads = 0;
const credentials = new InMemoryCredentialStore();
await credentials.modify('openai-codex', async () => ({ type: 'oauth', access: 'fixture-only', refresh: 'fixture-only', expires: Date.now() + 3600000 }));
const runtime = await ModelRuntime.create({ credentials, modelsPath: null,
  modelsStorePath: join(root, 'models-store.json'), refreshOnCreate: false, allowModelNetwork: false });

const settings = SettingsManager.inMemory({ theme: 'dark' });
const loader = new DefaultResourceLoader({ cwd: root, agentDir: join(root, 'agent'), settingsManager: settings,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
  agentsFilesOverride: () => ({ agentsFiles: [] }),
  extensionFactories: [
    pi => installStatus(pi, () => new QuotaCache(async () => { sdkReads++; return snapshot(); }, () => now), () => now),
    calm,
  ],
});
await loader.reload();
const sm = SessionManager.inMemory(root);
const { session } = await createAgentSession({ cwd: root, agentDir: join(root, 'agent'), modelRuntime: runtime,
  model, thinkingLevel: 'high', sessionManager: sm, settingsManager: settings, resourceLoader: loader, tools: [] });
session.agent.streamFn = () => { modelCalls++; throw new Error('footer caused a model request'); };
runtime.streamSimple = () => { modelCalls++; throw new Error('footer invoked provider runtime'); };
const widgets = new Map();
const statuses = new Map([['other-extension', 'watch ready']]);
const terminal = { columns: 120, rows: 40, start() {}, stop() {}, write() {}, hideCursor() {}, showCursor() {},
  setProgress() {}, drainInput: async () => {}, moveBy() {}, clearLine() {}, clearFromCursor() {}, clearScreen() {}, setTitle() {} };
initTheme('dark', false);
const theme = { fg: (_color, text) => `\x1b[36m${text}\x1b[0m` };
let repaints = 0, footerOverrides = 0, expanded = false;
const ui = {
  setWidget(key, factory) {
    widgets.get(key)?.dispose?.();
    if (factory) widgets.set(key, typeof factory === 'function' ? factory({ terminal, requestRender() { repaints++; } }, theme) : new Text(factory.join('\n'), 0, 0));
    else widgets.delete(key);
  },
  setFooter() { footerOverrides++; },
  setStatus(key, text) { if (text === undefined) statuses.delete(key); else statuses.set(key, text); },
  setWorkingVisible() {}, setHiddenThinkingLabel() {}, onTerminalInput() { return () => {}; },
  getEditorText() { return ''; }, getToolsExpanded() { return expanded; }, setToolsExpanded(value) { expanded = value; },
  notify() {}, theme,
};
await session.bindExtensions({ mode: 'tui', uiContext: ui, onError(error) { throw error; } });
await new Promise(resolve => setImmediate(resolve));
let component = widgets.get(STATUS_WIDGET);
assert.ok(component);
assert.match(component.render(120).join('\n'), /Model gpt-6-astra \| Effort high/);
session.setThinkingLevel('xhigh');
assert.match(component.render(120).join('\n'), /Effort xhigh/);
const nextModel = catalog.getModel('openai-codex', 'gpt-5.6-sol');
await session.setModel(nextModel);
assert.match(component.render(120).join('\n'), /Model gpt-5.6-sol/);
assert.equal(sdkReads, 1, 'model/effort switch must reuse the account cache');
for (let i = 0; i < 500; i++) component.render(120);
assert.equal(sdkReads, 1, 'streaming renders never fetch quota');
const before = sm.getEntries().length;
now += 60000;
await new Promise(resolve => setTimeout(resolve, 1100));
assert.equal(sdkReads, 2);
assert.equal(sm.getEntries().length, before, 'display refresh must not append session events');
assert.equal(modelCalls, 0);
await session.prompt('/calm');
assert.ok(widgets.has(STATUS_WIDGET), 'Calm on preserves quota component');
await session.prompt('/calm');
assert.ok(widgets.has(STATUS_WIDGET), 'Calm off preserves quota component');
assert.equal(footerOverrides, 0);
assert.equal(statuses.get('other-extension'), 'watch ready');
assert.equal(modelCalls, 0);

// Use stored fixture usage through Pi's public session APIs, then compact without a model.
const assistant = input => ({ role: 'assistant', content: [{ type: 'text', text: 'fixture response' }],
  provider: 'openai-codex', model: model.id, api: model.api, stopReason: 'stop', timestamp: now,
  usage: { input, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: input,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
const entry = sm.appendMessage(assistant(114240));
session.agent.state.messages = sm.buildSessionContext().messages;
assert.match(component.render(120).join('\n'), /Context 42% USED/);
sm.appendCompaction('fixture summary', entry, 114240);
session.agent.state.messages = sm.buildSessionContext().messages;
assert.match(component.render(120).join('\n'), /Context unknown/);
sm.appendMessage(assistant(27200));
session.agent.state.messages = sm.buildSessionContext().messages;
assert.match(component.render(120).join('\n'), /Context 10% USED/);
assert.equal(modelCalls, 0);

// Actual stock FooterComponent with the SDK session, not a drawn approximation.
const footer = new FooterComponent(session, { getGitBranch: () => 'fixture-branch',
  getExtensionStatuses: () => statuses, getAvailableProviderCount: () => 1 });
const captures = [];
for (const width of [40, 80, 120, 208]) {
  const render = component.render(width);
  const stock = footer.render(width);
  assert.ok(stock.join('\n').includes('watch ready'));
  const rows = ['FIXTURE VALUES ONLY', ...render, ...stock];
  captures.push(`TERMINAL WIDTH ${width}\n${rows.join('\n')}`);
  for (const line of rows) assert.ok(visibleWidth(line) <= width);
}
if (process.env.FM_PI_STATUS_CAPTURE) writeFileSync(process.env.FM_PI_STATUS_CAPTURE, captures.join('\n\n') + '\n');

// TUI's real diff renderer writes nothing for an unchanged footer frame.
let written = '';
const tui = new TuiMainScreen({ ...terminal, write(text) { written += text; } });
tui.addChild(new Text('FIXTURE VALUES ONLY', 0, 0));
tui.addChild(new Text('> ', 0, 0));
tui.addChild(component);
tui.addChild(footer);
tui.start(); await new Promise(resolve => setTimeout(resolve, 40));
if (process.env.FM_PI_STATUS_CAPTURE) writeFileSync(process.env.FM_PI_STATUS_CAPTURE + '.terminal', written);
written = '';
tui.requestRender(); await new Promise(resolve => setTimeout(resolve, 40));
assert.equal(written, '');
tui.stop();
// Real SDK reload invalidates old contexts and installs exactly one new widget.
const oldComponent = component;
await session.reload();
await new Promise(resolve => setImmediate(resolve));
component = widgets.get(STATUS_WIDGET);
assert.ok(component && component !== oldComponent);
const readsAfterReload = sdkReads;
oldComponent.dispose(); // A delayed old disposal cannot kill the replacement.
now += 60000;
await new Promise(resolve => setTimeout(resolve, 1100));
assert.equal(sdkReads, readsAfterReload + 1);
assert.equal(modelCalls, 0);
// Explicit lifecycle shutdown through the SDK runner, then prove timer silence.
await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'reload' });
const readsAtStop = sdkReads;
const rendersAtStop = repaints;
now += 60000;
await new Promise(resolve => setTimeout(resolve, 1100));
assert.equal(sdkReads, readsAtStop);
assert.equal(repaints, rendersAtStop);
assert.ok(!widgets.has(STATUS_WIDGET));
session.dispose();
console.log('ok - Pi SDK live model/effort, Calm coexistence, stock footer, unchanged TUI frames and shutdown; model calls=0');
