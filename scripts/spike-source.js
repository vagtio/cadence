/*!
 * @name Spike 全表面音源
 * @description 走通 lx 桥的每个面：request/timers/crypto/buffer/zlib/promise
 * @version 1.0.0
 * @author lx-native-spike
 * @homepage https://example.invalid/spike
 */

// 与 Q-music 的 preload 一致：只依赖 globalThis.lx，不需要 window/document/Buffer。
const { EVENT_NAMES, request, on, send, utils } = globalThis.lx;

const SECRET = 'spike-secret';
const ENDPOINT = 'http://127.0.0.1:8765/v1/music/resolve-url';
const SUPPORT = {
  kg: ['128k', '320k', 'flac'],
  kw: ['128k', '320k'],
  tx: ['128k', '320k'],
  wy: ['128k', '320k'],
};

const sources = {};
for (const [source, qualitys] of Object.entries(SUPPORT)) {
  sources[source] = { type: 'music', actions: ['musicUrl'], qualitys };
}

// 1) 定时器 + Promise 包裹的 callback 风格 request
const add = (a, b) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('timeout')), 5000);
  request(`http://127.0.0.1:8765/v1/music/resolve-url?ping=${a}`, { method: 'GET', timeout: 5000 }, (err, resp) => {
    clearTimeout(timer);
    if (err) return reject(err);
    if (resp.statusCode !== 404) return reject(new Error(`unexpected status ${resp.statusCode}`));
    resolve(b);
  });
});

// 2) crypto + Buffer + zlib 往返
async function selfTest() {
  const digest = utils.crypto.md5('lx-spike');
  // 期望值由系统 md5(1) 独立算出，用来证明桥接实现与 Node 结果一致
  if (digest !== 'fabe9dc8807a4e1c49a040698fd60108') throw new Error(`md5 mismatch: ${digest}`);

  const key = utils.buffer.from('0123456789abcdef', 'utf-8');
  const iv = utils.buffer.from('fedcba9876543210', 'utf-8');
  const plain = utils.buffer.from('{"hello":"世界"}', 'utf-8');

  // Node 20 基准：createCipheriv('aes-128-cbc', key, iv) 的字节级结果
  const sealed = utils.crypto.aesEncrypt(plain, 'aes-128-cbc', key, iv);
  const sealedHex = utils.buffer.bufToString(sealed, 'hex');
  if (sealedHex !== '92a52406eb53294be345674bcc810f796e850ff4d0a1882b1b78ee4e86d7da96') {
    throw new Error(`aes mismatch: ${sealedHex}`);
  }

  const nonce = utils.buffer.bufToString(utils.crypto.randomBytes(8), 'hex');
  if (!/^[0-9a-f]{16}$/.test(nonce)) throw new Error(`nonce ${nonce}`);

  const packed = await utils.zlib.deflate(plain);
  const unpacked = await utils.zlib.inflate(packed);
  if (utils.buffer.bufToString(unpacked, 'utf-8') !== '{"hello":"世界"}') throw new Error('zlib roundtrip failed');

  const base64 = utils.buffer.bufToString(plain, 'base64');
  if (utils.buffer.from(base64, 'base64').length !== plain.length) throw new Error('base64 roundtrip failed');

  return await add(1, nonce);
}

on(EVENT_NAMES.request, ({ source, action, info } = {}) => {
  if (action !== 'musicUrl') return Promise.reject('unsupported action');
  if (!SUPPORT[source]) return Promise.reject(`unsupported source ${source}`);
  if (!SUPPORT[source].includes(info.type)) return Promise.reject(`unsupported quality ${info.type}`);

  return selfTest()
    .then(nonce => {
      const rid = String(info.musicInfo.hash || info.musicInfo.songmid || '');
      const sign = utils.crypto.md5(`${rid}|${info.type}|${nonce}|${SECRET}`);
      return new Promise((resolve, reject) => {
        request(ENDPOINT, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'User-Agent': 'lxspike/1.0' },
          body: { source, rid, quality: info.type, nonce, sign },
          timeout: 8000,
        }, (err, resp) => {
          if (err) return reject(err);
          if (resp.statusCode !== 200) return reject(new Error(`resolve failed: HTTP ${resp.statusCode}`));
          const url = resp.body && resp.body.data && resp.body.data.url;
          if (!url) return reject(new Error('missing url in response'));
          resolve(url);
        });
      });
    });
});

send(EVENT_NAMES.inited, { openDevTools: false, sources });
