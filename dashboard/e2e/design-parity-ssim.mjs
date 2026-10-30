// Deterministic SSIM over raw 8-bit grayscale planes. ImageMagick's own
// `compare -metric SSIM` reports the same number for SSIM and DSSIM in 7.1.2,
// so the metric is computed here instead of shelling out for it.
// Standard Wang et al. 2004: 11x11 gaussian window, sigma 1.5,
// C1=(0.01*L)^2, C2=(0.03*L)^2, L=255. Mean SSIM over every pixel.
import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const TMP = process.env.SSIM_TMP || '/tmp'

function gray(png, tag) {
  const out = `${TMP}/_ssim_${tag}.gray`
  const dims = execFileSync('magick', ['identify', '-format', '%w %h', png]).toString().trim().split(' ').map(Number)
  execFileSync('magick', [png, '-colorspace', 'Gray', '-depth', '8', out])
  const buf = readFileSync(out)
  return { w: dims[0], h: dims[1], d: buf }
}

function gaussKernel(sigma, radius) {
  const k = []
  let s = 0
  for (let i = -radius; i <= radius; i++) { const v = Math.exp(-(i * i) / (2 * sigma * sigma)); k.push(v); s += v }
  return k.map(v => v / s)
}

function blurSep(src, w, h, k) {
  const r = (k.length - 1) / 2
  const tmp = new Float64Array(w * h)
  const dst = new Float64Array(w * h)
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let a = 0
    for (let i = -r; i <= r; i++) { const xx = Math.min(w - 1, Math.max(0, x + i)); a += src[y * w + xx] * k[i + r] }
    tmp[y * w + x] = a
  }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let a = 0
    for (let i = -r; i <= r; i++) { const yy = Math.min(h - 1, Math.max(0, y + i)); a += tmp[yy * w + x] * k[i + r] }
    dst[y * w + x] = a
  }
  return dst
}

export function ssim(aPng, bPng) {
  const A = gray(aPng, 'a'), B = gray(bPng, 'b')
  if (A.w !== B.w || A.h !== B.h) throw new Error(`size mismatch ${A.w}x${A.h} vs ${B.w}x${B.h}`)
  const { w, h } = A
  const n = w * h
  const x = new Float64Array(n), y = new Float64Array(n)
  for (let i = 0; i < n; i++) { x[i] = A.d[i]; y[i] = B.d[i] }
  const k = gaussKernel(1.5, 5)
  const mx = blurSep(x, w, h, k), my = blurSep(y, w, h, k)
  const xx = new Float64Array(n), yy = new Float64Array(n), xy = new Float64Array(n)
  for (let i = 0; i < n; i++) { xx[i] = x[i] * x[i]; yy[i] = y[i] * y[i]; xy[i] = x[i] * y[i] }
  const sxx = blurSep(xx, w, h, k), syy = blurSep(yy, w, h, k), sxy = blurSep(xy, w, h, k)
  const C1 = (0.01 * 255) ** 2, C2 = (0.03 * 255) ** 2
  let sum = 0
  for (let i = 0; i < n; i++) {
    const m1 = mx[i], m2 = my[i]
    const v1 = sxx[i] - m1 * m1, v2 = syy[i] - m2 * m2, cv = sxy[i] - m1 * m2
    sum += ((2 * m1 * m2 + C1) * (2 * cv + C2)) / ((m1 * m1 + m2 * m2 + C1) * (v1 + v2 + C2))
  }
  return sum / n
}

import { pathToFileURL } from 'node:url'
if (import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] && process.argv[3]) {
  console.log(ssim(process.argv[2], process.argv[3]).toFixed(4))
}
