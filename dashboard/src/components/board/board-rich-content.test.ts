import { h } from 'preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { act } from 'preact/test-utils'
import { afterEach, describe, expect, it } from 'vitest'
import { BoardRichContent } from './board-rich-content'
import { keepers } from '../../store'
import { normalizeKeepers } from '../../keeper-store-normalize'
import { readBoardAudience } from '../../lib/board-address'
import { reconcileKeepers } from '../../store'
import '@testing-library/jest-dom'

afterEach(() => { cleanup(); keepers.value = [] })
const setAddresses = (target_ids: string[]) => {
  keepers.value = reconcileKeepers(keepers.value, normalizeKeepers([
    { name: 'beta', status: 'offline', board_address: { state: 'ready', target_ids } },
  ]))
}

describe('Board authoritative recipient display', () => {
  it('highlights actual alias and immediately follows a new effective snapshot', async () => {
    setAddresses(['alpha'])
    const view = render(h(BoardRichContent, {
      text: 'please inspect @Alpha and `@beta`',
      audience: readBoardAudience({ kind: 'targets', targets: ['Alpha', 'Omega'] }),
    }))
    expect(view.container.querySelector('[data-board-address="matched"]')).toHaveTextContent('@Alpha · beta')
    await act(() => setAddresses(['omega']))
    await waitFor(() => expect(view.container.querySelector('[data-board-address="matched"]')).toHaveTextContent('@Omega · beta'))
    expect(view.container.querySelector('[data-board-address="unmatched"]')).toHaveTextContent('@Alpha · 일치하는 Keeper 없음')
    await waitFor(() => expect(view.container.querySelector('.markdown-content')).toHaveTextContent('@beta'))
  })
  it('never invents comment recipients from text or display names', () => {
    setAddresses(['alpha'])
    const view = render(h(BoardRichContent, { text: '@Alpha comment with no persisted audience' }))
    expect(screen.getByText('저장된 수신 대상 정보 없음')).toBeVisible()
    expect(view.container.querySelector('[data-board-address]')).toBeNull()
  })
  it('shows unavailable separately from a confirmed nonmatch', () => {
    keepers.value = normalizeKeepers([{ name: 'beta', status: 'offline', board_address: { state: 'unavailable', reason: 'effective_metadata_unread' } }])
    const view = render(h(BoardRichContent, { text: '@Alpha', audience: readBoardAudience({ kind: 'targets', targets: ['Alpha'] }) }))
    expect(view.container.querySelector('[data-board-address="unavailable"]')).toHaveTextContent('주소 확인 불가')
    expect(screen.getByRole('status')).toHaveTextContent('일부 Keeper의 현재 수신 주소를 확인할 수 없습니다')
    expect(screen.queryByText('일치하는 Keeper 없음')).toBeNull()
  })
  it('does not promote script, HTML attributes, email, or code prose into audience', async () => {
    setAddresses(['alpha'])
    const view = render(h(BoardRichContent, {
      text: '<img src="x" onerror="window.__boardXss=1" /> mail@alpha.example `@Alpha` <script>window.__boardXss=2</script>',
      audience: readBoardAudience({ kind: 'discoverable' }),
    }))
    await waitFor(() => expect(view.container.querySelector('.markdown-content')).not.toHaveClass('markdown-content--loading'))
    expect(view.container.querySelector('[data-board-address]')).toBeNull()
    expect(view.container.querySelector('script')).toBeNull()
    expect(view.container.querySelector('[onerror]')).toBeNull()
    expect(screen.getByText('발견 가능한 게시글')).toBeVisible()
  })
})
