(** The compaction plan gate and the checkpoint persist gate disagree, and the
    persist gate runs last.

    [Keeper_compaction_unit.partition ~quarantine:true] tolerates a structural
    break: it freezes the valid prefix and moves the break plus its successors
    into [protected_suffix] (#25413). The persist boundary does not tolerate
    it — a checkpoint must preserve every message exactly, so
    [Keeper_context_core.checkpoint_for_persistence] runs
    [Keeper_compaction_unit.validate] with quarantine off and maps a failure to
    [Tool_history_invalid] -> [Invalid_structural_source].

    Because quarantine PRESERVES the break rather than removing it, the break
    is carried into the compacted checkpoint and rejected there — after the
    summarizer has already been paid for. These tests pin that implication,
    which is what makes it safe to run the persist check BEFORE the summarizer
    call in [Keeper_compact_policy.requested_messages]:

      validate source = Error  ==>  validate (summary :: protected_suffix) = Error

    If this implication ever stops holding, the early rejection would start
    refusing compactions that could actually have persisted, and the gate in
    [requested_messages] must be revisited. *)

module U = Masc.Keeper_compaction_unit
module T = Agent_sdk.Types

let message ?tool_call_id role content : T.message =
  { role; content; name = None; tool_call_id; metadata = [] }
;;

let text role value = message role [ T.Text value ]

let use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }
;;

let result id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = Some (`Assoc [ "id", `String id ])
    ; content_blocks = None
    }
;;

(* One complete tool cycle, then an assistant turn that opens a cycle and a
   second assistant turn that opens another before the first is answered. That
   overlap is the shape observed live on analyst and idealist:

     compaction_rejected reason=invalid_structure:
       Keeper_compaction_unit.Overlapping_tool_cycle
         {message_index = 1221; tool_use_id = "call_function_mzi85j82orkf_1"}

   A merely dangling ToolUse is NOT enough — [validate] accepts a trailing open
   cycle. The rejection needs a second cycle opened while one is still open. *)
let history_with_overlapping_tool_cycle =
  [ text T.System "system preamble"
  ; text T.User "first question"
  ; message T.Assistant [ use "call-closed" ]
  ; message T.Tool [ result "call-closed" ]
  ; text T.Assistant "answered"
  ; text T.User "second question"
  ; message T.Assistant [ use "call-open" ]
  ; message T.Assistant [ use "call-overlapping" ]
  ; message T.Tool [ result "call-overlapping" ]
  ]
;;

let test_persist_gate_rejects_what_quarantine_admits () =
  (* Gate 1 (compaction planning) admits it. *)
  let partitioned =
    match U.partition ~quarantine:true history_with_overlapping_tool_cycle with
    | Ok partitioned -> partitioned
    | Error _ ->
      Alcotest.fail "quarantine partition must admit an overlapping tool cycle (#25413)"
  in
  Alcotest.(check bool)
    "quarantine produced a compactable prefix"
    true
    (partitioned.closed_prefix <> []);
  (* Gate 2 (persistence) refuses the same history. *)
  Alcotest.(check bool)
    "persist gate rejects the source history"
    true
    (Result.is_error (U.validate history_with_overlapping_tool_cycle))
;;

let test_break_survives_into_the_compacted_checkpoint () =
  let partitioned =
    match U.partition ~quarantine:true history_with_overlapping_tool_cycle with
    | Ok partitioned -> partitioned
    | Error _ -> Alcotest.fail "quarantine partition must admit an overlapping tool cycle"
  in
  Alcotest.(check bool)
    "the break was preserved in protected_suffix, not removed"
    true
    (partitioned.protected_suffix <> []);
  (* What compaction would persist: the summary replacing closed_prefix,
     followed by the untouched protected_suffix. *)
  let compacted =
    text T.Assistant "<<compaction summary>>" :: partitioned.protected_suffix
  in
  Alcotest.(check bool)
    "persist gate still rejects the compacted result"
    true
    (Result.is_error (U.validate compacted))
;;

let test_clean_history_passes_both_gates () =
  (* Guard against over-rejection: a well-formed history must still compact. *)
  let clean =
    [ text T.System "system preamble"
    ; text T.User "first question"
    ; message T.Assistant [ use "call-a" ]
    ; message T.Tool [ result "call-a" ]
    ; text T.Assistant "answered"
    ; text T.User "second question"
    ]
  in
  Alcotest.(check bool)
    "persist gate accepts a clean history"
    true
    (Result.is_ok (U.validate clean));
  match U.partition ~quarantine:true clean with
  | Ok partitioned ->
    Alcotest.(check bool)
      "clean history still yields a compactable prefix"
      true
      (partitioned.closed_prefix <> [])
  | Error _ -> Alcotest.fail "clean history must partition"
;;

(* The over-rejection guard. A turn that has issued a tool_use and not yet
   received its result is the NORMAL mid-turn shape, not a break: [validate]
   accepts a trailing open cycle (partition's [| [] ->] arm returns [Ok]
   regardless of an open cycle). If that ever changed, the gate added to
   [Keeper_compact_policy.requested_messages] would start refusing ordinary
   histories and compaction would stop fleet-wide — a far worse failure than
   the cost bleed the gate exists to stop. This is the single most important
   case in this file. *)
let test_trailing_open_cycle_is_not_a_break () =
  let trailing_open =
    [ text T.System "system preamble"
    ; text T.User "first question"
    ; message T.Assistant [ use "call-closed" ]
    ; message T.Tool [ result "call-closed" ]
    ; text T.Assistant "answered"
    ; text T.User "second question"
    ; message T.Assistant [ use "call-still-open" ]
    ]
  in
  Alcotest.(check bool)
    "persist gate accepts a history whose last tool cycle is still open"
    true
    (Result.is_ok (U.validate trailing_open));
  match U.partition ~quarantine:true trailing_open with
  | Ok partitioned ->
    Alcotest.(check bool)
      "an in-flight turn still yields a compactable prefix"
      true
      (partitioned.closed_prefix <> [])
  | Error _ -> Alcotest.fail "a trailing open cycle must not fail partition"
;;

let () =
  Alcotest.run
    "keeper_compaction_persist_gate"
    [ ( "gate_disagreement"
      , [ Alcotest.test_case
            "persist gate rejects what quarantine admits"
            `Quick
            test_persist_gate_rejects_what_quarantine_admits
        ; Alcotest.test_case
            "break survives into the compacted checkpoint"
            `Quick
            test_break_survives_into_the_compacted_checkpoint
        ; Alcotest.test_case
            "clean history passes both gates"
            `Quick
            test_clean_history_passes_both_gates
        ; Alcotest.test_case
            "trailing open cycle is not a break"
            `Quick
            test_trailing_open_cycle_is_not_a_break
        ] )
    ]
;;
