/**
 * devops-mutant-powers plugin for OpenCode, ported from obra/superpowers v6.4.2 (.opencode/plugins/superpowers.js).
 *
 * V1 (opencode 1.x) loads the named export: a `config` hook registers skills/ and
 * `experimental.chat.messages.transform` injects the bootstrap.
 * V2 (opencode 2.0.4+) loads the default export { id, setup }: setup() registers skills through
 * ctx.skill.transform() and injects the bootstrap through ctx.session.hook("context").
 * No dependencies: plain ESM that both flavors load as-is.
 */

import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pluginRoot = path.resolve(__dirname, '../..');
const skillsDir = path.join(pluginRoot, 'skills');
const BOOTSTRAP_SKILL = 'using-devops-mutant-powers';
const LOG = '[devops-mutant-powers]';

// Minimal frontmatter parser for name/description: plain, quoted and block-scalar values, CRLF. Not full YAML.
const extractAndStripFrontmatter = (content) => {
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { frontmatter: {}, content };

  const frontmatter = {};
  let lastKey = null;
  for (const rawLine of match[1].split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    const colonIdx = line.indexOf(':');
    if (colonIdx > 0 && !/^\s/.test(line)) {
      const key = line.slice(0, colonIdx).trim();
      const value = line.slice(colonIdx + 1).trim();
      frontmatter[key] = /^(>[+-]?|\|[+-]?)$/.test(value) ? '' : value;
      lastKey = key;
    } else if (lastKey !== null && line.trim() !== '') {
      frontmatter[lastKey] = `${frontmatter[lastKey]} ${line.trim()}`.trim();
    }
  }
  // Unquote only once the value is assembled: a quote may close on a continuation line.
  for (const key of Object.keys(frontmatter)) {
    frontmatter[key] = frontmatter[key].replace(/^(["'])([\s\S]*)\1$/, '$2');
  }
  return { frontmatter, content: match[2] };
};

// Build marker version: package.json is the copy OpenCode installs, and validate keeps it in parity.
const readVersion = () => {
  try {
    return JSON.parse(fs.readFileSync(path.join(pluginRoot, 'package.json'), 'utf8')).version || 'unknown';
  } catch {
    return 'unknown';
  }
};

// V1 built-ins: todowrite, task (subagent_type), skill, read, apply_patch, bash, grep, glob, webfetch.
export const V1_MAPPING = `**Tool Mapping for OpenCode:**
When skills request actions, substitute OpenCode equivalents:
- Create or update todos → \`todowrite\`
- \`Subagent (general-purpose):\` → \`task\` with \`subagent_type: "general"\`
- Invoke a skill → OpenCode's native \`skill\` tool
- Read files → \`read\`
- Create, edit, or delete files → \`apply_patch\`
- Run shell commands → \`bash\`
- Search files → \`grep\`, \`glob\`
- Fetch a URL → \`webfetch\`

Use OpenCode's native \`skill\` tool to list and load skills.`;

// V2 built-ins: no todo tool; task → subagent; apply_patch → patch; bash → shell.
export const V2_MAPPING = `**Tool Mapping for OpenCode:**
When skills request actions, substitute OpenCode equivalents:
- Create or update todos → OpenCode v2 has no todo tool; track the plan in a markdown file (or the harness's plan facility) instead
- \`Subagent (general-purpose):\` → \`subagent\` with \`agent: "general"\` (give it \`description\` and \`prompt\`, optionally \`background\`; pass \`sessionID\` to continue a previous subagent)
- Invoke a skill → OpenCode's native \`skill\` tool
- Read files → \`read\`
- Create, edit, or delete files → use \`patch\` with \`patchText\` when available; otherwise use \`write\` to create or overwrite files, \`edit\` for targeted changes, and \`shell\` for deletion
- Run shell commands → \`shell\` (\`command\`, \`workdir\`, \`timeout\`, \`background\`)
- Search files → \`grep\`, \`glob\`
- Fetch a URL → \`webfetch\`
- Search the web → \`websearch\`

Use OpenCode's native \`skill\` tool to list and load skills.`;

// Cached per mapping: the transform hook fires on every agent step (upstream issue 1202). null = file missing.
const _bootstrapCache = new Map();

const getBootstrapContent = (toolMapping) => {
  if (_bootstrapCache.has(toolMapping)) return _bootstrapCache.get(toolMapping);

  const skillPath = path.join(skillsDir, BOOTSTRAP_SKILL, 'SKILL.md');
  if (!fs.existsSync(skillPath)) {
    _bootstrapCache.set(toolMapping, null);
    return null;
  }
  const { content } = extractAndStripFrontmatter(fs.readFileSync(skillPath, 'utf8'));

  _bootstrapCache.set(toolMapping, `<EXTREMELY_IMPORTANT>
You have devops-mutant-powers v${readVersion()}.

**IMPORTANT: The ${BOOTSTRAP_SKILL} skill content is included below. It is ALREADY LOADED - you are currently following it. Do NOT use the skill tool to load "${BOOTSTRAP_SKILL}" again - that would be redundant.**

${content}

${toolMapping}
</EXTREMELY_IMPORTANT>`);
  return _bootstrapCache.get(toolMapping);
};

// Child (task subagent) sessions carry a parentID; they skip the controller bootstrap (upstream issue 2160).
// Bounded cache: the V2 server is long-lived. On overflow drop the oldest quarter.
const CHILD_SESSION_CACHE_MAX = 512;
const _childSessionCache = new Map();

const _cacheChildSession = (sessionID, isChild) => {
  if (_childSessionCache.size >= CHILD_SESSION_CACHE_MAX) {
    let toDrop = Math.ceil(CHILD_SESSION_CACHE_MAX / 4);
    for (const key of _childSessionCache.keys()) {
      if (toDrop-- <= 0) break;
      _childSessionCache.delete(key);
    }
  }
  _childSessionCache.set(sessionID, isChild);
};

const isChildSession = async (fetchSession, sessionID) => {
  if (!sessionID) return false;
  if (_childSessionCache.has(sessionID)) return _childSessionCache.get(sessionID);

  let isChild = false;
  try {
    const result = await fetchSession(sessionID);
    // V1 returns an SDK envelope, V2 the session record; validate both before classifying.
    if (!result || typeof result !== 'object' || Array.isArray(result)) {
      throw new Error('Session lookup returned no usable record');
    }
    if (result.error != null || result.response?.ok === false) {
      throw new Error('Session lookup was unsuccessful');
    }
    const session = 'data' in result ? result.data : result;
    if (!session || typeof session !== 'object' || Array.isArray(session) || session.id !== sessionID) {
      throw new Error('Session lookup returned an invalid session identity');
    }
    if (session.parentID !== undefined &&
        (typeof session.parentID !== 'string' || session.parentID.length === 0)) {
      throw new Error('Session lookup returned an invalid parent identity');
    }
    isChild = session.parentID !== undefined;
  } catch (err) {
    // Fail open and do not cache, so a transient failure recovers on the next step.
    console.error(`${LOG} session lookup failed, treating session as top-level:`, err);
    return false;
  }
  _cacheChildSession(sessionID, isChild);
  return isChild;
};

/** V1 plugin function (named export, also default.server). */
export const DevopsMutantPowersPlugin = async ({ client }) => {
  return {
    // Register skills/ in the live config: no symlinks or user config edits.
    config: async (config) => {
      if (Array.isArray(config.skills)) return; // V2 shape: setup() registers skills
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(skillsDir)) {
        config.skills.paths.push(skillsDir);
      }
    },

    // User message, not system message: repeated system messages bloat tokens (upstream 750) and break some models (894).
    'experimental.chat.messages.transform': async (_input, output) => {
      const bootstrap = getBootstrapContent(V1_MAPPING);
      if (!bootstrap || !output.messages.length) return;
      const firstUser = output.messages.find(m => m.info.role === 'user');
      if (!firstUser || !firstUser.parts.length) return;
      if (firstUser.parts.some(p => p.type === 'text' && p.text.includes('EXTREMELY_IMPORTANT'))) return;

      // V1 passes no input to this hook, so the sessionID comes from the message record.
      if (client && await isChildSession(
        (id) => client.session.get({ path: { id } }),
        firstUser.info.sessionID,
      )) return;

      const ref = firstUser.parts[0];
      firstUser.parts.unshift({ ...ref, type: 'text', text: bootstrap });
    }
  };
};

/** V2 setup (default.setup), called by the V2 PluginSupervisor. */
async function setup(ctx) {
  // V1 also calls default.setup with a ctx lacking skill/session; V1 is served by the named export.
  if (!ctx || !ctx.skill || typeof ctx.skill.transform !== 'function' || !ctx.session || typeof ctx.session.hook !== 'function') {
    return;
  }

  // 1. Register every skills/<name>/SKILL.md as Skill.Info { id, name, description?, path, content }.
  try {
    const skills = [];
    if (fs.existsSync(skillsDir)) {
      for (const entry of fs.readdirSync(skillsDir, { withFileTypes: true })) {
        if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
        const skillPath = path.join(skillsDir, entry.name, 'SKILL.md');
        if (!fs.existsSync(skillPath)) continue;
        const { frontmatter, content } = extractAndStripFrontmatter(fs.readFileSync(skillPath, 'utf8'));
        skills.push({
          id: entry.name,
          name: frontmatter.name || entry.name,
          ...(frontmatter.description ? { description: frontmatter.description } : {}),
          path: skillPath, // `location` before OpenCode 2.0.4
          content,
        });
      }
    }
    await ctx.skill.transform((draft) => {
      // A throw escaping this callback makes the host disable the whole plugin; contain it per skill.
      for (const skill of skills) {
        try {
          draft.add(skill);
        } catch (err) {
          console.error(`${LOG} skill "${skill.id}" rejected by host, skipping:`, err);
        }
      }
    });
  } catch (err) {
    // Never break activation: one failing plugin takes down the whole V2 generation.
    console.error(`${LOG} skill registration failed:`, err);
  }

  // 2. Inject the bootstrap into the first user message (V2 equivalent of the V1 transform).
  try {
    await ctx.session.hook('context', async (event) => {
      try {
        const bootstrap = getBootstrapContent(V2_MAPPING);
        if (!bootstrap || !event.messages || !event.messages.length) return;
        const firstUser = event.messages.find(m => m.role === 'user');
        if (firstUser && (!firstUser.content || !firstUser.content.length)) return;
        if (firstUser?.content.some(p => p.type === 'text' && p.text && p.text.includes('EXTREMELY_IMPORTANT'))) return;

        if (typeof ctx.session.get === 'function' && await isChildSession(
          (id) => ctx.session.get({ sessionID: id }),
          event.sessionID,
        )) return;

        // Compaction can leave only an opaque checkpoint: keep it and append the bootstrap as a user message.
        if (firstUser) {
          firstUser.content.unshift({ type: 'text', text: bootstrap });
        } else {
          event.messages.push({ role: 'user', content: [{ type: 'text', text: bootstrap }] });
        }
      } catch (err) {
        console.error(`${LOG} context hook failed:`, err);
      }
    });
  } catch (err) {
    console.error(`${LOG} session hook registration failed:`, err);
  }
}

export default {
  id: 'devops-mutant-powers',
  server: DevopsMutantPowersPlugin,
  setup,
};
