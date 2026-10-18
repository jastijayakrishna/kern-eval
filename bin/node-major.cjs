const fs = require('fs');
const path = require('path');
const semver = require(process.env.SEMVER_PATH);

const dir = process.argv[2];
const read = (f) => { try { return fs.readFileSync(path.join(dir, f), 'utf8').trim(); } catch { return null; } };
const LTS = { argon: 4, boron: 6, carbon: 8, dubnium: 10, erbium: 12, fermium: 14, gallium: 16, hydrogen: 18, iron: 20, jod: 22, krypton: 24 };
const PREFERRED = [22, 24, 20, 18, 16];
const DEFAULT = 22;

function fromText(t) {
  if (!t) return null;
  t = t.split('\n')[0].trim().replace(/^v/i, '');
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

let pkg = {};
try { pkg = JSON.parse(read('package.json') || '{}'); } catch { pkg = {}; }
let major = fromText(read('.nvmrc')) ?? fromText(read('.node-version'));
if (major == null) {
  const tv = read('.tool-versions');
  const line = tv && tv.split('\n').find((l) => /^(nodejs|node)\s/.test(l));
  if (line) major = fromText(line.split(/\s+/)[1]);
}
if (major == null && pkg.volta && pkg.volta.node) major = fromText(String(pkg.volta.node));
if (major == null && pkg.engines) major = fromRange(pkg.engines.node);
process.stdout.write(String(major ?? DEFAULT));
