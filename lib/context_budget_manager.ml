(** Context Budget Manager — session-level context window budget tracking.

    Tracks accumulated token usage across tool schemas and conversation turns,
    and determines compression phase based on usage ratio.

    Phase thresholds (usage_ratio):
    - 0.0 .. 0.50: None_phase
    - 0.50 .. 0.70: Compact_tools
    - 0.70 .. 0.85: Drop_low
    - 0.85+:        Summarize

    @since 2.128.0 *)

type compression_phase =
  | None_phase
  | Compact_tools
  | Drop_low
  | Summarize

let show_compression_phase = function
  | None_phase -> "none"
  | Compact_tools -> "compact_tools"
  | Drop_low -> "drop_low"
  | Summarize -> "summarize"

type t = {
  mutable tool_schema_tokens : int;
  mutable turn_tokens : int;
  max_budget_value : int;
}

let default_max_budget = 100_000

let max_budget_from_env () : int =
  match Sys.getenv_opt "MASC_CONTEXT_BUDGET_MAX" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some v when v > 0 -> v
      | _ -> default_max_budget)
  | None -> default_max_budget

let create ?(max_budget = 0) () : t =
  let max_budget_value =
    if max_budget > 0 then max_budget else max_budget_from_env ()
  in
  { tool_schema_tokens = 0; turn_tokens = 0; max_budget_value }

let record_tool_schemas (t : t) ~count:_ ~estimated_tokens =
  t.tool_schema_tokens <- t.tool_schema_tokens + estimated_tokens

let record_turn (t : t) ~estimated_tokens =
  t.turn_tokens <- t.turn_tokens + estimated_tokens

let total_tokens (t : t) : int =
  t.tool_schema_tokens + t.turn_tokens

let max_budget (t : t) : int = t.max_budget_value

let usage_ratio (t : t) : float =
  if t.max_budget_value <= 0 then 0.0
  else float_of_int (total_tokens t) /. float_of_int t.max_budget_value

let phase_of_ratio (ratio : float) : compression_phase =
  if ratio < 0.50 then None_phase
  else if ratio < 0.70 then Compact_tools
  else if ratio < 0.85 then Drop_low
  else Summarize

let current_phase (t : t) : compression_phase =
  phase_of_ratio (usage_ratio t)

let tool_budget_for_phase (t : t) : int option =
  match current_phase t with
  | None_phase -> None
  | Compact_tools -> Some (t.max_budget_value / 10)
  | Drop_low -> Some (t.max_budget_value / 20)
  | Summarize -> Some (t.max_budget_value / 40)

let summary (t : t) : string =
  let ratio = usage_ratio t in
  let phase = current_phase t in
  Printf.sprintf "context_budget: %d/%d tokens (%.0f%%), phase=%s"
    (total_tokens t) t.max_budget_value (ratio *. 100.0)
    (show_compression_phase phase)
