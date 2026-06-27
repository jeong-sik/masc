import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

describe('keeper composite schema bundle boundary', () => {
  it('keeps valibot-backed keeper detail schemas out of the initial keeper API import', () => {
    const source = readFileSync(resolve(__dirname, 'keeper.ts'), 'utf8')

    expect(source).toContain("await import('./schemas/keeper-composite')")
    expect(source).toContain("await import('./schemas/keeper-chat-history')")
    expect(source).toContain("await import('./schemas/keeper-transitions')")
    expect(source).toContain("import type {\n  KeeperCompositeSnapshot")
    expect(source).not.toMatch(/import\s*{[\s\S]*parseKeeperCompositeSnapshot[\s\S]*}\s*from\s*['"]\.\/schemas\/keeper-composite['"]/)
    expect(source).not.toMatch(/import\s*{[\s\S]*safeParseKeeperChatHistoryMessage[\s\S]*}\s*from\s*['"]\.\/schemas\/keeper-chat-history['"]/)
    expect(source).not.toMatch(/import\s*{[\s\S]*parseKeeperTransitionsResponse[\s\S]*}\s*from\s*['"]\.\/schemas\/keeper-transitions['"]/)
    expect(source).not.toContain('KeeperCompositeSnapshotSchema')
    expect(source).not.toContain('FleetCompositeSnapshotSchema')
    expect(source).not.toContain('KeeperChatHistoryMessageSchema')
  })
})
