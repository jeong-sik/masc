// FPS adaptive quality — lightweight rAF-based monitor.
// Reports rolling FPS every ~1 s. Consumers (e.g. VirtualList) can
// subscribe and lower render quality when FPS is poor.

let rafId = 0
let lastTime = 0
let frameCount = 0
let currentFps = 60
const listeners = new Set<(fps: number) => void>()

function tick(now: number) {
  frameCount++
  if (now - lastTime >= 1000) {
    currentFps = Math.round((frameCount * 1000) / (now - lastTime))
    frameCount = 0
    lastTime = now
    for (const cb of listeners) cb(currentFps)
  }
  rafId = requestAnimationFrame(tick)
}

function start() {
  if (rafId) return
  lastTime = performance.now()
  frameCount = 0
  rafId = requestAnimationFrame(tick)
}

function stop() {
  if (rafId) {
    cancelAnimationFrame(rafId)
    rafId = 0
  }
}

export function getFps(): number {
  return currentFps
}

/** Subscribe to FPS updates. Returns an unsubscribe function. */
export function onFpsChange(cb: (fps: number) => void): () => void {
  listeners.add(cb)
  start()
  return () => {
    listeners.delete(cb)
    if (listeners.size === 0) stop()
  }
}
