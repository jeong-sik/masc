import {
  AlertTriangle,
  CirclePause,
  FileWarning,
  Gauge,
  LoaderCircle,
  PlayCircle,
  RefreshCcw,
  ShieldAlert,
  Square,
  UserPlus,
  Wrench,
} from 'lucide-preact'
import type { LucideIcon } from 'lucide-preact'
import type {
  DashboardBlockedKeeperFact,
  DashboardFleetPressureHealth,
  DashboardKeeperFleetOperatorAction,
} from '../types'

export type KeeperFleetOperatorTone = 'warn' | 'bad'

interface KeeperFleetOperatorActionPresentation {
  label: string
  tone: KeeperFleetOperatorTone
  Icon: LucideIcon
  action: string
}

export interface KeeperFleetOperatorFactPresentation
  extends KeeperFleetOperatorActionPresentation {
  keeper: string
  reason: DashboardBlockedKeeperFact['reason']
  executionTruth: DashboardBlockedKeeperFact['execution_truth']
  nonExecutableCause: DashboardBlockedKeeperFact['non_executable_cause']
  // The row collapses to keeper_name ?? agent_name, which is null for
  // no_keeper_binding facts — so two unbound tasks of one agent rendered as
  // indistinguishable rows while the instruction said to reassign "the task".
  // Carried so the presentation names the identity its action refers to.
  taskId: string | null
}

const ACTION_PRESENTATION = {
  resume_or_leave_paused: {
    label: 'Keeper paused',
    tone: 'warn',
    Icon: CirclePause,
    action: 'resume selected paused keepers or confirm an intentional operator pause policy.',
  },
  repair_keeper_meta_file: {
    label: 'Keeper metadata unreadable',
    tone: 'bad',
    Icon: FileWarning,
    action: 'repair the current Keeper metadata file before activation.',
  },
  add_keeper_toml_or_disable_stale_autoboot_meta: {
    label: 'Keeper definition missing',
    tone: 'bad',
    Icon: FileWarning,
    action: 'add the Keeper definition or remove the unsupported runtime state.',
  },
  run_keeper_up_or_recreate_meta: {
    label: 'Keeper metadata missing',
    tone: 'bad',
    Icon: PlayCircle,
    action: 'create the current Keeper metadata before activation.',
  },
  repair_keeper_toml_config: {
    label: 'Keeper configuration invalid',
    tone: 'bad',
    Icon: Wrench,
    action: 'repair the current Keeper configuration.',
  },
  add_sandbox_profile_to_keeper_toml: {
    label: 'Keeper sandbox profile missing',
    tone: 'bad',
    Icon: ShieldAlert,
    action: 'add a valid sandbox profile to the Keeper definition.',
  },
  inspect_keeper_autoboot_logs: {
    label: 'Keeper materialization failed',
    tone: 'bad',
    Icon: AlertTriangle,
    action: 'inspect the typed materialization failure and repair its current input.',
  },
  enable_keeper_bootstrap_or_start_manually: {
    label: 'Keeper bootstrap disabled',
    tone: 'warn',
    Icon: PlayCircle,
    action: 'enable Keeper bootstrap or start the Keeper explicitly.',
  },
  inspect_dead_keeper_root_cause: {
    label: 'Keeper dead',
    tone: 'bad',
    Icon: ShieldAlert,
    action: 'inspect and repair the terminal Keeper cause before recovery.',
  },
  restart_or_disable_stopped_keeper: {
    label: 'Keeper stopped',
    tone: 'warn',
    Icon: Square,
    action: 'restart the Keeper or keep it explicitly disabled.',
  },
  start_or_recover_keeper: {
    label: 'Keeper not running',
    tone: 'warn',
    Icon: PlayCircle,
    action: 'start or recover the Keeper.',
  },
  inspect_capacity_accounting: {
    label: 'Keeper capacity fact inconsistent',
    tone: 'bad',
    Icon: Gauge,
    action: 'inspect the typed capacity fact before changing fleet targets.',
  },
  repair_failing_keeper: {
    label: 'Keeper failing',
    tone: 'bad',
    Icon: Wrench,
    action: 'inspect and recover failing keepers before retrying scheduled activation.',
  },
  recover_context_overflow: {
    label: 'Keeper context overflowed',
    tone: 'bad',
    Icon: AlertTriangle,
    action: 'recover the Keeper from the typed context-overflow state.',
  },
  wait_for_compaction: {
    label: 'Keeper compacting',
    tone: 'warn',
    Icon: LoaderCircle,
    action: 'wait for the current compaction operation to settle.',
  },
  wait_for_handoff: {
    label: 'Keeper handing off',
    tone: 'warn',
    Icon: LoaderCircle,
    action: 'wait for the current handoff operation to settle.',
  },
  wait_for_keeper_drain: {
    label: 'Keeper draining',
    tone: 'warn',
    Icon: LoaderCircle,
    action: 'wait for the current drain operation to settle.',
  },
  inspect_crashed_keeper: {
    label: 'Keeper crashed',
    tone: 'bad',
    Icon: AlertTriangle,
    action: 'inspect and repair the typed crash cause before recovery.',
  },
  wait_for_keeper_restart: {
    label: 'Keeper restarting',
    tone: 'warn',
    Icon: RefreshCcw,
    action: 'keeper recovery is in progress; wait for executable capacity before intervening.',
  },
  create_keeper_or_reassign_task: {
    label: 'Task owner has no Keeper',
    tone: 'bad',
    Icon: UserPlus,
    action: 'create the Keeper binding or reassign the task.',
  },
  inspect_current_keeper_fact: {
    label: 'Current Keeper fact invalid',
    tone: 'bad',
    Icon: ShieldAlert,
    action: 'inspect the current Keeper fleet fact and restore a canonical current snapshot.',
  },
} satisfies Record<DashboardKeeperFleetOperatorAction, KeeperFleetOperatorActionPresentation>

export const CURRENT_KEEPER_FLEET_FACT_INVALID: DashboardBlockedKeeperFact = {
  keeper_name: null,
  agent_name: null,
  task_id: null,
  task_status: null,
  reason: 'current_fact_invalid',
  action: 'inspect_current_keeper_fact',
  execution_truth: 'unknown',
  non_executable_cause: 'current_fact_invalid',
  operator_action_type: null,
  operator_tool_name: null,
  operator_action_confirm_required: null,
}

// Severity the action table already declares, not a new ranking invented here.
// Exhaustive over the closed tone union, so adding a tone is a compile error
// until it declares its rank.
const TONE_RANK: Record<KeeperFleetOperatorTone, number> = { bad: 0, warn: 1 }

export function keeperFleetOperatorFacts(
  fleet: DashboardFleetPressureHealth | null | undefined,
): DashboardBlockedKeeperFact[] {
  if (fleet?.status === 'ok') return []
  // The server orders blocked_keepers by keeper identity, and three of the four
  // consumers take [0] to speak for the whole fleet — so a keeper that was only
  // waiting could outrank, and hide, one that needed repair. Ordered here, at
  // the single point every consumer goes through, rather than at each call site.
  // Array.prototype.sort is stable, so equal-severity facts keep the server's
  // order.
  if (fleet?.blocked_keepers?.length)
    return [...fleet.blocked_keepers].sort(
      (a, b) =>
        TONE_RANK[ACTION_PRESENTATION[a.action].tone] -
        TONE_RANK[ACTION_PRESENTATION[b.action].tone],
    )
  return [CURRENT_KEEPER_FLEET_FACT_INVALID]
}

export function keeperFleetOperatorFactPresentation(
  fact: DashboardBlockedKeeperFact,
  fleetStatus: DashboardFleetPressureHealth['status'] | null | undefined,
): KeeperFleetOperatorFactPresentation {
  const presentation = ACTION_PRESENTATION[fact.action]
  return {
    ...presentation,
    tone:
      fact.reason === 'current_fact_invalid' || fleetStatus === 'blocked'
        ? 'bad'
        : fleetStatus === 'degraded'
          ? 'warn'
          : presentation.tone,
    keeper: fact.keeper_name ?? fact.agent_name ?? 'Keeper fleet',
    reason: fact.reason,
    executionTruth: fact.execution_truth,
    nonExecutableCause: fact.non_executable_cause,
    taskId: fact.task_id,
  }
}
