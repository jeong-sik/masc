type completed_call =
  { operation : string
  ; input : Yojson.Safe.t
  ; disposition : string
  }

type t =
  { turn_id : int option
  ; initial : Yojson.Safe.t
  ; completed_rev : completed_call list Atomic.t
  }

let create ~turn_id ~initial =
  { turn_id; initial; completed_rev = Atomic.make [] }
;;

let rec record_completed t call =
  let current = Atomic.get t.completed_rev in
  if not (Atomic.compare_and_set t.completed_rev current (call :: current))
  then record_completed t call
;;

let record_tool_result t ~operation ~input result =
  record_completed
    t
    { operation; input; disposition = Tool_result.string_of_disposition result }
;;

(* The payload a tool returned is not recorded. The judge is the only
   consumer, its question is "may this next call proceed", and
   config/prompts/judge.md, slot effect asks it to weigh the operation identity and
   the complete input, never the payload a previous tool returned. Rendering
   that payload put a tool's entire output into a prompt about a different
   call: measured on live pending approvals 2026-08-09, the largest bundle was
   860,589 B of which completed calls were 791,432 B (92%), one single [result]
   holding 623,999 B, and the judge slot refused it with
   {"error":{"code":"1261","message":"Prompt exceeds max length"}} - the same
   error #26081 cites verbatim. 45 of 52 hitl_auto_judge runs failed.

   Dropping [result] is not a truncation. Measured over the
   same samples, the calls render at 7,473 B instead of 901,178 B (0.83%) with
   every call retained, where a size budget over the old shape had to discard
   whole calls to fit - so the judge now sees more of the turn, not less.
   [disposition] already carries whether the call completed, deferred or
   failed, which is the part the judgment turns on. A judgment that needs to
   inspect what a tool returned is a different contract than this one and would
   have to be stated in judge.md, slot effect first. *)
let completed_call_to_yojson call =
  `Assoc
    [ "operation", `String call.operation
    ; "input", call.input
    ; "disposition", `String call.disposition
    ]
;;

(* #26081 bounded [initial.history_messages] against a measured "~41 KB
   remainder of the bundle" ([Keeper_run_tools_setup.gate_history_budget_bytes]
   carries that measurement); [completed_tool_calls] is that remainder and was
   never bounded, which is how the premise decayed unnoticed. Removing [result]
   is what makes this axis small, so the budget is a ceiling rather than a
   working limit - the samples above sit three orders of magnitude under it. It
   stays because a tool [input] can itself be large, and the axis with no
   declared ceiling is the one that grows until a provider refuses the prompt.
   Both axes read this one number so neither can drift alone. *)
let evidence_budget_bytes = 64 * 1024

(* [completed_rev] is newest-first, which is already the order the budget wants,
   so the walk consumes it directly and prepending each kept call rebuilds call
   order without a second pass. A call larger than the remaining budget stops
   the walk instead of being skipped over: everything behind it is older, so
   continuing would hand the judge an older-but-smaller call while hiding the
   newer one it depends on. *)
let completed_calls_within_budget newest_first =
  let rec take budget kept = function
    | [] -> kept, 0
    | call :: older ->
      let json = completed_call_to_yojson call in
      let size = String.length (Yojson.Safe.to_string json) in
      if size > budget
      then kept, List.length older + 1
      else take (budget - size) (json :: kept) older
  in
  take evidence_budget_bytes [] newest_first
;;

let snapshot t : Keeper_gate.causal_context =
  let completed_calls, omitted =
    Atomic.get t.completed_rev |> completed_calls_within_budget
  in
  { turn_id = t.turn_id
  ; snapshot =
      `Assoc
        [ "initial", t.initial
        ; "completed_tool_calls", `List completed_calls
        ; "completed_tool_calls_omitted", `Int omitted
        ]
  }
;;
