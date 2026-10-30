// The WebAssembly formatters' host (#158, ADR 0010), loaded into each
// formatter's context before its own glue. JavaScriptCore has no
// TextEncoder or TextDecoder, which the glue uses for UTF-8.
globalThis.TextEncoder = class {
  encode(text = "") {
    const out = [];
    for (const ch of text) {
      const c = ch.codePointAt(0);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }
  encodeInto(text, view) {
    const bytes = this.encode(text);
    const written = Math.min(bytes.length, view.length);
    view.set(bytes.subarray(0, written));
    return { read: text.length, written };
  }
};

globalThis.TextDecoder = class {
  decode(bytes) {
    if (!bytes) return "";
    const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.buffer || bytes);
    const parts = [];
    let chunk = [];
    for (let i = 0; i < b.length;) {
      let c = b[i++];
      if (c >= 0xf0) c = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
      else if (c >= 0xe0) c = ((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
      else if (c >= 0xc0) c = ((c & 31) << 6) | (b[i++] & 63);
      chunk.push(c);
      if (chunk.length === 8192) { parts.push(String.fromCodePoint(...chunk)); chunk = []; }
    }
    parts.push(String.fromCodePoint(...chunk));
    return parts.join("");
  }
};

// gofmt and shfmt: a module that imports nothing, with alloc, format,
// output_ptr, output_len and dispose (as their wasm-fmt bindings use it).
function __formatWithMemory(wasm, source, options, path) {
  const write = (text) => {
    const bytes = new TextEncoder().encode(text);
    const pointer = wasm.alloc(bytes.length);
    new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
  };
  try {
    if (options && wasm.set_options) { write(JSON.stringify(options)); wasm.set_options(); }
    if (path && wasm.set_path) { write(path); wasm.set_path(); }
    write(source);
    const result = wasm.format();
    if (result === 0) return source;
    const text = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, wasm.output_ptr(), wasm.output_len()));
    if (result === 1) return text;
    throw new Error(text);
  } finally {
    wasm.dispose();
  }
}
