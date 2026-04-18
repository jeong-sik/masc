// Fixed-capacity ring buffer for high-frequency signal buffers.
//
// Replaces the `signal.value = [entry, ...signal.value].slice(0, N)` pattern
// that allocates two intermediate arrays per push. The ring stores items in
// a single pre-allocated slot array; snapshot() materialises a newest-first
// readonly view in one pass, preserving the shape existing consumers expect.

export class RingBuffer<T> {
  private readonly slots: (T | undefined)[]
  private head = 0
  private count = 0

  constructor(readonly capacity: number) {
    if (!Number.isInteger(capacity) || capacity <= 0) {
      throw new Error(`RingBuffer capacity must be a positive integer, got ${capacity}`)
    }
    this.slots = new Array(capacity)
  }

  get size(): number {
    return this.count
  }

  push(item: T): void {
    this.head = (this.head - 1 + this.capacity) % this.capacity
    this.slots[this.head] = item
    if (this.count < this.capacity) this.count += 1
  }

  clear(): void {
    this.head = 0
    this.count = 0
    for (let i = 0; i < this.capacity; i += 1) this.slots[i] = undefined
  }

  peek(): T | undefined {
    return this.count === 0 ? undefined : (this.slots[this.head] as T)
  }

  toArray(): readonly T[] {
    const out: T[] = new Array(this.count)
    for (let i = 0; i < this.count; i += 1) {
      out[i] = this.slots[(this.head + i) % this.capacity] as T
    }
    return out
  }
}
