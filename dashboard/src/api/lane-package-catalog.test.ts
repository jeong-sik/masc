import { describe, expect, it } from 'vitest'
import { parseLanePackagePreview } from './lane-package-catalog'

const packageMetadata = { title: 'Browser', revision: '1', binding_schema: null }
const base = { manifest_path: '/workspace/browser/lane.toml', package: packageMetadata }

describe('package execution preview', () => {
  it('admits a host process without requiring an imaginary image', () => {
    const preview = parseLanePackagePreview({ ...base, execution: { kind: 'host_process' } })
    expect(preview.execution).toEqual({ kind: 'host_process' })
  })
  it('requires the real image name and inspection receipt for containers', () => {
    const execution = { kind: 'container', image_name: 'browser:1', image: { state: 'available', digest: 'sha256:fixture' } }
    expect(parseLanePackagePreview({ ...base, execution }).execution).toEqual(execution)
    expect(() => parseLanePackagePreview({ ...base, execution: { kind: 'container' } })).toThrow()
    expect(() => parseLanePackagePreview({ ...base, execution: { kind: 'unknown' } })).toThrow()
  })
})
