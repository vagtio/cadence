/* LX 音源 runtime glue.
 *
 * Mirrors the surface Q-music exposes to user source scripts through
 * src/main/modules/userApi/renderer/preload.js, on top of a JavaScriptCore
 * context instead of a Chromium renderer.
 */
(() => {
  'use strict';

  const N = globalThis.__native;
  const report = (level, msg) => { try { N.log(level, String(msg)); } catch {} };
  const parseJSON = (text, what) => {
    try { return JSON.parse(text); } catch (error) { throw new Error(`${what}: ${(error && error.message) || error}`); }
  };

  // ---------------------------------------------------------------- encoding

  const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const B64_LOOKUP = (() => {
    const table = new Int16Array(256).fill(-1);
    for (let i = 0; i < B64_CHARS.length; i++) table[B64_CHARS.charCodeAt(i)] = i;
    table['='.charCodeAt(0)] = -2;
    return table;
  })();

  function b64encode(bytes) {
    let out = '';
    const len = bytes.length;
    for (let i = 0; i < len; i += 3) {
      const b0 = bytes[i];
      const b1 = i + 1 < len ? bytes[i + 1] : 0;
      const b2 = i + 2 < len ? bytes[i + 2] : 0;
      out += B64_CHARS[b0 >> 2];
      out += B64_CHARS[((b0 & 3) << 4) | (b1 >> 4)];
      out += i + 1 < len ? B64_CHARS[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += i + 2 < len ? B64_CHARS[b2 & 63] : '=';
    }
    return out;
  }

  function b64decode(str) {
    const clean = String(str).replace(/[\s\r\n]/g, '');
    const padded = clean.length % 4 === 0 ? clean : clean + '='.repeat(4 - (clean.length % 4));
    const out = [];
    for (let i = 0; i < padded.length; i += 4) {
      const c0 = B64_LOOKUP[padded.charCodeAt(i)];
      const c1 = B64_LOOKUP[padded.charCodeAt(i + 1)];
      const c2 = B64_LOOKUP[padded.charCodeAt(i + 2)];
      const c3 = B64_LOOKUP[padded.charCodeAt(i + 3)];
      if (c0 < 0 || c1 < 0) continue;
      out.push((c0 << 2) | (c1 >> 4));
      if (c2 >= 0) out.push(((c1 & 15) << 4) | (c2 >> 2));
      if (c3 >= 0) out.push(((c2 & 3) << 6) | c3);
    }
    return new Uint8Array(out);
  }

  function utf8Encode(str) {
    const s = String(str);
    const out = [];
    for (let i = 0; i < s.length; i++) {
      let code = s.charCodeAt(i);
      if (code < 0x80) { out.push(code); continue; }
      if (code < 0x800) { out.push(0xc0 | (code >> 6), 0x80 | (code & 63)); continue; }
      if (code >= 0xd800 && code <= 0xdbff) {
        const next = s.charCodeAt(i + 1);
        const cp = 0x10000 + ((code & 0x3ff) << 10) + (next & 0x3ff);
        i++;
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        continue;
      }
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
    return new Uint8Array(out);
  }

  function utf8Decode(bytes) {
    let out = '';
    let i = 0;
    while (i < bytes.length) {
      const b = bytes[i++];
      if (b < 0x80) { out += String.fromCharCode(b); continue; }
      if (b < 0xe0) { out += String.fromCharCode(((b & 31) << 6) | (bytes[i++] & 63)); continue; }
      if (b < 0xf0) {
        out += String.fromCharCode(((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
        continue;
      }
      const cp = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      out += String.fromCharCode(((cp - 0x10000) >> 10) | 0xd800, ((cp - 0x10000) & 0x3ff) | 0xdc00);
    }
    return out;
  }

  function binaryString(bytes) {
    let out = '';
    for (let i = 0; i < bytes.length; i += 8192) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + 8192, bytes.length)));
    }
    return out;
  }

  // ------------------------------------------------------------------ Buffer

  class LxBuffer extends Uint8Array {
    toString(format) {
      switch (String(format || 'utf8').toLowerCase()) {
        case 'hex': {
          let out = '';
          for (let i = 0; i < this.length; i++) out += (this[i] < 16 ? '0' : '') + this[i].toString(16);
          return out;
        }
        case 'base64': return b64encode(this);
        case 'binary':
        case 'latin1': return binaryString(this);
        default: return utf8Decode(this);
      }
    }
    static isBuffer(value) { return value instanceof LxBuffer; }
    static from(value, encoding) {
      if (value instanceof Uint8Array) return new LxBuffer(value);
      if (value instanceof ArrayBuffer) return new LxBuffer(new Uint8Array(value));
      if (Array.isArray(value)) return new LxBuffer(value);
      if (typeof value === 'string') {
        switch (String(encoding || 'utf8').toLowerCase()) {
          case 'base64': return new LxBuffer(b64decode(value));
          case 'hex': {
            const bytes = [];
            for (let i = 0; i < value.length; i += 2) bytes.push(parseInt(value.substr(i, 2), 16));
            return new LxBuffer(bytes);
          }
          case 'binary':
          case 'latin1': {
            const bytes = new Uint8Array(value.length);
            for (let i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 0xff;
            return new LxBuffer(bytes);
          }
          default: return new LxBuffer(utf8Encode(value));
        }
      }
      if (typeof value === 'number') return new LxBuffer(new Uint8Array(value));
      throw new TypeError('Unsupported buffer input');
    }
  }

  const asBytes = value => (value instanceof Uint8Array ? value : LxBuffer.from(value));

  // -------------------------------------------------------- missing web APIs

  if (typeof globalThis.atob !== 'function') {
    globalThis.atob = input => binaryString(b64decode(input));
  }
  if (typeof globalThis.btoa !== 'function') {
    globalThis.btoa = input => b64encode(LxBuffer.from(String(input), 'latin1'));
  }
  if (typeof globalThis.TextEncoder !== 'function') {
    globalThis.TextEncoder = class TextEncoder {
      get encoding() { return 'utf-8'; }
      encode(input = '') { return utf8Encode(input); }
    };
  }
  if (typeof globalThis.TextDecoder !== 'function') {
    globalThis.TextDecoder = class TextDecoder {
      constructor(label = 'utf-8') { this.encoding = label; }
      decode(input = new Uint8Array(0)) { return utf8Decode(asBytes(input)); }
    };
  }
  if (typeof globalThis.URL !== 'function') {
    // Minimal resolver: enough for scripts doing `new URL(path, base).href`.
    globalThis.URL = class URLShim {
      constructor(input, base) { this.href = URLShim.resolve(String(input), base ? String(base) : undefined); }
      toString() { return this.href; }
      static resolve(input, base) {
        if (/^[a-z][a-z0-9+.-]*:/i.test(input)) return input;
        if (!base) return input;
        const match = /^([a-z][a-z0-9+.-]*:\/\/[^/?#]+)([^?#]*)/i.exec(base);
        if (!match) return input;
        if (input.startsWith('//')) return match[1].split(':')[0] + ':' + input;
        const origin = match[1];
        if (input.startsWith('/')) return origin + input;
        const dir = match[2].replace(/[^/]*$/, '');
        return origin + dir + input;
      }
    };
  }
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;

  globalThis.console = {
    log: (...args) => report('log', args.join(' ')),
    info: (...args) => report('info', args.join(' ')),
    warn: (...args) => report('warn', args.join(' ')),
    error: (...args) => report('error', args.join(' ')),
    debug: (...args) => report('debug', args.join(' ')),
  };

  // ---------------------------------------------------------------- timers

  const timers = new Map();
  let timerSeq = 1;

  globalThis.setTimeout = (fn, ms, ...args) => {
    const id = timerSeq++;
    timers.set(id, { repeat: false, fn: typeof fn === 'function' ? () => fn(...args) : () => (0, eval)(String(fn)) });
    N.scheduleTimer(id, Number(ms) || 0, false);
    return id;
  };
  globalThis.setInterval = (fn, ms, ...args) => {
    const id = timerSeq++;
    timers.set(id, { repeat: true, fn: typeof fn === 'function' ? () => fn(...args) : () => (0, eval)(String(fn)) });
    N.scheduleTimer(id, Number(ms) || 0, true);
    return id;
  };
  globalThis.clearTimeout = globalThis.clearInterval = id => {
    timers.delete(id);
    N.clearTimer(id);
  };

  globalThis.__lx_onTimer = id => {
    const timer = timers.get(id);
    if (!timer) return;
    if (!timer.repeat) timers.delete(id);
    try { timer.fn(); } catch (error) { report('error', `timer ${id}: ${error && error.message}`); }
  };

  // ----------------------------------------------------------- http helpers

  const requests = new Map();
  let requestSeq = 1;

  const headerValue = (headers, name) => {
    const key = Object.keys(headers || {}).find(k => k.toLowerCase() === name.toLowerCase());
    return key ? headers[key] : undefined;
  };

  const encodeBody = (options, headers) => {
    if (options.body !== undefined && options.body !== null) {
      const body = options.body;
      if (body instanceof Uint8Array) return b64encode(body);
      if (typeof body === 'string') return b64encode(utf8Encode(body));
      if (headerValue(headers, 'content-type') === undefined) headers['Content-Type'] = 'application/json';
      return b64encode(utf8Encode(JSON.stringify(body)));
    }
    if (options.form) {
      if (headerValue(headers, 'content-type') === undefined) headers['Content-Type'] = 'application/x-www-form-urlencoded';
      const encoded = Object.keys(options.form)
        .map(key => `${encodeURIComponent(key)}=${encodeURIComponent(options.form[key])}`)
        .join('&');
      return b64encode(utf8Encode(encoded));
    }
    if (options.formData) {
      const boundary = '----lxformboundary' + Math.random().toString(16).slice(2);
      if (headerValue(headers, 'content-type') === undefined) headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
      const parts = [];
      for (const [key, value] of Object.entries(options.formData)) {
        parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${value}\r\n`);
      }
      parts.push(`--${boundary}--\r\n`);
      return b64encode(utf8Encode(parts.join('')));
    }
    return null;
  };

  function sendRequest(url, options, callback) {
    const headers = { ...(options.headers || {}) };
    const body = encodeBody(options, headers);
    const id = requestSeq++;
    if (typeof callback === 'function') requests.set(id, callback);
    N.request(JSON.stringify({
      url: String(url),
      method: String(options.method || 'GET'),
      headers,
      body,
      timeout: typeof options.timeout === 'number' && options.timeout > 0 ? Math.min(options.timeout, 60000) : 60000,
    }), id);
    return id;
  }

  globalThis.__lx_onResponse = (id, json) => {
    const callback = requests.get(id);
    if (!callback) return;
    requests.delete(id);
    let payload;
    try { payload = parseJSON(json, 'bad response envelope'); } catch { return callback.call(null, new Error('bad response envelope'), null, null); }
    if (!payload.ok) return callback.call(null, new Error(payload.error || 'request failed'), null, null);
    try {
      const bytes = b64decode(payload.body || '');
      const raw = new LxBuffer(bytes);
      const text = utf8Decode(bytes);
      let parsed = text;
      try { parsed = parseJSON(text, 'response body'); } catch {}
      const response = {
        statusCode: payload.statusCode,
        statusMessage: payload.statusMessage,
        headers: payload.headers || {},
        bytes: bytes.length,
        raw,
        body: parsed,
        url: payload.url,
      };
      return callback.call(null, null, response, parsed);
    } catch (error) {
      return callback.call(null, error, null, null);
    }
  };

  globalThis.fetch = (input, init = {}) => new Promise((resolve, reject) => {
    const options = {
      method: init.method || 'GET',
      headers: { ...(init.headers || {}) },
      body: init.body,
      timeout: init.timeout,
    };
    const id = sendRequest(typeof input === 'string' ? input : String(input && input.url), options, (error, response) => {
      if (error) return reject(error);
      const text = typeof response.body === 'string' ? response.body : JSON.stringify(response.body);
      resolve({
        ok: response.statusCode >= 200 && response.statusCode < 300,
        status: response.statusCode,
        statusText: response.statusMessage,
        url: response.url,
        headers: { get: name => headerValue(response.headers, name) ?? null },
        text: async () => text,
        json: async () => parseJSON(text, 'fetch json'),
        arrayBuffer: async () => response.raw.buffer,
      });
    });
    const signal = init.signal;
    if (signal && typeof signal.addEventListener === 'function') {
      signal.addEventListener('abort', () => {
        requests.delete(id);
        N.abortRequest(id);
        reject(new Error('aborted'));
      });
    }
  });

  // -------------------------------------------------------------------- lx

  const EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };
  const handlers = { request: null };
  const allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local'];
  const supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: [],
  };
  const supportActions = {
    kw: ['musicUrl'], kg: ['musicUrl'], tx: ['musicUrl'], wy: ['musicUrl'],
    mg: ['musicUrl'], xm: ['musicUrl'], local: ['musicUrl', 'lyric', 'pic'],
  };

  const envelope = (op, args) => {
    const result = parseJSON(N.crypto(op, JSON.stringify(args)), 'crypto bridge');
    if (!result.ok) throw new Error(result.error);
    return result.data;
  };

  const parseScriptInfo = source => {
    const read = key => {
      const match = new RegExp(`^\\s*\\*?\\s*@${key}\\s+(.+)$`, 'm').exec(source);
      return match ? match[1].trim() : '';
    };
    return {
      name: read('name'),
      description: read('description'),
      version: read('version'),
      author: read('author'),
      homepage: read('homepage'),
      rawScript: source,
    };
  };

  let scriptInfo = null;
  const currentScriptInfo = () => {
    if (!scriptInfo) scriptInfo = parseScriptInfo(globalThis.__lxRawScript || '');
    return scriptInfo;
  };

  const lx = {
    EVENT_NAMES,
    version: '2.0.0',
    env: 'desktop',
    get currentScriptInfo() { return currentScriptInfo(); },

    request(url, options = {}, callback) {
      const id = sendRequest(url, options || {}, callback);
      return () => {
        requests.delete(id);
        N.abortRequest(id);
      };
    },

    send(eventName, data) {
      return new Promise((resolve, reject) => {
        switch (eventName) {
          case EVENT_NAMES.inited: {
            if (!data) return reject(new Error('Missing required parameter init info'));
            const sources = {};
            try {
              for (const source of allSources) {
                const userSource = data.sources[source];
                if (!userSource || userSource.type !== 'music') continue;
                sources[source] = {
                  type: 'music',
                  actions: supportActions[source].filter(action => (userSource.actions || []).includes(action)),
                  qualitys: supportQualitys[source].filter(quality => (userSource.qualitys || []).includes(quality)),
                };
              }
            } catch (error) {
              return reject(error);
            }
            N.onInited(JSON.stringify({ status: true, sources }));
            return resolve();
          }
          case EVENT_NAMES.updateAlert:
            report('log', `updateAlert: ${data && data.log}`);
            return resolve();
          default:
            return reject(new Error(`Unknown event name: ${eventName}`));
        }
      });
    },

    on(eventName, handler) {
      if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error(`The event is not supported: ${eventName}`));
      handlers.request = handler;
      return Promise.resolve();
    },

    utils: {
      crypto: {
        md5(str) { return envelope('md5', { data: String(str) }); },
        randomBytes(size) { return LxBuffer.from(b64decode(envelope('randomBytes', { size: Number(size) || 16 }))); },
        aesEncrypt(buffer, mode, key, iv) {
          return LxBuffer.from(b64decode(envelope('aesEncrypt', {
            data: b64encode(asBytes(buffer)),
            mode: String(mode),
            key: b64encode(asBytes(key)),
            iv: iv ? b64encode(asBytes(iv)) : null,
          })));
        },
        rsaEncrypt(buffer, key) {
          return LxBuffer.from(b64decode(envelope('rsaEncrypt', {
            data: b64encode(asBytes(buffer)),
            key: String(key),
          })));
        },
      },
      buffer: {
        from(...args) { return LxBuffer.from(...args); },
        bufToString(buffer, format) { return LxBuffer.from(buffer).toString(format); },
      },
      zlib: {
        inflate(buffer) {
          return new Promise((resolve, reject) => {
            const result = parseJSON(N.zlib('inflate', b64encode(asBytes(buffer))), 'zlib inflate');
            result.ok ? resolve(LxBuffer.from(b64decode(result.data))) : reject(new Error(result.error));
          });
        },
        deflate(buffer) {
          return new Promise((resolve, reject) => {
            const result = parseJSON(N.zlib('deflate', b64encode(asBytes(buffer))), 'zlib deflate');
            result.ok ? resolve(LxBuffer.from(b64decode(result.data))) : reject(new Error(result.error));
          });
        },
      },
    },
  };

  globalThis.lx = lx;

  globalThis.__lx_invokeRequest = (source, action, infoJSON) => {
    if (!handlers.request) return N.onResult(false, 'Request event is not defined');
    let info;
    try { info = parseJSON(infoJSON, 'bad info'); } catch { return N.onResult(false, 'bad info'); }
    let promise;
    try {
      promise = handlers.request.call(lx, { source, action, info });
    } catch (error) {
      return N.onResult(false, String((error && error.message) || error));
    }
    Promise.resolve(promise).then(result => {
      if (action === 'musicUrl') {
        if (typeof result !== 'string' || result.length > 2048 || !/^https?:/.test(result)) {
          return N.onResult(false, 'invalid music url');
        }
        return N.onResult(true, JSON.stringify({ source, action, url: result }));
      }
      if (action === 'pic') {
        if (typeof result !== 'string' || result.length > 2048 || !/^https?:/.test(result)) {
          return N.onResult(false, 'invalid pic url');
        }
        return N.onResult(true, JSON.stringify({ source, action, url: result }));
      }
      return N.onResult(true, JSON.stringify({ source, action, data: result }));
    }).catch(error => N.onResult(false, String((error && error.message) || error)));
  };
})();
