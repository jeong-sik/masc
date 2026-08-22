(* The agent-core → MASC log bridge renders the human line for every record
   the core emits. It used to build that line from a hardcoded key allowlist
   selected by matching on the message text, and fell back to a fixed guess
   for anything it did not recognise. The line then lied by omission:

     - [turn checkpoint persisted] carries [stage], [turn] and [messages], but
       only [turn] was in the fallback list, so the three checkpoint stages of
       one turn rendered as three identical lines — 1,289 of them in the two
       hours to 2026-08-22T02:03Z, and the pairs read as duplicate emissions.
     - [pipeline stage failed] carries [stage] and [error] and rendered with
       neither, so a WARN told the operator a stage failed without saying
       which stage or why.
     - Selecting keys by message text meant every message a producer added
       later fell into the guess by default.

   These tests pin the replacement contract: the line carries the fields the
   producer attached, in the order it attached them, and anything the line
   cannot fit says so instead of vanishing. *)

open Masc

let install_once = lazy (Runtime_log_sink.install ())

let emit_record ~module_name ~message fields =
  Lazy.force install_once;
  let logger = Agent_core.Log.create ~module_name () in
  Agent_core.Log.info logger message fields

let newest_message () =
  match Log.Ring.recent ~limit:1 () with
  | [] -> Alcotest.fail "the emitted record never reached the ring"
  | entry :: _ -> entry.Log.Ring.message

let newest_entry () =
  match Log.Ring.recent ~limit:1 () with
  | [] -> Alcotest.fail "the emitted record never reached the ring"
  | entry :: _ -> entry

let checkpoint stage =
  emit_record
    ~module_name:"pipeline_checkpoint"
    ~message:"turn checkpoint persisted"
    [ Agent_core.Log.S ("stage", stage)
    ; Agent_core.Log.I ("turn", 392)
    ; Agent_core.Log.I ("messages", 691)
    ];
  newest_message ()

let test_checkpoint_stages_do_not_collapse () =
  let collected = checkpoint "after_assistant_collected" in
  let appended = checkpoint "after_tool_results_appended" in
  let injected = checkpoint "after_context_injection" in
  Alcotest.(check int)
    "one turn's three checkpoint stages are three distinct lines"
    3
    (List.length (List.sort_uniq compare [ collected; appended; injected ]));
  Alcotest.(check bool)
    "the stage that distinguishes them is on the line"
    true
    (String.length collected
     > String.length "turn checkpoint persisted"
     && Astring.String.is_infix ~affix:"stage=after_assistant_collected" collected)

let test_unknown_message_keeps_its_fields () =
  emit_record
    ~module_name:"pipeline"
    ~message:"pipeline stage failed"
    [ Agent_core.Log.S ("stage", "route")
    ; Agent_core.Log.S ("error", "[route] Rate limited: Rate limit reached")
    ];
  let message = newest_message () in
  Alcotest.(check bool)
    "the failing stage is named"
    true
    (Astring.String.is_infix ~affix:"stage=route" message);
  (* The value carries spaces, so it must be quoted or the line stops being
     readable as a sequence of key=value pairs. *)
  Alcotest.(check bool)
    "the error is on the line, quoted"
    true
    (Astring.String.is_infix
       ~affix:{|error="[route] Rate limited: Rate limit reached"|}
       message)

let test_details_still_carry_every_field () =
  emit_record
    ~module_name:"pipeline_checkpoint"
    ~message:"turn checkpoint persisted"
    [ Agent_core.Log.S ("stage", "after_context_injection")
    ; Agent_core.Log.I ("turn", 7)
    ; Agent_core.Log.I ("messages", 13)
    ];
  match (newest_entry ()).Log.Ring.details with
  | `Assoc fields ->
    Alcotest.(check (list string))
      "details keep the producer's fields"
      [ "stage"; "turn"; "messages" ]
      (List.map fst fields)
  | other ->
    Alcotest.failf "details is not an object: %s" (Yojson.Safe.to_string other)

let test_overflowing_fields_are_announced_not_dropped () =
  let fields =
    List.init 20 (fun i -> Agent_core.Log.I (Printf.sprintf "f%02d" i, i))
  in
  emit_record ~module_name:"pipeline" ~message:"wide record" fields;
  let entry = newest_entry () in
  Alcotest.(check bool)
    "the fields the line could not fit are counted on the line"
    true
    (Astring.String.is_infix ~affix:"(+4 more in details)" entry.Log.Ring.message);
  match entry.Log.Ring.details with
  | `Assoc kept ->
    Alcotest.(check int) "details drop nothing" 20 (List.length kept)
  | other ->
    Alcotest.failf "details is not an object: %s" (Yojson.Safe.to_string other)

let () =
  Alcotest.run
    "runtime_log_sink_render"
    [ ( "render"
      , [ Alcotest.test_case
            "checkpoint stages do not collapse"
            `Quick
            test_checkpoint_stages_do_not_collapse
        ; Alcotest.test_case
            "an unrecognised message keeps its fields"
            `Quick
            test_unknown_message_keeps_its_fields
        ; Alcotest.test_case
            "details still carry every field"
            `Quick
            test_details_still_carry_every_field
        ; Alcotest.test_case
            "overflowing fields are announced"
            `Quick
            test_overflowing_fields_are_announced_not_dropped
        ] )
    ]
