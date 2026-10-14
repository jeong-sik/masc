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
 *
 * The first-letter lift is ASCII-only on purpose (task-2327): inputs beyond
 * the tool registry carry no ASCII promise — skill slugs pass
 * package_id_of_directory, which blocks separators and NUL but not non-ASCII
 * bytes, and MCP tool names come from outside the process — and
 * String.prototype.toUpperCase() lifts non-ASCII cased letters where
 * String.capitalize_ascii leaves every byte >= 0x80 untouched, so the port
 * would diverge from the TUI on e.g. "über_tool". Lifting only [a-z] keeps
 * the mirror byte-faithful to capitalize_ascii on every string.
 */
const ASCII_LOWER_A = 0x61

const asciiLift = (c: string): string => {
  const code = c.charCodeAt(0)
  return code >= ASCII_LOWER_A && code <= ASCII_LOWER_A + 25
    ? String.fromCharCode(code - 32)
    : c
}

export function toolDisplayLabel(name: string): string {
  if (name.includes('-')) return name
  return name
    .split('_')
    .map((segment) => (segment === '' ? '' : asciiLift(segment[0]!) + segment.slice(1)))
    .join('')
}
