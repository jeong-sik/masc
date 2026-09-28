import { afterEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { mountCollabViewer } from './collab-viewer'
import { encodeB64url } from '../collab-link'

function testLink(): string {
  const room = new Uint8Array(16).fill(7)
  const key = new Uint8Array(32).fill(9)
  return `${encodeB64url(room)}.${encodeB64url(key)}`
}

describe('mountCollabViewer', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('ignores dashboard routes and empty hashes', () => {
    const root = document.createElement('div')
    expect(mountCollabViewer(root, '#overview')).toBe(false)
    expect(mountCollabViewer(root, '#command?section=operations')).toBe(false)
    expect(mountCollabViewer(root, '')).toBe(false)
    expect(mountCollabViewer(root, '#not-a-link')).toBe(false)
    expect(root.innerHTML).toBe('')
  })

  it('mounts the standalone viewer for a share link', () => {
    const root = document.createElement('div')
    document.body.appendChild(root)
    try {
      expect(mountCollabViewer(root, `#${testLink()}`)).toBe(true)
      expect(root.querySelector('.collab-viewer')).not.toBeNull()
      expect(root.querySelector('.collab-badge-view')).not.toBeNull()
      expect(root.querySelector('.collab-readonly')?.textContent).toMatch(/View-only/)
      expect(root.querySelector('.collab-transcript')).not.toBeNull()
    } finally {
      render(null, root)
      root.remove()
    }
  })
})
