import JZZ from 'jzz'

// UMP 1.1.2 table 2: reserved types still have a defined packet width.
export const umpMessageWordCounts = Object.freeze([1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4])

export function* umpMessages(bytes, offset = 0) {
  while (offset < bytes.length) {
    const end = offset + 4 * umpMessageWordCounts[bytes[offset] >>> 4]
    if (end > bytes.length) throw new Error('Truncated UMP message')
    const words = []
    for (let at = offset; at < end; at += 4) words.push(bytes.readUInt32BE(at))
    yield { offset, words, message: JZZ.UMP([...bytes.subarray(offset, end)]) }
    offset = end
  }
}
