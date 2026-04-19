#!/usr/bin/env bash
set -euo pipefail

BASE_PATH="${BASE_PATH:-}"
MCP_URL="${MCP_URL:-http://127.0.0.1:8935/mcp}"
ROOM_ID="${ROOM_ID:-default}"
SESSION_ID="${SESSION_ID:-ts-mission-fixture-001}"
KEEPER_NAME="${KEEPER_NAME:-mission-fixture-keeper}"

if [ -z "$BASE_PATH" ]; then
  echo "BASE_PATH is required" >&2
  exit 1
fi

mkdir -p "$BASE_PATH"

BASE_PATH="$BASE_PATH" \
MCP_URL="$MCP_URL" \
ROOM_ID="$ROOM_ID" \
SESSION_ID="$SESSION_ID" \
KEEPER_NAME="$KEEPER_NAME" \
node <<'NODE'
const fs = require('fs');
const path = require('path');

const basePath = process.env.BASE_PATH;
const mcp = process.env.MCP_URL;
const roomId = process.env.ROOM_ID || 'default';
const sessionId = process.env.SESSION_ID || 'ts-mission-fixture-001';
const keeperName = process.env.KEEPER_NAME || 'mission-fixture-keeper';

const fixtureAgents = [
  { name: 'team-session-local64-smoke', capabilities: ['operator', 'fixture', 'local64'] },
  { name: 'llama-local-alpha', capabilities: ['worker', 'local64', 'manager'] },
  { name: 'llama-local-beta', capabilities: ['worker', 'local64', 'metacog'] },
  { name: 'llama-local-gamma', capabilities: ['worker', 'local64', 'executor'] },
];

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function writeJson(filePath, value) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
}

function writeJsonl(filePath, entries) {
  ensureDir(path.dirname(filePath));
  const body = entries.map(entry => JSON.stringify(entry)).join('\n') + '\n';
  fs.writeFileSync(filePath, body);
}

async function mcpCall(name, args) {
  const res = await fetch(mcp, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: Date.now() + Math.random(),
      method: 'tools/call',
      params: { name, arguments: args },
    }),
  });

  const text = await res.text();
  const dataLine = text.split('\n').find(line => line.startsWith('data: '));
  if (!dataLine) {
    throw new Error(`No MCP data line for ${name}: ${text.slice(0, 400)}`);
  }
  const payload = JSON.parse(dataLine.slice(6));
  if (payload.error) {
    throw new Error(`${name} error: ${payload.error.message}`);
  }
  return payload.result;
}

async function seedRoom() {
  await mcpCall('masc_init', { agent_name: 'mission-fixture-root' });
  for (const agent of fixtureAgents) {
    await mcpCall('masc_join', {
      agent_name: agent.name,
      capabilities: agent.capabilities,
    });
  }

  await mcpCall('masc_add_task', {
    title: 'Recover failed worker coverage',
    description: 'Mission fixture task for failed local64 worker recovery.',
    priority: 1,
  });

  await mcpCall('masc_broadcast', {
    agent_name: 'team-session-local64-smoke',
    message: '@llama-local-alpha recover failed worker coverage',
    format: 'compact',
  });

  await mcpCall('masc_broadcast', {
    agent_name: 'llama-local-alpha',
    message: 'Spawned worker recovered partial role coverage and runtime visibility.',
    format: 'compact',
  });

  await mcpCall('masc_broadcast', {
    agent_name: 'llama-local-beta',
    message: 'Metacog verified spawn failure cause and escalation path.',
    format: 'compact',
  });

  await mcpCall('masc_broadcast', {
    agent_name: 'llama-local-gamma',
    message: 'Executor confirmed role coverage gap remains in local64 lane.',
    format: 'compact',
  });

  await mcpCall('masc_keeper_up', {
    name: keeperName,
    goal: 'Guard fixture continuity while the mission dashboard is inspected.',
    models: ['glm:auto'],
    presence_keepalive: false,
    proactive_enabled: false,
    auto_handoff: false,
  });
}

function seedExecutionSession() {
  const now = Date.now();
  const startedAt = Math.floor(now / 1000) - 45;
  const startedIso = new Date(startedAt * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const updatedIso = nowIso();
  const sessionDir = path.join(basePath, '.masc', 'team-sessions', sessionId);
  const session = {
    session_id: sessionId,
    goal: 'Validate local64 worker coverage, runtime visibility, and operator census',
    created_by: 'mission-fixture-root',
    room_id: roomId,
    status: 'interrupted',
    duration_seconds: 2700,
    execution_scope: 'observe_only',
    checkpoint_interval_sec: 60,
    min_agents: 1,
    scale_profile: 'local64',
    control_profile: 'hierarchical_quality_v1',
    orchestration_mode: 'assist',
    communication_mode: 'hybrid',
    model_cascade: ['qwen3.5-35b-a3b-ud-q8-xl', 'qwen27-balanced', 'qwen9-worker'],
    fallback_policy: 'cascade_then_task',
    instruction_profile: 'strict',
    alert_channel: 'both',
    auto_resume: false,
    report_formats: ['markdown', 'json'],
    turn_count: 4,
    agent_names: fixtureAgents.map(agent => agent.name),
    planned_workers: [
      {
        spawn_agent: 'llama',
        runtime_actor: 'llama-local-alpha',
        spawn_role: 'manager',
        spawn_model: 'qwen3.5-35b-a3b-ud-q8-xl',
        worker_class: 'manager',
        parent_actor: 'team-session-local64-smoke',
        capsule_mode: 'inherit',
        runtime_pool: 'local64',
        lane_id: 'lane-manager',
        controller_level: 'root',
        control_domain: 'execution',
        supervisor_actor: 'team-session-local64-smoke',
        model_tier: '35b',
        task_profile: 'decide',
        risk_level: 'high',
        routing_confidence: 0.94,
        routing_reason: 'manager must hold root synthesis',
        routing_escalated: false,
      },
      {
        spawn_agent: 'llama',
        runtime_actor: 'llama-local-beta',
        spawn_role: 'metacog',
        spawn_model: 'qwen27-balanced',
        worker_class: 'metacog',
        parent_actor: 'team-session-local64-smoke',
        capsule_mode: 'inherit',
        runtime_pool: 'local64',
        lane_id: 'lane-meta',
        controller_level: 'lane',
        control_domain: 'meta',
        supervisor_actor: 'llama-local-alpha',
        model_tier: '27b',
        task_profile: 'verify',
        risk_level: 'medium',
        routing_confidence: 0.68,
        routing_reason: 'low confidence because spawn failures hide runtime census',
        routing_escalated: true,
      },
      {
        spawn_agent: 'llama',
        runtime_actor: 'llama-local-gamma',
        spawn_role: 'executor',
        spawn_model: 'qwen9-worker',
        worker_class: 'executor',
        parent_actor: 'team-session-local64-smoke',
        capsule_mode: 'fresh',
        runtime_pool: 'local64',
        lane_id: 'lane-worker',
        controller_level: 'worker',
        control_domain: 'runtime',
        supervisor_actor: 'llama-local-alpha',
        model_tier: '9b',
        task_profile: 'extract',
        risk_level: 'medium',
        routing_confidence: 0.88,
        routing_reason: 'executor covers direct runtime checks',
        routing_escalated: false,
      },
    ],
    broadcast_count: 3,
    portal_count: 0,
    cascade_attempted: 1,
    cascade_success: 0,
    cascade_failed: 1,
    fallback_task_created: 1,
    min_agents_violation_streak: 0,
    policy_violations: [],
    baseline_done_counts: [],
    final_done_delta_total: null,
    final_done_delta_by_agent: null,
    started_at: startedAt,
    planned_end_at: startedAt + 2700,
    stopped_at: startedAt + 45.125,
    last_checkpoint_at: startedAt + 30.125,
    last_event_at: startedAt + 42.125,
    last_turn_at: startedAt + 32.125,
    stop_reason: 'fixture_interrupted_after_spawn_failure',
    generated_report: false,
    artifacts_dir: path.join('.masc', 'team-sessions', sessionId),
    created_at_iso: startedIso,
    updated_at_iso: updatedIso,
  };

  const events = [
    {
      ts: startedAt + 5,
      ts_iso: new Date((startedAt + 5) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'team_step_spawn',
      detail: {
        actor: 'team-session-local64-smoke',
        spawn_agent: 'llama',
        runtime_actor: 'llama-local-delta',
        success: false,
        reason: 'Connection refused on secondary runtime',
        title: 'Recover failed worker coverage',
      },
    },
    {
      ts: startedAt + 8,
      ts_iso: new Date((startedAt + 8) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'team_step_spawn',
      detail: {
        actor: 'team-session-local64-smoke',
        spawn_agent: 'llama',
        runtime_actor: 'llama-local-epsilon',
        success: false,
        reason: 'Slot census timed out on local64 runtime',
        title: 'Recover failed worker coverage',
      },
    },
    {
      ts: startedAt + 18,
      ts_iso: new Date((startedAt + 18) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'team_turn',
      detail: {
        kind: 'note',
        actor: 'llama-local-alpha',
        message: 'manager synthesized runtime visibility and confirmed the missing workers',
      },
    },
    {
      ts: startedAt + 22,
      ts_iso: new Date((startedAt + 22) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'team_turn',
      detail: {
        kind: 'note',
        actor: 'llama-local-beta',
        message: 'metacog reviewed the failed spawn events and escalated the runtime mismatch',
      },
    },
    {
      ts: startedAt + 28,
      ts_iso: new Date((startedAt + 28) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'team_turn',
      detail: {
        kind: 'note',
        actor: 'llama-local-gamma',
        message: 'executor confirmed the local64 role coverage gap remains unresolved',
      },
    },
    {
      ts: startedAt + 42,
      ts_iso: new Date((startedAt + 42) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      event_type: 'local64_smoke_cleanup',
      detail: {
        actor: 'team-session-local64-smoke',
        result: 'interrupted after fixture spawn failure reproduction',
      },
    },
  ];

  writeJson(path.join(sessionDir, 'session.json'), session);
  writeJsonl(path.join(sessionDir, 'events.jsonl'), events);
}

function seedPendingConfirm() {
  const operatorDir = path.join(basePath, '.masc', 'operator');
  writeJson(path.join(operatorDir, 'pending_confirms.json'), [
    {
      token: 'confirm-mission-fixture-001',
      confirm_token: 'confirm-mission-fixture-001',
      trace_id: 'ops_fixture_mission',
      actor: 'dashboard-fixture',
      action_type: 'namespace_pause',
      target_type: 'root',
      target_id: null,
      payload: {
        reason: 'Fixture pending confirmation for mission dashboard',
      },
      delegated_tool: 'masc_pause',
      created_at: nowIso(),
      expires_at: null,
    },
  ]);
}

(async () => {
  await seedRoom();
  seedExecutionSession();
  seedPendingConfirm();
  console.log(JSON.stringify({
    ok: true,
    basePath,
    roomId,
    sessionId,
    keeperName,
    agents: fixtureAgents.map(agent => agent.name),
  }, null, 2));
})().catch(err => {
  console.error(err);
  process.exit(1);
});
NODE
