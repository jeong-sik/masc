import { html } from 'htm/preact'
import { options, render } from 'preact'
import { act } from 'preact/test-utils'
import { useState } from 'preact/hooks'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MasterDetail } from './master-detail'

/** What a test does to the screen without a click. */
interface ScreenHandle {
  /** Selects as a reload does. */
  select: (id: string | null) => void
  /** Makes the detail available, for a screen that loads it after the pick. */
  load: () => void
}

interface ScreenProps {
  readonly initial?: string | null
  /** The item a link to the screen names. */
  readonly linked?: string | null
  /** The detail is there only once it is loaded. */
  readonly loads?: boolean
  /** The screen does not say what is selected: its panes are two views. */
  readonly twoViews?: boolean
  readonly handle?: { current: ScreenHandle | null }
}

/**
 * A list of two rows under a filter, a view switch and a "new" button, as a
 * workspace builds one. Its detail has a control that selects another item, one
 * that does so and is drawn anew for each item, one that goes back to the list,
 * and one that drops the selection.
 */
function Screen(props: ScreenProps) {
  const [selected, setSelected] = useState<string | null>(props.initial !== undefined ? props.initial : props.linked ?? null)
  const [loaded, setLoaded] = useState(props.loads !== true)
  const [newShown, setNewShown] = useState(true)
  if (props.handle) props.handle.current = { select: setSelected, load: () => setLoaded(true) }
  const master = html`
    <button type="button" data-test="filter">Filter</button>
    <button type="button" data-test="other-view" onClick=${() => setSelected('other')}>Other view</button>
    <button type="button" data-test="clear" onClick=${() => setSelected(null)}>Clear</button>
    ${newShown && html`
      <button type="button" data-test="new" data-opens-detail onClick=${() => setSelected('new')}>New</button>
      <button
        type="button"
        data-test="new-once"
        data-opens-detail
        onClick=${() => { setSelected('new'); setNewShown(false) }}
      >New, once</button>
    `}
    <div role="list">
      ${['a', 'b'].map((id) => html`
        <div key=${id} role="listitem">
          <button type="button" data-test=${`row-${id}`} onClick=${() => setSelected(id)}>Row ${id}</button>
        </div>
      `)}
    </div>
  `
  return html`
    <${MasterDetail}
      master=${master}
      detail=${html`
        <p data-test="detail">Detail of ${selected}</p>
        <button type="button" data-test="related" onClick=${() => setSelected('a')}>Related: a</button>
        <button
          type="button"
          key=${`link-${selected}`}
          data-test="link"
          onClick=${() => setSelected(selected === 'a' ? 'b' : 'a')}
        >Link drawn for ${selected}</button>
        <button type="button" data-test="close" data-opens-master onClick=${() => setSelected('a')}>Close</button>
        <button type="button" data-test="discard" onClick=${() => setSelected(null)}>Discard</button>
      `}
      emptyDetail=${html`<p data-test="waiting">Loading ${selected}</p>`}
      hasSelection=${selected !== null && loaded}
      selectionKey=${props.twoViews === true ? undefined : selected}
      linkedKey=${props.linked}
      masterLabel="Rows"
      detailLabel="Row"
    />
  `
}

describe('MasterDetail pane switch', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  const mount = (props: ScreenProps = {}) => act(() => { render(html`<${Screen} ...${props} />`, container) })
  const button = (test: string) => container.querySelector<HTMLElement>(`[data-test="${test}"]`)!
  const click = (test: string) => act(() => { button(test).click() })
  const shownPane = () => container.querySelector('.md-split')!.getAttribute('data-pane')
  const switchButton = (label: string) =>
    [...container.querySelectorAll<HTMLButtonElement>('.md-switch-btn')].find((candidate) => candidate.textContent === label)!

  it('names the switch after its panes, and opens on the list with the detail out of reach while nothing is selected', async () => {
    await mount()

    expect([...container.querySelectorAll('.md-switch-btn')].map((candidate) => candidate.textContent)).toEqual(['Rows', 'Row'])
    expect(container.querySelector('.md-master')!.getAttribute('aria-label')).toBe('Rows')
    expect(container.querySelector('.md-detail')!.getAttribute('aria-label')).toBe('Row')
    expect(shownPane()).toBe('master')
    expect(switchButton('Rows').getAttribute('aria-pressed')).toBe('true')
    expect(switchButton('Row').disabled).toBe(true)
  })

  it('opens on the list when a row is selected on arrival', async () => {
    await mount({ initial: 'a' })

    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
  })

  it('opens on the detail for a link to one item', async () => {
    await mount({ linked: 'b' })

    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('shows the detail for a link followed while the screen is open', async () => {
    await mount({ initial: 'a' })
    expect(shownPane()).toBe('master')

    await mount({ initial: 'a', linked: 'a' })
    expect(shownPane()).toBe('detail')
  })

  it('keeps the list while the linked item is not selected yet, and shows its detail once it is', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ initial: null, linked: 'b', handle })
    expect(shownPane()).toBe('master')

    await act(() => { handle.current!.select('b') })
    expect(shownPane()).toBe('detail')
  })

  it('keeps the list for a link to an item when another one is what gets selected', async () => {
    await mount({ initial: 'a', linked: 'gone' })

    expect(shownPane()).toBe('master')
    expect(button('detail').textContent).toBe('Detail of a')

    // The detail of the other item is the reader's to ask for.
    await act(() => { switchButton('Row').click() })
    expect(shownPane()).toBe('detail')
  })

  it('waits with a link for the detail of its item', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ loads: true, linked: 'b', handle })
    expect(shownPane()).toBe('master')

    await act(() => { handle.current!.load() })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('leaves in the list what the screen selects in place of the linked item', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ linked: 'b', handle })
    expect(shownPane()).toBe('detail')

    await act(() => { handle.current!.select('a') })
    expect(shownPane()).toBe('master')
  })

  it('stays on the detail when a control of it selects another item, after a link', async () => {
    await mount({ linked: 'b' })
    await click('related')

    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')
  })

  it('leaves the detail to a reader who pressed a key in it, whatever the screen selects next', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ linked: 'b', handle })

    await act(() => { button('related').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true })) })
    await act(() => { handle.current!.select('a') })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')
  })

  // The list is not shown in between, as it was not shown before.
  it('keeps the detail shown while a link followed from it is on its way', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ linked: 'a', handle })
    expect(shownPane()).toBe('detail')

    // The address names b; the screen still has a selected.
    await mount({ linked: 'b', handle })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')

    await act(() => { handle.current!.select('b') })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('waits in the list for a link followed while the list is shown', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ initial: 'a', handle })
    await mount({ initial: 'a', linked: 'b', handle })
    expect(shownPane()).toBe('master')

    await act(() => { handle.current!.select('b') })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  // As for a link the screen opened on: what the screen selects in place of
  // the item is not opened, whatever the link before it had shown.
  it('leaves in the list what the screen selects in place of an item linked while it was open', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ linked: 'a', handle })
    await mount({ linked: 'gone', handle })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')

    await act(() => { handle.current!.select('other') })
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
  })

  // The detail a row pick asked for was asked of that row, not of the link.
  it('does not carry the detail a row pick asked for over to a link followed after it', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ handle })
    await click('row-a')
    await mount({ linked: 'gone', handle })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')

    await act(() => { handle.current!.select('other') })
    expect(shownPane()).toBe('master')
  })

  // The detail is kept for the item for as long as the screen has it selected.
  // Selected again later, as a reload selects, it is an item nobody picked.
  it('does not keep the detail for an item the screen let go of and selects again', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ handle })
    await click('row-a')
    await mount({ linked: 'gone', handle })
    expect(shownPane()).toBe('detail')

    await act(() => { handle.current!.select(null) })
    expect(shownPane()).toBe('master')
    await act(() => { handle.current!.select('a') })
    expect(shownPane()).toBe('master')

    await click('row-a')
    await mount({ linked: 'gone-too', handle })
    await act(() => { handle.current!.select('other') })
    await act(() => { handle.current!.select('a') })
    expect(shownPane()).toBe('master')
  })

  // Both in one render: the address names another item, and the screen lets
  // go of the one whose detail was kept.
  it('does not keep the detail for what the screen selects as another link is followed', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ linked: 'a', handle })
    await mount({ linked: 'gone', handle })
    expect(shownPane()).toBe('detail')

    await act(() => {
      handle.current!.select('other')
      render(html`<${Screen} linked="gone-too" handle=${handle} />`, container)
    })
    expect(button('detail').textContent).toBe('Detail of other')
    expect(shownPane()).toBe('master')
  })

  it('stops waiting for a linked item when the address stops naming it', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ loads: true, linked: 'b', handle })
    expect(shownPane()).toBe('master')

    await mount({ loads: true, handle })
    await act(() => { handle.current!.load() })
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
  })

  it('leaves the list to a reader who clicked in it while a link was waiting', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ loads: true, linked: 'b', handle })
    expect(shownPane()).toBe('master')

    await click('filter')
    await act(() => { handle.current!.load() })
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
  })

  it('leaves the list to a reader who pressed a key in it while a link was waiting', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ loads: true, linked: 'b', handle })

    await act(() => { button('filter').dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true })) })
    await act(() => { handle.current!.load() })
    expect(shownPane()).toBe('master')
  })

  // A wide container shows the list beside the detail of a linked item. Using
  // the list ends the wait and takes no pane from the reader: made narrow, the
  // container shows the detail they were reading.
  it('keeps the detail of a linked item for a reader who clicks in the list beside it', async () => {
    await mount({ linked: 'b' })
    expect(shownPane()).toBe('detail')

    await click('filter')
    expect(shownPane()).toBe('detail')
    expect(switchButton('Row').getAttribute('aria-pressed')).toBe('true')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('keeps the detail of a linked item for a reader who presses a key in the list beside it', async () => {
    await mount({ linked: 'b' })

    await act(() => { button('row-a').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true })) })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('keeps the detail kept for a link on its way for a reader who clicks in the list beside it', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ handle })
    await click('row-a')
    await mount({ linked: 'gone', handle })

    await click('filter')
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')
  })

  it('keeps the pane when the address stops naming an item', async () => {
    await mount({ linked: 'b' })
    expect(shownPane()).toBe('detail')

    await mount({})
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('goes back to the list from a linked item by the switch, and to the item again by its row', async () => {
    await mount({ linked: 'b' })
    await act(() => { switchButton('Rows').click() })
    expect(shownPane()).toBe('master')

    await click('row-b')
    expect(shownPane()).toBe('detail')
  })

  it('shows the detail when a row is picked', async () => {
    await mount()
    await click('row-b')

    expect(shownPane()).toBe('detail')
    expect(switchButton('Row').getAttribute('aria-pressed')).toBe('true')
    expect(button('detail').textContent).toBe('Detail of b')
  })

  it('shows the detail when the row picked is the selected one', async () => {
    await mount({ initial: 'a' })
    await click('row-a')

    expect(shownPane()).toBe('detail')
  })

  it('stays on the list for a click that picks nothing', async () => {
    await mount({ initial: 'a' })
    await click('filter')

    expect(shownPane()).toBe('master')
  })

  it('stays on the list for a click that changes the selection without picking a row', async () => {
    await mount({ initial: 'a' })
    await click('other-view')

    expect(shownPane()).toBe('master')
    expect(button('detail').textContent).toBe('Detail of other')
  })

  it('shows the detail for a control that says it opens it, the second time as the first', async () => {
    await mount({ initial: 'a' })
    await click('new')
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of new')

    await act(() => { switchButton('Rows').click() })
    expect(shownPane()).toBe('master')

    // What it selects is selected already: the click still opens the detail.
    await click('new')
    expect(shownPane()).toBe('detail')
  })

  it('shows the list for a control of the detail that says so, with the selection it leaves', async () => {
    await mount()
    await click('row-b')
    expect(shownPane()).toBe('detail')

    await click('close')
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
    expect(button('detail').textContent).toBe('Detail of a')
  })

  it('leaves the clicks of both panes alone on a screen that does not say what is selected', async () => {
    await mount({ twoViews: true })
    await click('row-a')

    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)

    await act(() => { switchButton('Row').click() })
    expect(shownPane()).toBe('detail')

    await click('close')
    expect(shownPane()).toBe('detail')
  })

  it('scrolls the detail back to its top for another item', async () => {
    await mount({ initial: 'a' })
    const detail = container.querySelector<HTMLElement>('.md-detail')!
    detail.scrollTop = 40

    await click('row-b')
    expect(detail.scrollTop).toBe(0)
  })

  it('shows the pane picked while its detail is not there yet', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ loads: true, handle })
    await click('row-a')

    expect(shownPane()).toBe('detail')
    expect(button('waiting').textContent).toBe('Loading a')

    await act(() => { handle.current!.load() })
    expect(shownPane()).toBe('detail')
    expect(button('detail').textContent).toBe('Detail of a')
  })

  it('goes back to the list and to the detail by the switch', async () => {
    await mount()
    await click('row-a')

    await act(() => { switchButton('Rows').click() })
    expect(shownPane()).toBe('master')
    expect(switchButton('Rows').getAttribute('aria-pressed')).toBe('true')

    await act(() => { switchButton('Row').click() })
    expect(shownPane()).toBe('detail')
  })

  it('returns to the list when the selection is gone, and stays there for a selection made without a pick', async () => {
    const handle: ScreenProps['handle'] = { current: null }
    await mount({ handle })
    await click('row-a')
    expect(shownPane()).toBe('detail')

    await click('clear')
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(true)

    await act(() => { handle.current!.select('b') })
    expect(shownPane()).toBe('master')
    expect(switchButton('Row').disabled).toBe(false)
  })

  it('does not take a row around the screen for a row of its list', async () => {
    await act(() => { render(html`<div role="listitem"><${Screen} initial="a" /></div>`, container) })
    await click('filter')

    expect(shownPane()).toBe('master')
  })

  it('leaves the focus where it is when both panes are shown', async () => {
    await mount()
    const row = button('row-a')

    row.focus()
    await click('row-a')
    expect(document.activeElement).toBe(row)
  })

  it('keeps the focus in the detail when the control that had it went away with its item', async () => {
    await mount({ initial: 'a' })
    const link = button('link')

    link.focus()
    await click('link')

    expect(link.isConnected).toBe(false)
    expect(container.querySelector('[data-test="detail"]')!.textContent).toBe('Detail of b')
    expect(document.activeElement).toBe(container.querySelector('.md-detail'))
  })

  it('keeps the focus in the list when the control that had it went away from it', async () => {
    await mount()
    const once = button('new-once')

    once.focus()
    await click('new-once')

    expect(once.isConnected).toBe(false)
    expect(document.activeElement).toBe(container.querySelector('.md-master'))
  })

  it('leaves the focus the reader put elsewhere when a control goes away', async () => {
    const handle: { current: ScreenHandle | null } = { current: null }
    await mount({ initial: 'a', handle })
    const link = button('link')
    const filter = button('filter')

    link.focus()
    filter.focus()
    await Promise.resolve()
    await act(() => { handle.current!.select('b') })

    expect(link.isConnected).toBe(false)
    expect(document.activeElement).toBe(filter)
  })

  it('does not put the focus on a pane for a control the reader had left before it went away', async () => {
    const handle: { current: ScreenHandle | null } = { current: null }
    await mount({ initial: 'a', handle })
    const link = button('link')

    link.focus()
    link.blur()
    await Promise.resolve()
    await act(() => { handle.current!.select('b') })

    expect(link.isConnected).toBe(false)
    expect(document.activeElement).toBe(document.body)
  })

  // A browser runs a pending render between the handlers of one click: after
  // the handler of the row, before the handler of the pane. `element.click()`
  // from a script does not, so the render is made immediate here.
  describe('with a render between the handlers of a click', () => {
    let debounceRendering: typeof options.debounceRendering

    beforeEach(() => {
      debounceRendering = options.debounceRendering
      options.debounceRendering = (renderNow) => renderNow()
    })

    afterEach(() => {
      options.debounceRendering = debounceRendering
    })

    // Before any effect has run: the first thing drawn is the linked item.
    it('opens on the detail for a link in its first render', () => {
      render(html`<${Screen} linked="b" />`, container)

      expect(shownPane()).toBe('detail')
    })

    it('shows the detail when a row is picked', () => {
      render(html`<${Screen} initial="a" />`, container)
      button('row-b').click()

      expect(shownPane()).toBe('detail')
      expect(button('detail').textContent).toBe('Detail of b')
    })

    it('shows the detail for a control that its own click takes off the screen', () => {
      render(html`<${Screen} initial="a" />`, container)
      const once = button('new-once')
      once.click()

      expect(once.isConnected).toBe(false)
      expect(shownPane()).toBe('detail')
    })

    it('stays on the list for a click that picks nothing', () => {
      render(html`<${Screen} initial="a" />`, container)
      button('filter').click()

      expect(shownPane()).toBe('master')
    })

    // Before any effect has run: an empty detail is not drawn for a frame.
    it('returns to the list in the render that loses the selection', () => {
      render(html`<${Screen} />`, container)
      button('row-a').click()
      expect(shownPane()).toBe('detail')

      button('clear').click()
      expect(shownPane()).toBe('master')
    })

    /** The stylesheet of a narrow container: the pane not shown is hidden. */
    const hideThePaneNotShown = () => {
      vi.spyOn(window, 'getComputedStyle').mockImplementation((element) => ({
        visibility: (element as Element).classList.contains(`md-${shownPane()}`) ? 'visible' : 'hidden',
      }) as CSSStyleDeclaration)
    }

    /** An event is over before the browser or the screen does anything else. */
    const endOfEvent = () => Promise.resolve()

    // The focus is moved as the pane is hidden, not a frame later: by then a
    // browser has taken it off the hidden element and left it on the page.
    it('moves the focus out of a pane the stylesheet hides, in the render that hides it', () => {
      render(html`<${Screen} />`, container)
      const row = button('row-a')
      hideThePaneNotShown()

      row.focus()
      row.click()

      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(container.querySelector('.md-detail'))
    })

    // A focus that scrolls takes the page to the pane, away from where the
    // reader had it.
    it('moves the focus without scrolling the page', () => {
      render(html`<${Screen} />`, container)
      const row = button('row-a')
      hideThePaneNotShown()
      const focus = vi.spyOn(container.querySelector<HTMLElement>('.md-detail')!, 'focus')

      row.focus()
      row.click()

      expect(focus).toHaveBeenCalledTimes(1)
      expect(focus).toHaveBeenCalledWith({ preventScroll: true })
    })

    it('moves the focus to the pane shown when the control that had it went away with the other', () => {
      render(html`<${Screen} initial="a" />`, container)
      button('row-a').click()
      expect(shownPane()).toBe('detail')
      hideThePaneNotShown()

      const discard = button('discard')
      discard.focus()
      discard.click()

      expect(shownPane()).toBe('master')
      expect(discard.isConnected).toBe(false)
      expect(document.activeElement).toBe(container.querySelector('.md-master'))
    })

    it('does not take the focus when it is drawn', () => {
      hideThePaneNotShown()
      render(html`<${Screen} linked="b" />`, container)

      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(document.body)
    })

    // The reader did not have the focus in the list: there is none to follow.
    it('does not take the focus for a linked item that gets there later', () => {
      const handle: ScreenProps['handle'] = { current: null }
      hideThePaneNotShown()
      render(html`<${Screen} loads linked="b" handle=${handle} />`, container)
      expect(shownPane()).toBe('master')

      handle.current!.load()
      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(document.body)
    })

    // A wide container shows both panes, and a row keeps the focus when it is
    // picked. Made narrow, the container hides the list with no render.
    it('moves the focus out of a pane that a container made narrow hides', async () => {
      const resized: Array<() => void> = []
      vi.stubGlobal('ResizeObserver', class {
        private readonly heard: () => void
        constructor(heard: () => void) { this.heard = heard }
        observe() { resized.push(this.heard) }
        disconnect() { resized.splice(resized.indexOf(this.heard), 1) }
      })
      await act(() => { render(html`<${Screen} />`, container) })
      const row = button('row-a')
      row.focus()
      await act(() => { row.click() })
      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(row)

      hideThePaneNotShown()
      expect(resized).toHaveLength(1)
      resized[0]!()
      expect(document.activeElement).toBe(container.querySelector('.md-detail'))
    })

    // The same, in the other order a browser may take: it finds the row hidden
    // and takes the focus off it before the new size is heard.
    it('follows a focus the browser took off a hidden row before the narrow container was heard', async () => {
      const resized: Array<() => void> = []
      vi.stubGlobal('ResizeObserver', class {
        private readonly heard: () => void
        constructor(heard: () => void) { this.heard = heard }
        observe() { resized.push(this.heard) }
        disconnect() { resized.splice(resized.indexOf(this.heard), 1) }
      })
      await act(() => { render(html`<${Screen} />`, container) })
      const row = button('row-a')
      row.focus()
      await act(() => { row.click() })

      hideThePaneNotShown()
      row.blur()
      expect(document.activeElement).toBe(document.body)
      await endOfEvent()
      resized[0]!()
      expect(document.activeElement).toBe(container.querySelector('.md-detail'))
    })

    // A browser may take the focus off a control as it removes it, while its
    // pane is still shown: the control is gone when that event is over, so it
    // was not the reader who took the focus off it.
    it('follows a control that went away with its pane after the focus was taken off it', async () => {
      hideThePaneNotShown()
      await act(() => { render(html`<${Screen} />`, container) })
      const once = button('new-once')
      once.focus()
      once.blur()
      await act(() => { once.click() })
      expect(shownPane()).toBe('detail')
      expect(once.isConnected).toBe(false)
      expect(document.activeElement).toBe(container.querySelector('.md-detail'))
    })

    // The reader took the focus off the list themselves: there is none to
    // follow. The first render is let finish, so that the focus is noted.
    it('leaves alone a focus the reader took off a control that is still there', async () => {
      const handle: ScreenProps['handle'] = { current: null }
      hideThePaneNotShown()
      await act(() => { render(html`<${Screen} loads linked="b" handle=${handle} />`, container) })
      const filter = button('filter')
      filter.focus()
      filter.blur()
      expect(document.activeElement).toBe(document.body)
      await endOfEvent()

      await act(() => { handle.current!.load() })
      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(document.body)
    })

    // The same when that control goes away with its pane later: the reader had
    // put the focus on nothing, and there it stays.
    it('leaves alone a focus the reader took off a control that went away later', async () => {
      const handle: ScreenProps['handle'] = { current: null }
      await act(() => { render(html`<${Screen} initial="a" handle=${handle} />`, container) })
      await act(() => { button('row-a').click() })
      expect(shownPane()).toBe('detail')
      hideThePaneNotShown()

      const discard = button('discard')
      discard.focus()
      discard.blur()
      await endOfEvent()

      await act(() => { handle.current!.select(null) })
      expect(shownPane()).toBe('master')
      expect(discard.isConnected).toBe(false)
      expect(document.activeElement).toBe(document.body)
    })

    // The focus went from one control of the detail to another: the one it is
    // on is the one noted, not the one it was taken off.
    it('follows the control the focus went to from another one of its pane', async () => {
      await act(() => { render(html`<${Screen} initial="a" />`, container) })
      await act(() => { button('row-a').click() })
      hideThePaneNotShown()

      button('related').focus()
      const discard = button('discard')
      discard.focus()
      await endOfEvent()

      await act(() => { discard.click() })
      expect(shownPane()).toBe('master')
      expect(document.activeElement).toBe(container.querySelector('.md-master'))
    })

    // A control removed before its pane is hidden had the focus until it went
    // away, whether or not the browser raised an event for it.
    it('follows a control that was removed, with an event for it, before its pane was hidden', async () => {
      const handle: ScreenProps['handle'] = { current: null }
      await act(() => { render(html`<${Screen} initial="a" handle=${handle} />`, container) })
      await act(() => { button('row-a').click() })
      hideThePaneNotShown()

      const discard = button('discard')
      discard.focus()
      discard.blur()
      discard.remove()
      await endOfEvent()

      await act(() => { handle.current!.select(null) })
      expect(shownPane()).toBe('master')
      expect(document.activeElement).toBe(container.querySelector('.md-master'))
    })

    it('leaves the focus on a control outside the panes', () => {
      const handle: ScreenProps['handle'] = { current: null }
      hideThePaneNotShown()
      render(html`<${Screen} loads linked="b" handle=${handle} />`, container)
      const outside = switchButton('Rows')
      outside.focus()

      handle.current!.load()
      expect(shownPane()).toBe('detail')
      expect(document.activeElement).toBe(outside)
    })

    // The focus went from the detail to a control elsewhere, and that control
    // went away: the pane hidden later is not where the focus was.
    it('leaves the focus nowhere when it was last outside the panes', () => {
      const handle: ScreenProps['handle'] = { current: null }
      render(html`<${Screen} initial="a" handle=${handle} />`, container)
      button('row-a').click()
      expect(shownPane()).toBe('detail')
      hideThePaneNotShown()

      button('discard').focus()
      const outside = document.createElement('button')
      document.body.appendChild(outside)
      outside.focus()
      outside.remove()

      handle.current!.select(null)
      expect(shownPane()).toBe('master')
      expect(document.activeElement).toBe(document.body)
    })

    // The detail hears the click before the control does: the list is not
    // shown in between, which would take the focus off the control.
    it('keeps the focus on a control of the detail that selects another item, after a link', () => {
      render(html`<${Screen} linked="b" />`, container)
      hideThePaneNotShown()

      const related = button('related')
      related.focus()
      related.click()

      expect(shownPane()).toBe('detail')
      expect(button('detail').textContent).toBe('Detail of a')
      expect(document.activeElement).toBe(related)
    })
  })
})
