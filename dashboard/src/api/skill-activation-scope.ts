import { validate as isUuid, version as uuidVersion } from 'uuid'

export interface NestedCompositionScope {
  parent_tool_use_id: string
  composition_run_id: string
  alias: string
}

// Same UUIDv7/identity boundary as the canonical OCaml journal constructor.
export function nestedCompositionScopeIsValid(scope: NestedCompositionScope, childToolUseId?: string): boolean {
  return scope.parent_tool_use_id.trim() !== ''
    && scope.parent_tool_use_id !== childToolUseId
    && scope.alias.length > 0
    && isUuid(scope.composition_run_id)
    && uuidVersion(scope.composition_run_id) === 7
}
