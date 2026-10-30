// Cuts an installed node_modules down to what the service bundle still loads from it at run time:
// the named packages and everything they depend on, resolved the way Node resolves them. Everything
// else was inlined into the bundle, or is part of @jxsuite/server that the service never reaches.
//
//   node scripts/prune-modules.mjs <node_modules> <package>...
//
// A package installed nested under a kept one travels with its directory; its own dependencies are
// still followed. A missing `dependencies` entry is an error, a missing optional or peer one is not
// (another platform's binary, or a peer nobody installed).
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";

const [modules, ...roots] = process.argv.slice(2);
if (!modules || roots.length === 0) {
  console.error("usage: prune-modules.mjs <node_modules> <package>...");
  process.exit(2);
}
const top = dirname(modules);

/** The directory `name` resolves to from `fromDir`, walking up through node_modules to `top`. */
function resolveDir(name, fromDir) {
  for (let dir = fromDir; ; dir = dirname(dir)) {
    const candidate = join(dir, "node_modules", name);
    if (existsSync(join(candidate, "package.json"))) {
      return candidate;
    }
    if (dir === top || dirname(dir) === dir) {
      return null;
    }
  }
}

const keep = new Set();
const queue = roots.map((name) => {
  const dir = resolveDir(name, top);
  if (!dir) {
    throw new Error(`${name} is not installed in ${modules}`);
  }
  return dir;
});
for (let dir = queue.pop(); dir; dir = queue.pop()) {
  if (keep.has(dir)) {
    continue;
  }
  keep.add(dir);
  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const wanted = {
    ...manifest.peerDependencies,
    ...manifest.optionalDependencies,
    ...manifest.dependencies,
  };
  for (const name of Object.keys(wanted)) {
    const found = resolveDir(name, dir);
    if (found) {
      queue.push(found);
    } else if (manifest.dependencies?.[name]) {
      throw new Error(`${name}, a dependency of ${dir}, is not installed`);
    }
  }
}

let removed = 0;
for (const entry of readdirSync(modules)) {
  const names = entry.startsWith("@")
    ? readdirSync(join(modules, entry)).map((name) => join(entry, name))
    : [entry];
  for (const name of names) {
    const dir = join(modules, name);
    if (!keep.has(dir)) {
      rmSync(dir, { recursive: true, force: true });
      removed += 1;
    }
  }
  if (entry.startsWith("@") && readdirSync(join(modules, entry)).length === 0) {
    rmSync(join(modules, entry), { recursive: true });
  }
}
console.log(`prune-modules: kept ${keep.size} packages, removed ${removed} top-level entries`);
