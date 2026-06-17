import { describe, expect, it } from 'vitest'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'

const STYLES_DIR = resolve(__dirname)

function kitDir(name: string): string {
  return resolve(STYLES_DIR, name)
}

describe('keeper-v2 DS UI kit asset delivery', () => {
  it('delivers dashboard kit files and index.css', () => {
    const dir = kitDir('ds-dashboard-kit')
    expect(existsSync(dir)).toBe(true)
    const files = readdirSync(dir)
    expect(files).toContain('index.css')
    expect(files).toContain('base.css')
    expect(files).toContain('shell.css')
    expect(files).toContain('primitives.css')
    expect(files.length).toBeGreaterThan(10)
  })

  it('delivers cockpit kit files and index.css', () => {
    const dir = kitDir('ds-cockpit-kit')
    expect(existsSync(dir)).toBe(true)
    const files = readdirSync(dir)
    expect(files).toContain('index.css')
    expect(files).toContain('tokens.css')
    expect(files).toContain('layout.css')
    expect(files).toContain('swimlanes.css')
    expect(files.length).toBeGreaterThan(5)
  })

  it('delivers viewer kit files and index.css', () => {
    const dir = kitDir('ds-viewer-kit')
    expect(existsSync(dir)).toBe(true)
    const files = readdirSync(dir)
    expect(files).toContain('index.css')
    expect(files).toContain('tokens.css')
    expect(files).toContain('shell.css')
    expect(files).toContain('theme-paper.css')
    expect(files.length).toBeGreaterThan(5)
  })

  it('imports all three kit indices from ds-ui-kits.css', () => {
    const css = readFileSync(resolve(STYLES_DIR, 'ds-ui-kits.css'), 'utf-8')
    expect(css).toContain('@import url("./ds-dashboard-kit/index.css")')
    expect(css).toContain('@import url("./ds-cockpit-kit/index.css")')
    expect(css).toContain('@import url("./ds-viewer-kit/index.css")')
  })
})
