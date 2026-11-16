// HWP5 table 6: character controls occupy one WCHAR; inline/extended controls occupy eight.
const slotBytes = 16, wcharBytes = 2, carriageReturn = 13
type ControlShape = 'character' | 'inline' | 'extended'
function controlShape(code: number): ControlShape {
  switch (code) {
    case 0: case 10: case 13: case 24: case 30: case 31: return 'character'
    case 1: case 4: case 5: case 6: case 7: case 8: case 9: case 19: case 20: return 'inline'
    case 2: case 3: case 11: case 12: case 14: case 15: case 16: case 17: case 18: case 21: case 22: case 23: return 'extended'
    default: throw new Error('지원하지 않는 원본 HWP 제어 문자입니다.')
  }
}

/** Return original extended-control IDs without decoding or rewriting the text. */
export function readHwpTextControls(data: Uint8Array): readonly number[] {
  if (data.byteLength % wcharBytes !== 0) throw new Error('HWP UTF-16 본문이 잘렸습니다.')
  const bytes = new DataView(data.buffer, data.byteOffset, data.byteLength), controls: number[] = []
  for (let offset = 0; offset < data.byteLength;) {
    const code = bytes.getUint16(offset, true)
    if (code >= 0xD800 && code <= 0xDBFF) {
      if (offset + wcharBytes * 2 > data.byteLength) throw new Error('HWP UTF-16 서로게이트의 짝이 없습니다.')
      const low = bytes.getUint16(offset + wcharBytes, true)
      if (low < 0xDC00 || low > 0xDFFF) throw new Error('HWP UTF-16 서로게이트의 짝이 없습니다.')
      offset += wcharBytes * 2; continue
    }
    if (code >= 0xDC00 && code <= 0xDFFF) throw new Error('HWP UTF-16 서로게이트의 짝이 없습니다.')
    if (code >= 0x20) { offset += wcharBytes; continue }
    const shape = controlShape(code)
    if (shape === 'character') {
      if (code === carriageReturn && offset + wcharBytes !== data.byteLength) throw new Error('HWP 문단 끝 뒤에 본문이 있습니다.')
      offset += wcharBytes; continue
    }
    if (offset + slotBytes > data.byteLength || bytes.getUint16(offset + slotBytes - wcharBytes, true) !== code) throw new Error('HWP 8-WCHAR 제어 문자 구조가 올바르지 않습니다.')
    if (shape === 'extended') controls.push(bytes.getUint32(offset + wcharBytes, true))
    offset += slotBytes
  }
  return controls
}
