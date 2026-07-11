import { describe, expect, it } from 'vitest'

import {
  KeeperSandboxSchemaDriftError,
  parseKeeperSandboxNetworkMode,
  parseKeeperSandboxProfile,
  parseKeeperSandboxStatusResponse,
} from './keeper-sandbox-status'

function validResponse() {
  return {
    keeper: 'sangsu',
    sandbox: {
      keeper: 'sangsu',
      sandbox_profile: 'docker',
      configured_network_mode: 'none',
      effective_mode: 'docker_idle',
      security_boundary: {
        execution_boundary: 'docker_container',
        filesystem_boundary: 'explicit_container_mounts',
        network_boundary: 'isolated_network_namespace',
        credential_boundary: 'ephemeral_container_projection',
        rootfs_read_only: true,
        cap_drop_all: true,
        no_new_privileges: true,
      },
      container_count: 0,
      containers: [],
      preflight: {
        backend: 'docker',
        status: 'ok',
        ok: true,
        image: 'masc-keeper-sandbox:local',
        docker_runtime_ok: true,
        docker_runtime_error: null,
        hardening_ok: true,
        hardening_error: null,
        image_present: true,
        image_error: null,
        failure_classes: [],
        required_commands: [{ command: 'rg', available: true }],
        missing_commands: [],
        next_actions: [],
      },
      container_error: null,
      why_no_container: 'docker_idle',
      recommendation: 'No lifecycle action is required.',
      playground_repos: [] as unknown[],
      playground_repos_source: 'live',
      playground_repos_error: null,
      identity: {
        agent_name: 'keeper-sangsu',
        expected_agent_name: 'keeper-sangsu',
        agent_name_matches: true,
        trace_id: 'trace-sangsu',
        warnings: [],
      },
    },
  }
}

describe('keeper sandbox status schema', () => {
  it('parses the closed local/docker live status contract', () => {
    const result = parseKeeperSandboxStatusResponse(validResponse())
    expect(result.sandbox.effective_mode).toBe('docker_idle')
    expect(result.sandbox.preflight?.image).toBe('masc-keeper-sandbox:local')
  })

  it('rejects an unknown effective mode rather than displaying it as idle', () => {
    const input = validResponse()
    input.sandbox.effective_mode = 'managed_prewarm'
    expect(() => parseKeeperSandboxStatusResponse(input)).toThrow(KeeperSandboxSchemaDriftError)
  })

  it('rejects unknown config policy values rather than coercing them', () => {
    expect(() => parseKeeperSandboxProfile('future')).toThrow(KeeperSandboxSchemaDriftError)
    expect(() => parseKeeperSandboxNetworkMode('inherit')).toThrow(KeeperSandboxSchemaDriftError)
    expect(() => parseKeeperSandboxNetworkMode('bridge')).toThrow(KeeperSandboxSchemaDriftError)
  })

  it('rejects an unknown security boundary instead of inferring isolation from profile', () => {
    const input = validResponse()
    input.sandbox.security_boundary.execution_boundary = 'managed_container'
    expect(() => parseKeeperSandboxStatusResponse(input)).toThrow(KeeperSandboxSchemaDriftError)
  })

  it('rejects incomplete playground repository truth', () => {
    const input = validResponse()
    input.sandbox.playground_repos = [{
      name: 'masc',
      source: 'git',
      path: 'repos/masc',
    }]
    expect(() => parseKeeperSandboxStatusResponse(input)).toThrow(KeeperSandboxSchemaDriftError)
  })
})
