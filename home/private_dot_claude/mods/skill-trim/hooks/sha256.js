// Mods may import only their own files, so node:crypto is out of reach.
const K = new Uint32Array(64)
for (let i = 0, n = 2; i < 64; n++) {
  let prime = true
  for (let d = 2; d * d <= n; d++) if (n % d === 0) prime = false
  if (prime) K[i++] = (Math.cbrt(n) % 1) * 2 ** 32
}

export function sha256(text) {
  const bytes = new TextEncoder().encode(text)
  const padded = new Uint8Array(((bytes.length + 9 + 63) >> 6) << 6)
  padded.set(bytes)
  padded[bytes.length] = 0x80
  const view = new DataView(padded.buffer)
  view.setUint32(padded.length - 8, Math.floor((bytes.length * 8) / 2 ** 32))
  view.setUint32(padded.length - 4, (bytes.length * 8) >>> 0)

  const h = new Uint32Array(8)
  for (let i = 0, n = 2, found = 0; found < 8; n++) {
    let prime = true
    for (let d = 2; d * d <= n; d++) if (n % d === 0) prime = false
    if (prime) h[i++] = (Math.sqrt(n) % 1) * 2 ** 32, found++
  }

  const w = new Uint32Array(64)
  const rotr = (x, n) => (x >>> n) | (x << (32 - n))
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4)
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0
    }
    let [a, b, c, d, e, f, g, hh] = h
    for (let i = 0; i < 64; i++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0
      hh = g; g = f; f = e; e = (d + t1) | 0
      d = c; c = b; b = a; a = (t1 + t2) | 0
    }
    const v = [a, b, c, d, e, f, g, hh]
    for (let i = 0; i < 8; i++) h[i] = (h[i] + v[i]) | 0
  }
  return Array.from(h, (x) => (x >>> 0).toString(16).padStart(8, '0')).join('')
}
