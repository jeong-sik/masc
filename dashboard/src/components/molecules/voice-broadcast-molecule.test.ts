// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { MoleculeVoice } from './voice-molecule'
import { MoleculeBroadcast } from './broadcast-molecule'

describe('MoleculeVoice', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  it('renders wave bars, duration, via/size meta, and transcript from the block', () => {
    render(html`
      <${MoleculeVoice}
        secs=${75}
        wave=${[0.2, 0.8, 0.5]}
        via="discord"
        size="120 KB"
        transcript="배포 끝났어요"
      />
    `, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('voice')).toBe(true)
    expect(el.querySelectorAll('.voice-wave .vbar')).toHaveLength(3)
    expect(el.querySelector('.voice-dur')!.textContent).toBe('1:15')
    expect(el.querySelector('.voice-meta .voice-via')!.textContent).toContain('discord')
    expect(el.querySelector('.voice-tx .voice-tx-k')!.textContent).toBe('받아쓰기')
    expect(el.querySelector('.voice-tx .voice-tx-v')!.textContent).toBe('배포 끝났어요')
  })

  it('shows the play button only with a real audio payload', () => {
    render(html`<${MoleculeVoice} secs=${3} wave=${[0.5]} />`, host)
    expect(host.querySelector('.voice-play')).toBeNull()
    render(null, host)
    render(html`<${MoleculeVoice} secs=${3} wave=${[0.5]} src="data:audio/mpeg;base64,SUQz" />`, host)
    expect(host.querySelector('.voice-play')!.getAttribute('aria-label')).toBe('재생')
  })

  it('rejects unsafe audio src', () => {
    render(html`<${MoleculeVoice} secs=${3} src="javascript:alert(1)" />`, host)
    expect(host.querySelector('.voice-play')).toBeNull()
  })
})

describe('MoleculeBroadcast', () => {
  let host: HTMLDivElement
  beforeEach(() => { host = document.createElement('div'); document.body.appendChild(host) })
  afterEach(() => { render(null, host); host.remove() })

  const recipients = [
    { id: 'iron-claw', ack: 'acked', at: '14:02' },
    { id: 'miso', ack: 'read' },
    { id: 'hippo', ack: 'delivered' },
  ]

  it('renders the design broadcast chrome with real ack counts', () => {
    render(html`
      <${MoleculeBroadcast}
        scope="fleet"
        via="keeper-net"
        note="릴리즈 컷 동결"
        recipients=${recipients}
      />
    `, host)
    const el = host.firstElementChild as HTMLElement
    expect(el.classList.contains('bcast')).toBe(true)
    expect(el.querySelector('.bcast-hd .bcast-tag')!.textContent).toBe('Broadcast')
    expect(el.querySelector('.bcast-scope')!.textContent).toBe('fleet')
    expect(el.querySelector('.bcast-via')!.textContent).toBe('keeper-net')
    expect(el.querySelector('.bcast-count')!.textContent).toBe('1/3 확인')
    expect(el.querySelector('.bcast-note')!.textContent).toBe('릴리즈 컷 동결')
    const rows = el.querySelectorAll('.bcast-rcpts .bcast-rcpt')
    expect(rows).toHaveLength(3)
    expect(rows[0]!.classList.contains('acked')).toBe(true)
    expect(rows[0]!.querySelector('.bcast-rcpt-id')!.textContent).toBe('iron-claw')
    expect(rows[0]!.querySelector('.bcast-ack')!.textContent).toBe('확인함 · 14:02')
    expect(rows[1]!.querySelector('.bcast-ack')!.textContent).toBe('읽음')
  })

  it('renders the audience chip only when the host supplies it', () => {
    render(html`<${MoleculeBroadcast} scope="fleet" note="n" recipients=${[]} />`, host)
    expect(host.querySelector('.bcast-aud')).toBeNull()
    expect(host.querySelector('.bcast-aud-note')).toBeNull()
    render(null, host)
    render(html`<${MoleculeBroadcast} scope="fleet" note="n" recipients=${[]} audience="record" />`, host)
    expect(host.querySelector('.bcast-aud.record')!.textContent).toBe('기록')
    expect(host.querySelector('.bcast-aud-note')!.textContent).toContain('기록으로만 남음')
  })

  it('omits the count pill when there are no recipients', () => {
    render(html`<${MoleculeBroadcast} scope="fleet" note="n" recipients=${[]} />`, host)
    expect(host.querySelector('.bcast-count')).toBeNull()
    expect(host.querySelector('.bcast-rcpts')).toBeNull()
  })
})
