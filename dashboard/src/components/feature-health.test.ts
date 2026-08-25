import { html } from 'htm/preact'
import { render } from 'preact'
import { Effect } from 'effect'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { FeatureHealthData } from '../api/feature-health'
import type * as FeatureHealthApi from '../api/feature-health'

const mocks = vi.hoisted(() => ({
  fetchFeatureHealth: vi.fn(),
}))

vi.mock('../api/feature-health', async importOriginal => {
  const original = await importOriginal<typeof FeatureHealthApi>()
  return {
    ...original,
    fetchFeatureHealth: mocks.fetchFeatureHealth,
  }
})

import {
  FeatureHealth,
  featureStatusLabel,
  refreshFeatureHealth,
  resetFeatureHealthState,
} from './feature-health'

const feature: FeatureHealthData['all_features'][number] = {
  env_name: 'MASC_GRPC_ENABLED',
  description: 'gRPC transport server',
  category: 'transport',
  lifecycle: 'active',
  is_enabled: true,
  source: 'env',
  status: 'healthy',
}

const data: FeatureHealthData = {
  generated_at: 1_786_500_000.25,
  overview: {
    total_features: 1,
    healthy_count: 1,
    warning_count: 0,
    inactive_count: 0,
    enabled_count: 1,
    overridden_count: 1,
  },
  features_by_category: {
    transport: { total: 1, enabled: 1, features: [feature] },
  },
  all_features: [feature],
}

async function flushUi(): Promise<void> {
  for (let index = 0; index < 4; index += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('featureStatusLabel', () => {
  it.each([
    ['healthy', '정상'],
    ['warning', '실험적'],
    ['inactive', '비활성'],
  ] as const)('featureStatusLabel(%s) → %s', (status, expected) => {
    expect(featureStatusLabel(status)).toBe(expected)
  })
})

describe('FeatureHealth', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    resetFeatureHealthState()
    mocks.fetchFeatureHealth.mockReset()
    mocks.fetchFeatureHealth.mockReturnValue(Effect.succeed(data))
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetFeatureHealthState()
    vi.clearAllMocks()
  })

  it('renders only decoded feature-health domain data', async () => {
    render(html`<${FeatureHealth} />`, container)
    await flushUi()

    expect(mocks.fetchFeatureHealth).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('1 / 1 기능 활성화')
    expect(container.textContent).toContain('MASC_GRPC_ENABLED')
    expect(container.textContent).toContain('source: env')
  })

  it('keeps the previous domain value visible while refreshing', async () => {
    render(html`<${FeatureHealth} />`, container)
    await flushUi()
    mocks.fetchFeatureHealth.mockReturnValue(Effect.never)

    void refreshFeatureHealth()
    await flushUi()

    expect(container.textContent).toContain('MASC_GRPC_ENABLED')
    expect(container.textContent).toContain('불러오는 중...')
  })
})
