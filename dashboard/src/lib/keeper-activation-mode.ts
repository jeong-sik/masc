export const KEEPER_ACTIVATION_MODES = ['manual', 'on_demand', 'autonomous'] as const
export type KeeperActivationMode = typeof KEEPER_ACTIVATION_MODES[number]

export function parseKeeperActivationMode(value: unknown): KeeperActivationMode | null {
  switch (value) {
    case 'manual': case 'on_demand': case 'autonomous': return value
    default: return null
  }
}

export function requireKeeperActivationMode(value: unknown): KeeperActivationMode {
  const mode = parseKeeperActivationMode(value)
  if (mode === null) throw new Error('Invalid keeper activation_mode')
  return mode
}

export const KEEPER_ACTIVATION_LABELS: Record<KeeperActivationMode, string> = {
  manual: '수동 시작',
  on_demand: '요청 시 실행',
  autonomous: '자율 실행',
}
