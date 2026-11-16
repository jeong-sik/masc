import { Either, Schema } from 'effect'
import { HwpDocument } from '@rhwp/core'
import { preflightArtifactHwp } from './artifact-hwp-container'
import { readHwpOleChart } from './artifact-hwp-ole'
import { importArtifactHwpx } from './artifact-hwpx-import'

const exportReport = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  outputFormat: Schema.Literal('hwpx'),
  count: Schema.Number.pipe(Schema.int(), Schema.nonNegative()),
  losses: Schema.Array(Schema.Unknown),
})

function exportedHwpx(data: Uint8Array): Uint8Array {
  // The original records are checked before the engine can reduce an unknown control.
  preflightArtifactHwp(data)
  const document = new HwpDocument(data)
  try {
    const result = document.exportHwpxWithReport()
    try {
      const raw: unknown = JSON.parse(result.contentLoss())
      const report = Schema.decodeUnknownEither(exportReport, { onExcessProperty: 'error' })(raw)
      if (Either.isLeft(report) || report.right.count !== report.right.losses.length) {
        throw new Error('HWP 변환 결과의 내용 보존 여부를 확인할 수 없습니다.')
      }
      if (report.right.count !== 0) throw new Error('HWP 변환 중 내용 손실이 감지되어 가져오기를 중단했습니다.')
      return result.takeBytes()
    } finally { result.free() }
  } finally { document.free() }
}

/** Called after the worker has initialized the pinned engine. No file is uploaded. */
export async function convertArtifactHwp(data: Uint8Array): Promise<{ content: string; notices: readonly string[] }> {
  const bytes = exportedHwpx(data)
  return importArtifactHwpx(bytes, { kind: 'hwp5', readOleChart: readHwpOleChart })
}
