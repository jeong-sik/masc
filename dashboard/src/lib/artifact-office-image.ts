import { imageDimensionsFromData } from 'image-dimensions'

export type OfficeImageDimensions = { readonly type: 'png' | 'jpeg' | 'bmp'; readonly width: number; readonly height: number }
const bitmapFileHeaderBytes = 14, bitmapInfoHeaderBytes = 40, bitmapV4HeaderBytes = 108, bitmapV5HeaderBytes = 124, bitmapSignature = 0x4d42
const bitmapRgb = 0, rgbQuadBytes = 4, bitmapRowAlignmentBits = 32, bitmapRowAlignmentBytes = 4

/** Read supported image headers; image bytes are retained without re-encoding.
 * BMP fields and row stride follow Microsoft's BITMAPFILEHEADER/BITMAPINFOHEADER.
 * https://learn.microsoft.com/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader */
export function officeImageDimensions(bytes: Uint8Array): OfficeImageDimensions | null {
  const image = imageDimensionsFromData(bytes)
  if (image && (image.type === 'png' || image.type === 'jpeg')) return { type: image.type, width: image.width, height: image.height }
  if (bytes.byteLength < bitmapFileHeaderBytes + bitmapInfoHeaderBytes) return null
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (view.getUint16(0, true) !== bitmapSignature || view.getUint32(2, true) !== bytes.byteLength
    || view.getUint16(6, true) !== 0 || view.getUint16(8, true) !== 0) return null
  const header = view.getUint32(bitmapFileHeaderBytes, true), offset = view.getUint32(10, true)
  if (![bitmapInfoHeaderBytes, bitmapV4HeaderBytes, bitmapV5HeaderBytes].includes(header) || bitmapFileHeaderBytes + header > bytes.byteLength) return null
  const width = view.getInt32(18, true), height = Math.abs(view.getInt32(22, true)), bits = view.getUint16(28, true)
  if (width <= 0 || height <= 0 || view.getUint16(26, true) !== 1 || ![1, 4, 8, 16, 24, 32].includes(bits)
    || view.getUint32(30, true) !== bitmapRgb) return null
  const colours = view.getUint32(46, true), palette = colours || (bits <= 8 ? 2 ** bits : 0)
  if (bits <= 8 && palette > 2 ** bits) return null
  if (offset < bitmapFileHeaderBytes + header + palette * rgbQuadBytes || offset >= bytes.byteLength) return null
  const stride = Math.ceil(width * bits / bitmapRowAlignmentBits) * bitmapRowAlignmentBytes, pixelBytes = stride * height
  const declaredPixels = view.getUint32(34, true)
  if (!Number.isSafeInteger(pixelBytes) || pixelBytes > bytes.byteLength - offset
    || (declaredPixels !== 0 && (declaredPixels < pixelBytes || declaredPixels > bytes.byteLength - offset))) return null
  return { type: 'bmp', width, height }
}
