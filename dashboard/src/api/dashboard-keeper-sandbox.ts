import { callMcpTool } from './mcp'
import {
  parseKeeperSandboxStatusResponse,
  type KeeperSandboxStatusResponse,
} from './schemas/keeper-sandbox-status'

export class KeeperSandboxResponseDecodeError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'KeeperSandboxResponseDecodeError'
  }
}

export async function fetchKeeperSandboxStatus(
  keeperName: string,
): Promise<KeeperSandboxStatusResponse> {
  const name = keeperName.trim()
  if (!name) throw new KeeperSandboxResponseDecodeError('keeper name is required')

  const text = await callMcpTool('masc_keeper_sandbox_status', {
    name,
    include_preflight: true,
    verbose: true,
  })

  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch (cause) {
    throw new KeeperSandboxResponseDecodeError(
      'keeper sandbox status returned invalid JSON',
      { cause },
    )
  }

  return parseKeeperSandboxStatusResponse(raw)
}
