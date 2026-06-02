// MASC Dashboard — Deterministic agent name -> avatar palette mapping
// Uses a simple string hash to pick colors and template from agent name.

type AvatarTemplate = 'humanoid' | 'robot' | 'animal' | 'abstract'

export interface AvatarPalette {
  skin: string
  hair: string
  point: string
  highlight: string
}

// Warm, distinguishable palette sets (4 colors each)
const PALETTE_POOL: AvatarPalette[] = [
  { skin: '#f5c89a', hair: '#7a4e3a', point: '#e8917a', highlight: '#f5c542' },
  { skin: '#b8e0d2', hair: '#3d6b5e', point: '#8dbd97', highlight: '#e0f0e3' },
  { skin: '#c5b8e8', hair: '#5a4785', point: '#b8a4d6', highlight: '#e3d9f2' },
  { skin: '#f0d6a8', hair: '#8a6530', point: '#e8c070', highlight: '#fff3d6' },
  { skin: '#a8d4f0', hair: '#3a6585', point: '#7ab8e0', highlight: '#d6ecfa' },
  { skin: '#f0a8c0', hair: '#854060', point: '#e07a98', highlight: '#fad6e6' },
  { skin: '#d4f0a8', hair: '#5a8530', point: '#b0d870', highlight: '#ecfad6' },
  { skin: '#f0c8a8', hair: '#85553a', point: '#e0a07a', highlight: '#fae4d6' },
  { skin: '#a8e8f0', hair: '#3a7885', point: '#7ad0e0', highlight: '#d6f4fa' },
  { skin: '#e8d0a8', hair: '#7a6030', point: '#d4b470', highlight: '#f5ead6' },
  { skin: '#c0e0b8', hair: '#4a7040', point: '#98c888', highlight: '#e0f0d8' },
  { skin: '#e0b8d4', hair: '#704060', point: '#c898b8', highlight: '#f0d8e8' },
]

const TEMPLATES: AvatarTemplate[] = ['humanoid', 'robot', 'animal', 'abstract']

function hashString(str: string): number {
  let hash = 5381
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) + hash + str.charCodeAt(i)) >>> 0
  }
  return hash
}

export function paletteForAgent(name: string): AvatarPalette {
  const hash = hashString(name.toLowerCase())
  return PALETTE_POOL[hash % PALETTE_POOL.length] as AvatarPalette
}

export function templateForAgent(name: string, traits?: string[]): AvatarTemplate {
  // Trait-based template selection
  if (traits && traits.length > 0) {
    const joined = traits.join(' ').toLowerCase()
    if (joined.includes('robot') || joined.includes('machine') || joined.includes('auto')) return 'robot'
    if (joined.includes('animal') || joined.includes('creature') || joined.includes('pet')) return 'animal'
    if (joined.includes('abstract') || joined.includes('concept') || joined.includes('system')) return 'abstract'
  }
  // Fallback: name-based deterministic selection
  const hash = hashString(name.toLowerCase() + '_template')
  return TEMPLATES[hash % TEMPLATES.length] as AvatarTemplate
}

// 8x8 pixel templates: 1 = skin, 2 = hair, 3 = point, 4 = highlight, 0 = transparent
// Each template is a flat 64-element array (8 rows x 8 cols)

type PixelGrid = readonly number[]

export const PIXEL_TEMPLATES: Record<AvatarTemplate, PixelGrid> = {
  humanoid: [
    0, 0, 2, 2, 2, 2, 0, 0,
    0, 2, 2, 2, 2, 2, 2, 0,
    0, 2, 1, 3, 3, 1, 2, 0,
    0, 0, 1, 1, 1, 1, 0, 0,
    0, 0, 1, 4, 4, 1, 0, 0,
    0, 3, 3, 1, 1, 3, 3, 0,
    0, 0, 1, 1, 1, 1, 0, 0,
    0, 0, 1, 0, 0, 1, 0, 0,
  ],
  robot: [
    0, 0, 3, 3, 3, 3, 0, 0,
    0, 3, 2, 2, 2, 2, 3, 0,
    0, 3, 4, 1, 1, 4, 3, 0,
    0, 3, 2, 2, 2, 2, 3, 0,
    0, 0, 3, 3, 3, 3, 0, 0,
    0, 1, 3, 2, 2, 3, 1, 0,
    0, 0, 3, 2, 2, 3, 0, 0,
    0, 3, 3, 0, 0, 3, 3, 0,
  ],
  animal: [
    2, 0, 0, 0, 0, 0, 0, 2,
    2, 2, 0, 0, 0, 0, 2, 2,
    0, 2, 1, 1, 1, 1, 2, 0,
    0, 1, 4, 1, 1, 4, 1, 0,
    0, 1, 1, 3, 3, 1, 1, 0,
    0, 0, 1, 1, 1, 1, 0, 0,
    0, 0, 0, 1, 1, 0, 0, 0,
    0, 0, 0, 3, 3, 0, 0, 0,
  ],
  abstract: [
    0, 0, 0, 3, 3, 0, 0, 0,
    0, 0, 3, 4, 4, 3, 0, 0,
    0, 3, 1, 1, 1, 1, 3, 0,
    3, 4, 1, 2, 2, 1, 4, 3,
    3, 4, 1, 2, 2, 1, 4, 3,
    0, 3, 1, 1, 1, 1, 3, 0,
    0, 0, 3, 4, 4, 3, 0, 0,
    0, 0, 0, 3, 3, 0, 0, 0,
  ],
}
