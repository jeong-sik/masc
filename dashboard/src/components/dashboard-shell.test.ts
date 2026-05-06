// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { h, render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { DashboardMain } from './dashboard-shell'
import { route } from '../router'
import { connected } from '../sse'
import { dashboardLoading } from '../store'
import { namespaceTruthInitializing } from '../namespace-truth-store'

describe('DashboardMain solo mode', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    dashboardLoading.value = false
    connected.value = true
    namespaceTruthInitializing.value = false
    document.title = 'MASC Dashboard'
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('keeps document title and active observability filters visible in solo mode', async () => {
    route.value = {
      tab: 'monitoring',
      params: {
        section: 'runtime',
        view: 'cost',
        solo: '1',
        keeper: 'keeper-alpha',
        range: '1h',
      },
      postId: null,
    }

    render(h(DashboardMain, {}), container)

    await waitFor(() => expect(document.title).toBe('MASC · Cascade'))
    expect(container.querySelector('[data-testid="dashboard-widget-solo-bar"]')).not.toBeNull()
    expect(container.querySelector('[aria-label="Active observability filters"]')).not.toBeNull()
  })
})
