/** Group items into a Map keyed by the result of keyFn.
 *  Items whose key is empty string, null, or undefined are skipped. */
export function groupByKey<T>(
  items: T[],
  keyFn: (item: T) => string | null | undefined,
): Map<string, T[]> {
  const map = new Map<string, T[]>()
  for (const item of items) {
    const key = keyFn(item)
    if (!key) continue
    const arr = map.get(key)
    if (arr) arr.push(item)
    else map.set(key, [item])
  }
  return map
}
