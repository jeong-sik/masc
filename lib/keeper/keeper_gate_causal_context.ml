type completed_call =
  { operation : string
  ; input : Yojson.Safe.t
  ; result : Yojson.Safe.t
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
    { operation
    ; input
    ; result = Tool_result.data result
    ; disposition = Tool_result.string_of_disposition result
    }
;;

let completed_call_to_yojson call =
  `Assoc
    [ "operation", `String call.operation
    ; "input", call.input
    ; "result", call.result
    ; "disposition", `String call.disposition
    ]
;;

(* #26081 bounded [initial.history_messages] because the judge bundle exceeded
   the judge model's prompt limit, and set the 64 KB history budget against a
   measured "~41 KB remainder of the bundle"
   ([Keeper_run_tools_setup.gate_history_budget_bytes] carries that
   measurement). [completed_tool_calls] is that remainder and it was never
   bounded, so the premise decayed: measured on live pending approvals
   2026-08-09, the largest bundle was 860,589 B of which completed calls were
   791,432 B (92%), one single [result] holding 623,999 B. The judge slot
   refused it with the same error #26081 cites verbatim -
   {"error":{"code":"1261","message":"Prompt exceeds max length"}} - and 45 of
   52 hitl_auto_judge runs failed.

   The same budget applies to both axes rather than a second tuned number: the
   refusal evidence in #26081 is a ceiling on the whole prompt (400 KB
   accepted, 800 KB refused, 300 KB of poorly-tokenising content refused), so
   two 64 KB axes plus the request identity stay under half the nearest
   refusal. Newest-first within the budget, dropping whole calls rather than
   trimming a [result], keeps this identical to [gate_history_slice]: a
   partially rendered call would assert a tool outcome the judge cannot verify,
   while a dropped one is counted in [completed_tool_calls_omitted] and
   config/prompts/judge.effect.md tells the judge how to weigh that count. *)
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
