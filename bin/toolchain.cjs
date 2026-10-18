const fs = require('fs');
const path = require('path');
const semver = require(process.env.SEMVER_PATH);

const dir = process.argv[2];
const read = (f) => { try { return fs.readFileSync(path.join(dir, f), 'utf8'); } catch { return null; } };
const LTS = { argon: 4, boron: 6, carbon: 8, dubnium: 10, erbium: 12, fermium: 14, gallium: 16, hydrogen: 18, iron: 20, jod: 22, krypton: 24 };
const PREFERRED = [22, 24, 20, 18, 16];
const DEFAULT = 22;
const STEP_END = /\n\s*-\s/;
const PNPM_VERSION = /(?<![\w-])version:\s*['"]?(\d+(?:\.\d+){0,2})/;
const NODE_VERSION = /(?<![\w-])node-version:\s*['"]?(\d+)/;

function fromText(t) {
  if (!t) return null;
  t = t.trim().split('\n')[0].trim().replace(/^v/i, '');
  let m = t.match(/^(\d+)/);
  if (m) return Number(m[1]);
  m = t.toLowerCase().match(/^lts\/([a-z]+)/);
  if (m) return LTS[m[1]] || DEFAULT;
  if (/^(lts|node|latest|stable|current|\*)/i.test(t)) return DEFAULT;
  return null;
}

function fromRange(r) {
  if (typeof r !== 'string' || !semver.validRange(r)) return null;
  for (const m of PREFERRED) if (semver.intersects(r, `${m}.x`)) return m;
  return null;
}

function workflows() {
  let names = [];
  try { names = fs.readdirSync(path.join(dir, '.github', 'workflows')).filter((f) => /\.ya?ml$/.test(f)).sort(); } catch { return []; }
  return names.map((f) => read(path.join('.github', 'workflows', f)) || '');
}

function ciVersions() {
  let node = null;
  let pnpm = null;
  for (const text of workflows()) {
    if (pnpm == null) {
      let at = text.indexOf('pnpm/action-setup');
      while (at >= 0 && pnpm == null) {
        const rest = text.slice(at);
        const end = rest.slice(1).search(STEP_END);
        const m = (end >= 0 ? rest.slice(0, end + 1) : rest).match(PNPM_VERSION);
        if (m) pnpm = m[1];
        at = text.indexOf('pnpm/action-setup', at + 1);
      }
    }
    if (node == null) {
      const m = text.match(NODE_VERSION);
      if (m) node = Number(m[1]);
    }
  }
  return { node, pnpm };
}

let pkg = {};
try { pkg = JSON.parse(read('package.json') || '{}'); } catch { pkg = {}; }
const ci = ciVersions();
const toolVersions = read('.tool-versions');
const toolLine = toolVersions && toolVersions.split('\n').find((l) => /^(nodejs|node)\s/.test(l));
const candidates = [
  ['nvmrc', fromText(read('.nvmrc'))],
  ['node-version-file', fromText(read('.node-version'))],
  ['tool-versions', toolLine ? fromText(toolLine.split(/\s+/)[1]) : null],
  ['volta', pkg.volta && pkg.volta.node ? fromText(String(pkg.volta.node)) : null],
  ['ci', ci.node],
  ['engines', pkg.engines ? fromRange(pkg.engines.node) : null],
];
const [source, node] = candidates.find(([, v]) => v != null) || ['default', DEFAULT];
process.stdout.write(JSON.stringify({ node, node_source: source, ci_pnpm: ci.pnpm }));
