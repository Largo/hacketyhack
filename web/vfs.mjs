// The bundle format shared by the builder and the page.
//
// Ruby needs a real filesystem -- Hackety Hack reads its lessons, its samples
// and its pictures off disk, and `require` walks a load path -- so the browser
// gets one: an in-memory WASI directory tree. The tree is shipped as one file
// rather than as thousands of fetches: a little index at the front, every
// file's bytes laid end to end behind it.
//
//   [4 bytes LE] index length
//   [index]      JSON: [[path, offset, length], ...]
//   [data]       every file's bytes, in index order

export function pack(entries) {
  // `entries` is [[path, Uint8Array], ...].
  const index = [];
  let offset = 0;
  for (const [path, bytes] of entries) {
    index.push([path, offset, bytes.length]);
    offset += bytes.length;
  }
  const indexBytes = new TextEncoder().encode(JSON.stringify(index));
  const out = new Uint8Array(4 + indexBytes.length + offset);
  new DataView(out.buffer).setUint32(0, indexBytes.length, true);
  out.set(indexBytes, 4);
  let at = 4 + indexBytes.length;
  for (const [, bytes] of entries) {
    out.set(bytes, at);
    at += bytes.length;
  }
  return out;
}

export function unpack(buffer) {
  const view = new DataView(buffer);
  const indexLength = view.getUint32(0, true);
  const index = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 4, indexLength)));
  const base = 4 + indexLength;
  return index.map(([path, offset, length]) => [path, new Uint8Array(buffer, base + offset, length)]);
}

// Turn the flat path list into the nested Map tree browser_wasi_shim wants.
export function buildTree(entries, { File, Directory }) {
  const root = new Map();
  const dirFor = (parts) => {
    let map = root;
    for (const part of parts) {
      let dir = map.get(part);
      if (!dir) {
        dir = new Directory(new Map());
        map.set(part, dir);
      }
      map = dir.contents;
    }
    return map;
  };
  for (const [path, bytes] of entries) {
    const parts = path.split("/").filter(Boolean);
    const name = parts.pop();
    dirFor(parts).set(name, new File(bytes));
  }
  return { root, dirFor };
}
