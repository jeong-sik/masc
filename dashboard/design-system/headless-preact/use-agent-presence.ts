/**
 * useAgentPresence — Preact adapter over headless-core/AgentPresenceManager.
 *
 * Per RFC 0008 §3.4. Hooks for whole-snapshot, per-agent, and
 * by-state subscriptions. The manager is provided externally
 * (typically via Preact context allocated at app boot) so multiple
 * surfaces share one canonical roster.
 */

import { useEffect, useState } from 'preact/hooks'
import type {
  Agent,
  AgentPresenceManager,
  AgentState,
} from '../headless-core/agent-presence'

export function useAgentPresence(manager: AgentPresenceManager): {
  readonly agents: ReadonlyArray<Agent>
} {
  const [snapshot, setSnapshot] = useState<ReadonlyArray<Agent>>(() => [
    ...manager.agents.values(),
  ])
  useEffect(() => {
    const dispose = manager.subscribe((s) => setSnapshot(s))
    return dispose
  }, [manager])
  return { agents: snapshot }
}

export function useAgent(
  manager: AgentPresenceManager,
  id: string,
): Agent | undefined {
  const [agent, setAgent] = useState<Agent | undefined>(() => manager.agents.get(id))
  useEffect(() => {
    setAgent(manager.agents.get(id))
    const dispose = manager.subscribeAgent(id, (a) => setAgent(a))
    return dispose
  }, [manager, id])
  return agent
}

export function useAgentsByState(
  manager: AgentPresenceManager,
  state: AgentState,
): ReadonlyArray<Agent> {
  const [agents, setAgents] = useState<ReadonlyArray<Agent>>(() =>
    manager.byState(state),
  )
  useEffect(() => {
    setAgents(manager.byState(state))
    const dispose = manager.subscribe(() => setAgents(manager.byState(state)))
    return dispose
  }, [manager, state])
  return agents
}
