/** Extract model type and display name from generated agent nicknames.
 *
 * nickname.ml generates names as `{agent_type}-{adjective}-{animal}`.
 * Examples:
 *   "opus-leader-witty-heron" → { model: "opus", nickname: "leader-witty-heron" }
 *   "keeper-dm-keeper-agent"  → { model: "keeper", nickname: "dm-keeper-agent" }
 *   "claude"                  → { model: "claude", nickname: "claude" }
 */

export type AgentInfo = {
  model: string
  nickname: string
  isKeeper: boolean
}

export function extractAgentInfo(name: string): AgentInfo {
  const idx = name.indexOf('-')
  if (idx < 0) {
    return { model: name, nickname: name, isKeeper: name === 'keeper' }
  }
  const model = name.slice(0, idx)
  const nickname = name.slice(idx + 1)
  const isKeeper = model === 'keeper'
  return { model, nickname, isKeeper }
}

export function isKeeperAgent(name: string): boolean {
  return name.startsWith('keeper-')
}
