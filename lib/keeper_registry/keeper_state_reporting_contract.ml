type surface =
  | State_block

type field =
  | Done
  | Next
  | Goal
  | Decisions
  | OpenQuestions
  | Constraints

let version = "state-reporting.v1"
let surface = State_block

let surface_to_string = function
  | State_block -> "state_block"

let all_fields = [ Done; Next; Goal; Decisions; OpenQuestions; Constraints ]

let field_name = function
  | Done -> "DONE"
  | Next -> "NEXT"
  | Goal -> "Goal"
  | Decisions -> "Decisions"
  | OpenQuestions -> "OpenQuestions"
  | Constraints -> "Constraints"

let field_summary =
  all_fields
  |> List.map field_name
  |> function
  | [] -> ""
  | [ only ] -> only
  | fields ->
      let rec split_last acc = function
        | [] -> ("", List.rev acc)
        | [ last ] -> (last, List.rev acc)
        | x :: xs -> split_last (x :: acc) xs
      in
      let last, prefix = split_last [] fields in
      Printf.sprintf "%s, and %s" (String.concat ", " prefix) last

let template_line = function
  | Done -> "DONE: what you accomplished this turn"
  | Next -> "NEXT: what the next turn should do"
  | Goal ->
      "Goal: active goal id from <available_goals> verbatim (e.g. goal-123-04af), never prose; omit this line when no goal id applies"
  | Decisions -> "Decisions: key decisions (semicolon-separated)"
  | OpenQuestions -> "OpenQuestions: unresolved items (semicolon-separated)"
  | Constraints -> "Constraints: active constraints (semicolon-separated)"

let template_text =
  String.concat "\n"
    (("[STATE]" :: List.map template_line all_fields) @ [ "[/STATE]" ])

let instruction_text =
  String.concat "\n"
    [
      Printf.sprintf
        "State block template: for non-direct keeper turns, report continuity \
         using the [STATE] block at the end of your response. Fields: %s. All \
         fields are optional but provide as many as you can. Contract: %s."
        field_summary version;
      template_text;
    ]

let recovery_line =
  Printf.sprintf
    "State block template: non-direct keeper turns must report structured \
     continuity via [STATE]...[/STATE] blocks containing %s. Contract: %s."
    field_summary version

let output_guard_text =
  "Output guard: this turn uses runtime-managed continuity. Report state via [STATE]...[/STATE] blocks. The runtime will synthesize and persist state metadata when needed."

let forbidden_tool_tokens =
  [
    "keeper_report_state";
  ]

let is_tool_token_char = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '_' ->
      true
  | _ -> false

let contains_standalone_token text token =
  let text_len = String.length text in
  let token_len = String.length token in
  let rec loop pos =
    if token_len = 0 || pos + token_len > text_len then false
    else if
      String.sub text pos token_len = token
      && (pos = 0 || not (is_tool_token_char text.[pos - 1]))
      &&
      let after = pos + token_len in
      after >= text_len || not (is_tool_token_char text.[after])
    then true
    else loop (pos + 1)
  in
  loop 0

let forbidden_tool_tokens_in_text text =
  List.filter (contains_standalone_token text) forbidden_tool_tokens
