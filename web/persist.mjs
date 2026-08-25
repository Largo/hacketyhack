// Keeping what you write.
//
// The wasm filesystem is built fresh in memory on every load and dies with the
// tab, so a program written in Hackety Hack was gone on reload -- while the
// preferences recording that you had been here *did* survive, in localStorage,
// which is how the IDE ended up greeting a returning user with "You have no
// programs".
//
// This mirrors one subtree -- the wasm home directory, where Hackety Hack
// keeps ~/.hacketyhack -- into localStorage, restoring it before Ruby starts
// and saving it back whenever it changes. It is deliberately about the whole
// subtree rather than about programs: anything the app writes there persists,
// which is the same promise a real home directory makes.

const KEY = "hh.home";

// localStorage is about 5MB per origin, and it is shared with the preferences
// database. A user's programs are a few KB of text; anything approaching this
// is a picture that got downloaded into the home directory, and dropping the
// save is better than throwing a quota error into the middle of a frame.
const LIMIT_BYTES = 3 * 1024 * 1024;

function encode(bytes) {
  let binary = "";
  // String.fromCharCode.apply blows the stack on a large array, so this goes in
  // chunks. Programs are small; downloaded files are not.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function decode(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// Walk a browser_wasi_shim Directory into something JSON can hold. Empty
// directories are recorded too: Hackety Hack makes ~/.hacketyhack/Downloads at
// boot and would rather find it than make it again.
export function snapshot(dir) {
  const files = {};
  const dirs = [];

  const walk = (node, prefix) => {
    for (const [name, entry] of node.contents) {
      const path = prefix ? `${prefix}/${name}` : name;
      if (entry.contents) {
        dirs.push(path);
        walk(entry, path);
      } else if (entry.data) {
        files[path] = encode(entry.data);
      } else {
        files[path] = "";
      }
    }
  };

  walk(dir, "");
  return { dirs, files };
}

export function apply(dir, snap, { File, Directory }) {
  if (!snap) return;

  const dirFor = (parts) => {
    let node = dir;
    for (const part of parts) {
      let child = node.contents.get(part);
      if (!child || !child.contents) {
        child = new Directory(new Map());
        node.contents.set(part, child);
      }
      node = child;
    }
    return node;
  };

  for (const path of snap.dirs || []) dirFor(path.split("/"));
  for (const [path, data] of Object.entries(snap.files || {})) {
    const parts = path.split("/");
    const name = parts.pop();
    dirFor(parts).contents.set(name, new File(decode(data)));
  }
}

export function load() {
  try {
    const raw = window.localStorage.getItem(KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (error) {
    console.warn("clogs: could not read the saved home directory", error);
    return null;
  }
}

// Saves only when something actually changed, so the common case -- an app
// sitting there animating -- costs one tree walk and a string compare rather
// than a localStorage write.
export function startAutosave(dir, { intervalMs = 2000 } = {}) {
  let lastSaved = null;

  const save = () => {
    let serialized;
    try {
      serialized = JSON.stringify(snapshot(dir));
    } catch (error) {
      console.warn("clogs: could not snapshot the home directory", error);
      return;
    }
    if (serialized === lastSaved) return;

    if (serialized.length > LIMIT_BYTES) {
      console.warn(
        `clogs: the home directory is ${Math.round(serialized.length / 1024)}KB, too big for localStorage; not saving`,
      );
      lastSaved = serialized;
      return;
    }

    try {
      window.localStorage.setItem(KEY, serialized);
      lastSaved = serialized;
    } catch (error) {
      console.warn("clogs: could not save the home directory", error);
      lastSaved = serialized; // don't retry every tick against a full store
    }
  };

  const timer = window.setInterval(save, intervalMs);
  // A reload or a closed tab should not lose the last few seconds of work.
  window.addEventListener("pagehide", save);
  window.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") save();
  });

  return { save, stop: () => window.clearInterval(timer) };
}

export function forget() {
  try {
    window.localStorage.removeItem(KEY);
  } catch {
    /* nothing to do */
  }
}
