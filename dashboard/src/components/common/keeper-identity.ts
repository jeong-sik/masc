export function runtimeAgentName(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const keeper = keeperName?.trim()
  const agent = agentName?.trim()
  if (!agent) return null
  if (!keeper) return agent
  return agent === keeper ? null : agent
}

export function keeperRuntimeLabel(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const runtime = runtimeAgentName(keeperName, agentName)
  return runtime ? `runtime · ${runtime}` : null
}

export function keeperIdentityHint(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const keeper = keeperName?.trim()
  const runtime = runtimeAgentName(keeper, agentName)
  if (!keeper) return null
  if (!runtime) return `키퍼 · ${keeper}`
  return `키퍼 · ${keeper} · 런타임 · ${runtime}`
}
