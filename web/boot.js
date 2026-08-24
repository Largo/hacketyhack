// Starts CRuby in the page and hands it Hackety Hack.
import { RubyVM } from "@ruby/wasm-wasi";
import { WASI, OpenFile, File, Directory, PreopenDirectory, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { unpack, buildTree } from "./vfs.mjs";

const params = new URLSearchParams(location.search);

async function boot() {
  const [wasmModule, vfsBuffer] = await Promise.all([
    WebAssembly.compileStreaming(fetch("/ruby.wasm")),
    fetch("/dist/vfs.bin").then((r) => r.arrayBuffer()),
  ]);

  const { root, dirFor } = buildTree(unpack(vfsBuffer), { File, Directory });
  // Two directories nothing ships files into but Ruby and the app both write
  // to: HOME is where Hackety Hack keeps ~/.hacketyhack.
  dirFor(["home"]);
  dirFor(["tmp"]);

  const env = [
    "HOME=/home",
    "TMPDIR=/tmp",
    "RUBYOPT=-EUTF-8",
    `CLOGS_ENTRY=${params.get("entry") || "/hh/hacketyhack.rb"}`,
  ];

  // `?env.FOO=bar` sets an environment variable, which is how the Shoes
  // programs that read one -- the benchmarks in tools/, say -- are configured
  // from a URL.
  for (const [key, value] of params) {
    if (key.startsWith("env.")) env.push(`${key.slice(4)}=${value}`);
  }

  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => console.log(line)),
    ConsoleStdout.lineBuffered((line) => console.warn(line)),
    new PreopenDirectory("/", root),
  ];

  const wasi = new WASI(["ruby", "/boot.rb"], env, fds, { debug: false });
  const { vm } = await RubyVM.instantiateModule({ module: wasmModule, wasip1: wasi });

  window.__clogsVM = vm;
  vm.eval(`load "/boot.rb"`);
  window.__clogsReady = true;
}

window.__clogsStatus = "booting";
window.__clogsReady = false;
boot().catch((error) => {
  window.__clogsStatus = "error";
  window.__clogsError = String(error && error.stack ? error.stack : error);
  console.error(error);
});
