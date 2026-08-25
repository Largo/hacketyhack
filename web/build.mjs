#!/usr/bin/env node
// Builds everything the page needs: the filesystem bundle and the boot script.
//
//   node web/build.mjs
//
// Re-run after changing any Ruby the browser loads. The wasm binary itself is
// served straight out of node_modules and never copied.
import { pack } from "./vfs.mjs";
import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const WEB = path.dirname(new URL(import.meta.url).pathname);
const REPO = path.resolve(WEB, "..");
const DIST = path.join(WEB, "dist");

// Where the gems live on this machine. Lacci and scarpe-components are pure
// Ruby, so they travel into wasm unchanged; nothing else in the Gemfile does.
//
// Resolved through web/Gemfile rather than the repo's own, and through Bundler
// rather than the ambient gem list. See web/Gemfile for why the browser pins
// its own Lacci; using Bundler is what makes that pin mean anything, and what
// makes this work on a machine that has only ever run `bundle install`.
function gemPaths(names) {
  const script = `print ${JSON.stringify(names)}.map { |name|
    Gem::Specification.find_by_name(name).full_gem_path
  }.join("\n")`;
  const out = execFileSync("bundle", ["exec", "ruby", "-e", script], {
    encoding: "utf8",
    cwd: WEB,
    env: { ...process.env, BUNDLE_GEMFILE: path.join(WEB, "Gemfile") },
  });
  return Object.fromEntries(names.map((name, i) => [name, out.trim().split("\n")[i]]));
}

const entries = [];
let skipped = 0;

function add(vfsPath, diskPath) {
  entries.push([vfsPath, new Uint8Array(fs.readFileSync(diskPath))]);
}

function addTree(vfsRoot, diskRoot, { include = () => true } = {}) {
  if (!fs.existsSync(diskRoot)) throw new Error(`missing: ${diskRoot}`);
  for (const entry of fs.readdirSync(diskRoot, { withFileTypes: true })) {
    const disk = path.join(diskRoot, entry.name);
    const vfs = `${vfsRoot}/${entry.name}`;
    if (entry.isDirectory()) addTree(vfs, disk, { include });
    else if (entry.isFile()) {
      if (include(vfs, disk)) add(vfs, disk);
      else skipped++;
    }
  }
}

// ---- the gems -----------------------------------------------------------

const gems = gemPaths(["lacci", "scarpe-components", "chunky_png"]);
addTree("/gems/lacci", path.join(gems["lacci"], "lib"));
addTree("/gems/scarpe-components", path.join(gems["scarpe-components"], "lib"));
addTree("/gems/chunky_png", path.join(gems["chunky_png"], "lib"));

// ---- Clogs and the shims ------------------------------------------------

addTree("/clogs", path.join(REPO, "clogs", "lib"));
addTree("/shims", path.join(WEB, "shims"));

// ---- Hackety Hack itself ------------------------------------------------
//
// The whole app, its samples, its lessons and its pictures. The one thing left
// behind is TakaoGothic, a 3.6 MB CJK font: `font()` is a no-op on every Clogs
// backend, so no bundled font is doing anything yet, and that one alone would
// be a third of the download.
const HEAVY_FONT = "/hh/fonts/TakaoGothic.otf";
for (const dir of ["app", "lib", "static", "samples", "lessons", "fonts", "root", "platform", "tools"]) {
  addTree(`/hh/${dir}`, path.join(REPO, dir), { include: (vfs) => vfs !== HEAVY_FONT });
}
for (const file of ["hacketyhack.rb", "h-ety-h.rb"]) {
  add(`/hh/${file}`, path.join(REPO, file));
}

// ---- the Ruby that starts it all ---------------------------------------

add("/boot.rb", path.join(WEB, "boot.rb"));

fs.mkdirSync(DIST, { recursive: true });
const bundle = pack(entries);
fs.writeFileSync(path.join(DIST, "vfs.bin"), bundle);

await esbuild.build({
  entryPoints: [path.join(WEB, "boot.js")],
  bundle: true,
  format: "esm",
  outfile: path.join(DIST, "boot.js"),
  logLevel: "warning",
});

const mb = (n) => (n / 1024 / 1024).toFixed(2) + " MB";
console.log(`vfs.bin: ${entries.length} files, ${mb(bundle.length)} (${skipped} skipped)`);
console.log(`boot.js: ${mb(fs.statSync(path.join(DIST, "boot.js")).size)}`);
