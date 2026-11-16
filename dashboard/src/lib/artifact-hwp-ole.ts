import JSZip from 'jszip'
import type { OfficeChart } from './artifact-office-chart'
import { readOfficeChart } from './artifact-office-chart-read'
import { officeImportLimits } from './artifact-office-xml'
import { readHwpCompound } from './artifact-hwp-container'

const compoundSignature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1] as const
const lengthBytes = 4
const chartStream = 'OOXMLChartContents'
const chartPart = 'Chart/chart.xml'

function compoundPayload(data: Uint8Array): Uint8Array {
  if (data.byteLength > officeImportLimits.partBytes) throw new Error('HWP 차트 개체가 문서 내부 파일 크기 한도를 넘습니다.')
  const signatureAt = (offset: number) => compoundSignature.every((byte, index) => data[offset + index] === byte)
  if (signatureAt(0)) return data
  // RHWP 0.9.0's HWPX serializer prefixes OLE CFB bytes with their UINT32 length.
  if (data.byteLength < lengthBytes + compoundSignature.length || !signatureAt(lengthBytes)
    || new DataView(data.buffer, data.byteOffset, lengthBytes).getUint32(0, true) !== data.byteLength - lengthBytes) {
    throw new Error('HWP 차트 개체의 CFB 서명 또는 길이 정보가 올바르지 않습니다.')
  }
  return data.subarray(lengthBytes)
}

/** HWP5 revision 1.3 §4.3.9.6 stores DrawingML at this root CFB stream. */
export async function readHwpOleChart(data: Uint8Array): Promise<OfficeChart> {
  const streams = readHwpCompound(compoundPayload(data), 'HWP 차트 개체')
  const candidates = streams.pathsWithName(chartStream)
  const xml = streams.lookup(chartStream)
  if (!xml || candidates.length !== 1) {
    throw new Error('최상위 OOXMLChartContents 하나가 있는 HWP 차트만 가져올 수 있습니다. 구형 차트와 다른 OLE 개체는 지원하지 않습니다.')
  }
  const zip = new JSZip()
  zip.file(chartPart, xml)
  return readOfficeChart(zip, chartPart)
}
