#!/usr/bin/env node
// A static server for web/, with the Ruby wasm binary mapped in from
// node_modules so nothing has to be copied around.
//
//   node web/serve.mjs [port]
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const WEB = path.dirname(new URL(import.meta.url).pathname);
const PORT = Number(process.argv[2] || process.env.PORT || 4173);
const RUBY_WASM = path.join(WEB, "node_modules/@ruby/4.0-wasm-wasi/dist/ruby+stdlib.wasm");

const TYPES = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".json": "application/json", ".wasm": "application/wasm",
  ".bin": "application/octet-stream", ".png": "image/png", ".map": "application/json",
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  let file = url.pathname === "/" ? "/index.html" : url.pathname;
  file = file === "/ruby.wasm" ? RUBY_WASM : path.join(WEB, path.normalize(file).replace(/^(\.\.[/\\])+/, ""));

  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("not found: " + url.pathname);
      return;
    }
    res.writeHead(200, {
      "content-type": TYPES[path.extname(file)] || "application/octet-stream",
      "cache-control": "no-store",
    });
    res.end(data);
  });
});

server.listen(PORT, () => console.log(`http://localhost:${PORT}`));
