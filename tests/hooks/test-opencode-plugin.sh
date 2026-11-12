#!/usr/bin/env bash
# The OpenCode plugin must register skills and inject the bootstrap once per top-level session (V1 and V2 APIs faked).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "  [SKIP] node is not installed"; echo "opencode plugin: SKIPPED"; exit 0; }

PLUGIN_ROOT_UNDER_TEST="$ROOT" node --input-type=module <<'EOF'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.PLUGIN_ROOT_UNDER_TEST;
const modPath = path.join(root, '.opencode/plugins/devops-mutant-powers.js');
const skillsDir = path.join(root, 'skills');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const MARKER = `<EXTREMELY_IMPORTANT>\nYou have devops-mutant-powers v${version}.`;
const logged = [];
console.error = (...args) => logged.push(args.join(' ')); // the plugin logs contained failures; keep output clean

let generation = 0;
let failures = 0;
const load = (p = modPath) => import(`${pathToFileURL(p).href}?t=${++generation}`); // fresh module, fresh caches
const t = async (name, fn) => {
  try { await fn(); console.log(`  [PASS] ${name}`); } catch (e) { failures++; console.log(`  [FAIL] ${name}: ${e.message}`); }
};
const count = (messages) => messages.flatMap((m) => m.parts ?? m.content ?? [])
  .filter((p) => p.type === 'text' && p.text.startsWith(MARKER)).length;
const v1Event = (sessionID) => ({ messages: [{ info: { role: 'user', sessionID }, parts: [{ type: 'text', text: 'hi' }] }] });
const v2Event = (sessionID) => ({ sessionID, messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }] });
const top = (id) => ({ id });
const child = (id) => ({ id, parentID: 'parent' });

async function v1(sessions, p) {
  const mod = await load(p);
  const hooks = await mod.DevopsMutantPowersPlugin({
    client: { session: { get: async ({ path: { id } }) => ({ data: sessions(id) }) } },
  });
  return { hooks, inject: (event) => hooks['experimental.chat.messages.transform']({}, event) };
}
async function v2(sessions, add = () => {}, p) {
  const mod = await load(p);
  let inject;
  await mod.default.setup({
    skill: { transform: async (cb) => cb({ add }) },
    session: {
      get: async ({ sessionID }) => sessions(sessionID),
      hook: async (name, cb) => { if (name === 'context') inject = cb; },
    },
  });
  return { inject };
}

console.log('OpenCode V1:');
await t('config hook adds skills/ once and leaves the V2 array shape alone', async () => {
  const { hooks } = await v1(top);
  const cfg = {};
  await hooks.config(cfg); await hooks.config(cfg);
  assert.deepEqual(cfg.skills.paths, [skillsDir]);
  const v2cfg = { skills: [] };
  await hooks.config(v2cfg);
  assert.deepEqual(v2cfg.skills, []);
});
await t('bootstrap injected once as a user part, frontmatter stripped, package.json version in the marker', async () => {
  const { inject } = await v1(top);
  const ev = v1Event('v1-top');
  await inject(ev); await inject(ev);
  assert.equal(count(ev.messages), 1);
  const text = ev.messages[0].parts[0].text;
  assert.ok(!text.includes('\nname: using-devops-mutant-powers'), 'frontmatter must be stripped');
  assert.ok(text.includes('`todowrite`'), 'V1 tool mapping');
  assert.ok(text.endsWith('</EXTREMELY_IMPORTANT>'));
  assert.equal(ev.messages[0].parts[1].text, 'hi');
});
await t('child (task subagent) session gets no bootstrap', async () => {
  const { inject } = await v1(child);
  const ev = v1Event('v1-child');
  await inject(ev);
  assert.equal(count(ev.messages), 0);
});

console.log('OpenCode V2:');
await t('setup registers every skill as { id, name, description, path, content } without frontmatter', async () => {
  const added = [];
  await v2(top, (skill) => added.push(skill));
  const want = fs.readdirSync(skillsDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && fs.existsSync(path.join(skillsDir, e.name, 'SKILL.md'))).map((e) => e.name).sort();
  assert.deepEqual(added.map((s) => s.id).sort(), want);
  for (const s of added) {
    assert.equal(s.path, path.join(skillsDir, s.id, 'SKILL.md'), `${s.id}: path`);
    assert.equal(s.name, s.id, `${s.id}: name`);
    assert.ok(typeof s.description === 'string' && s.description.length > 0, `${s.id}: description`);
    assert.ok(!s.content.startsWith('---'), `${s.id}: content still has frontmatter`);
    assert.ok(!('location' in s), `${s.id}: pre-2.0.4 field`);
  }
});
await t('a skill the host rejects is skipped; the others and the bootstrap survive', async () => {
  const ok = [];
  const { inject } = await v2(top, (s) => { if (s.id === 'kubernetes') throw new Error('rejected'); ok.push(s.id); });
  assert.ok(ok.length > 0 && !ok.includes('kubernetes'));
  const ev = v2Event('v2-survive');
  await inject(ev);
  assert.equal(count(ev.messages), 1);
});
await t('bootstrap injected once per top-level session, with the V2 tool mapping', async () => {
  const { inject } = await v2(top);
  const ev = v2Event('v2-top');
  await inject(ev); await inject(ev);
  assert.equal(count(ev.messages), 1);
  assert.ok(ev.messages[0].content[0].text.includes('`subagent` with `agent: "general"`'));
});
await t('child (task subagent) session gets no bootstrap', async () => {
  const { inject } = await v2(child);
  const ev = v2Event('v2-child');
  await inject(ev);
  assert.equal(count(ev.messages), 0);
});
await t('after compaction the checkpoint is kept and the bootstrap is appended as a user message', async () => {
  const { inject } = await v2(top);
  const checkpoint = { role: 'assistant', content: [{ type: 'compaction', encrypted: 'opaque' }] };
  const ev = { sessionID: 'v2-compacted', messages: [structuredClone(checkpoint)] };
  await inject(ev); await inject(ev);
  assert.deepEqual(ev.messages[0], checkpoint);
  assert.equal(ev.messages.length, 2);
  assert.equal(ev.messages[1].role, 'user');
  assert.equal(count(ev.messages), 1);
});
await t('a failed session lookup fails open and is retried, not cached', async () => {
  let calls = 0;
  const { inject } = await v2((id) => { calls++; if (calls === 1) throw new Error('503'); return child(id); });
  const first = v2Event('v2-retry'); await inject(first);
  const second = v2Event('v2-retry'); await inject(second);
  assert.deepEqual([count(first.messages), count(second.messages), calls], [1, 0, 2]);
});
await t('a V1-shaped ctx passed to default.setup is ignored', async () => {
  const mod = await load();
  await mod.default.setup({}); await mod.default.setup(undefined);
  assert.equal(mod.default.id, 'devops-mutant-powers');
});

console.log('OpenCode, bootstrap file missing:');
await t('no skills/ directory: nothing registered, nothing injected, no throw', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nsd-opencode-'));
  try {
    fs.mkdirSync(path.join(tmp, '.opencode/plugins'), { recursive: true });
    fs.copyFileSync(modPath, path.join(tmp, '.opencode/plugins/devops-mutant-powers.js'));
    fs.copyFileSync(path.join(root, 'package.json'), path.join(tmp, 'package.json'));
    const p = path.join(tmp, '.opencode/plugins/devops-mutant-powers.js');
    const { inject: i1 } = await v1(top, p);
    const e1 = v1Event('missing-v1'); await i1(e1);
    assert.equal(e1.messages[0].parts.length, 1);
    const added = [];
    const { inject: i2 } = await v2(top, (s) => added.push(s), p);
    const e2 = v2Event('missing-v2'); await i2(e2);
    assert.deepEqual([added.length, e2.messages[0].content.length], [0, 1]);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

console.log(failures ? `opencode plugin: ${failures} failure(s)` : 'opencode plugin: ALL OK');
process.exit(failures ? 1 : 0);
EOF
