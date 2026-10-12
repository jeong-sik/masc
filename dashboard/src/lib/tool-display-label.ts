/**
 * Display labels for MASC wire tool names.
 *
 * Mirrors lib/tool_display.ml (the TUI shared module, #42624/#42642): a
 * snake_case wire name reads as its PascalCase label ("keeper_task_done" →
 * "KeeperTaskDone"), and a name containing '-' is a skill slug that is
 * already the readable name ("browser-lanes" stays). The web stack cannot
 * call the OCaml module, so the rule is ported here; the unit tests on both
 * sides pin the same mapping (keeper_task_done / browser-lanes / WebFetch) —
 * change them together (sync rule, task-2258).
 */
export function toolDisplayLabel(name: string): string {
  if (name.includes('-')) return name
  return name
    .split('_')
    .map((segment) => (segment === '' ? '' : segment[0]!.toUpperCase() + segment.slice(1)))
    .join('')
}
