(** RFC-0233 §5 harness for PR-3: Prompt_block_id round-trip, TurnRecord
    codec round-trip, and block-diff exactness (the "what entered/left
    context" question as a test). *)

open Alcotest

let block_id = testable (Fmt.of_to_string Prompt_block_id.to_string) Prompt_block_id.equal

(* ── Prompt_block_id ──────────────────────────────────── *)

let test_block_id_roundtrip () =
  List.iter
    (fun block ->
      check block_id
        (Printf.sprintf "roundtrip %s" (Prompt_block_id.to_string block))
        block
        (Prompt_block_id.of_string (Prompt_block_id.to_string block)))
    Prompt_block_id.all_known

let test_block_id_unknown_maps_to_other () =
  check block_id "unknown name survives as Other"
    (Prompt_block_id.Other "future_block")
    (Prompt_block_id.of_string "future_block");
  check string "Other renders its name" "future_block"
    (Prompt_block_id.to_string (Prompt_block_id.Other "future_block"))

(* ── TurnRecord codec ─────────────────────────────────── *)

let sample_block block digest =
  { Turn_record.block; bytes = String.length digest; digest }

let default_blocks () =
  [ sample_block Prompt_block_id.Persona "aaaa"
  ; sample_block Prompt_block_id.Dynamic_context "bbbb"
  ; sample_block Prompt_block_id.Memory_os_recall "cccc"
  ]

let default_sampling : Turn_record.sampling =
  { temperature = Some 0.3
  ; top_p = Some 0.9
  ; max_tokens = Some 8192
  ; thinking_budget = Some 1500
  ; enable_thinking = Some true
  }

let default_usage : Turn_record.usage =
  { input_tokens = Some 18000; output_tokens = Some 412 }

let make_sample_record
      ?(keeper = "sangsu")
      ?(trace_id = "trace-1780648779957-00000")
      ?(absolute_turn = 4071)
      ?(blocks = default_blocks ())
      ?(runtime_profile = "ollama_cloud.deepseek-v4-flash")
      ?(model = Some "deepseek-v4-flash")
      ?(finish_reason = Some "completed")
      ?(context_window = Some 131072)
      ?(price_input_per_million = Some 0.15)
      ?(price_output_per_million = Some 0.6)
      ?(request_latency_ms = Some 1234)
      ?(ttfrc_ms = Some 567.8)
      ?(sampling = default_sampling)
      ?(usage = default_usage)
      ?(ts = 1781200000.5)
      ()
  =
  Turn_record.make
    ~keeper
    ~trace_id
    ~absolute_turn
    ~blocks
    ~runtime_profile
    ~model
    ~finish_reason
    ~context_window
    ~price_input_per_million
    ~price_output_per_million
    ~request_latency_ms
    ~ttfrc_ms
    ~sampling
    ~usage
    ~ts

let sample_record ?keeper ?trace_id ?absolute_turn ?blocks ?runtime_profile ?model
      ?finish_reason ?context_window ?price_input_per_million
      ?price_output_per_million ?request_latency_ms ?ttfrc_ms ?sampling ?usage ?ts ()
  =
  match
    make_sample_record
      ?keeper
      ?trace_id
      ?absolute_turn
      ?blocks
      ?runtime_profile
      ?model
      ?finish_reason
      ?context_window
      ?price_input_per_million
      ?price_output_per_million
      ?request_latency_ms
      ?ttfrc_ms
      ?sampling
      ?usage
      ?ts
      ()
  with
  | Ok record -> record
  | Error reason -> failf "sample TurnRecord rejected: %s" reason

let check_make_error label expected = function
  | Ok _ -> failf "%s: invalid TurnRecord was accepted" label
  | Error reason -> check string label expected reason

let replace_field name value = function
  | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
  | _ -> fail "TurnRecord JSON was not an object"

let test_codec_roundtrip () =
  let record = sample_record () in
  match Turn_record.of_json (Turn_record.to_json record) with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check string "keeper" record.keeper decoded.keeper;
    check string "trace_id" record.trace_id decoded.trace_id;
    check int "absolute_turn" record.absolute_turn decoded.absolute_turn;
    check bool "turn_ref preserved" true
      (Ids.Turn_ref.equal record.turn_ref decoded.turn_ref);
    check int "blocks count" 3 (List.length decoded.blocks);
    check bool "blocks preserved in order" true
      (List.for_all2
         (fun (a : Turn_record.prompt_block) (b : Turn_record.prompt_block) ->
           Prompt_block_id.equal a.block b.block
           && a.bytes = b.bytes
           && String.equal a.digest b.digest)
         record.blocks decoded.blocks);
    check string "runtime_profile" record.runtime_profile decoded.runtime_profile;
    check (option string) "model" record.model decoded.model;
    check (option string) "finish_reason" record.finish_reason decoded.finish_reason;
    check (option int) "context_window" record.context_window decoded.context_window;
    check (option (float 0.0001)) "price_input_per_million"
      record.price_input_per_million decoded.price_input_per_million;
    check (option (float 0.0001)) "price_output_per_million"
      record.price_output_per_million decoded.price_output_per_million;
    check (option int) "request_latency_ms round-trip" record.request_latency_ms
      decoded.request_latency_ms;
    check (option (float 0.0001)) "ttfrc_ms round-trip" record.ttfrc_ms
      decoded.ttfrc_ms;
    check (option (float 0.0001)) "temperature" record.sampling.temperature
      decoded.sampling.temperature;
    check (option (float 0.0001)) "top_p" record.sampling.top_p
      decoded.sampling.top_p;
    check (option int) "max_tokens" record.sampling.max_tokens
      decoded.sampling.max_tokens;
    check (option int) "thinking_budget" record.sampling.thinking_budget
      decoded.sampling.thinking_budget;
    check (option bool) "enable_thinking" record.sampling.enable_thinking
      decoded.sampling.enable_thinking;
    check (option int) "input_tokens" record.usage.input_tokens
      decoded.usage.input_tokens;
    check (option int) "output_tokens" record.usage.output_tokens
      decoded.usage.output_tokens;
    check (float 0.0001) "ts" record.ts decoded.ts

let test_codec_optional_fields_absent () =
  let record =
    sample_record
      ~model:None
      ~finish_reason:None
      ~context_window:None
      ~price_input_per_million:None
      ~price_output_per_million:None
      ~request_latency_ms:None
      ~ttfrc_ms:None
      ~sampling:
        { temperature = None
        ; top_p = None
        ; max_tokens = None
        ; thinking_budget = None
        ; enable_thinking = None
        }
      ~usage:{ input_tokens = None; output_tokens = None }
      ()
  in
  let json = Turn_record.to_json record in
  (* RFC-0233 §2.3/§8: absent meta fields are omitted from the wire, never
     emitted as a fabricated value (no "stop", no placeholder model, no
     fabricated 200K window or Claude $3/$15 price). *)
  (match json with
   | `Assoc fields ->
     check bool "finish_reason key omitted when None" false
       (List.mem_assoc "finish_reason" fields);
     check bool "model key omitted when None" false
       (List.mem_assoc "model" fields);
     check bool "top_p key omitted when None" false
       (List.mem_assoc "top_p" fields);
     check bool "max_tokens key omitted when None" false
       (List.mem_assoc "max_tokens" fields);
     check bool "context_window key omitted when None" false
       (List.mem_assoc "context_window" fields);
     check bool "price_input_per_million key omitted when None" false
       (List.mem_assoc "price_input_per_million" fields);
     check bool "request_latency_ms key omitted when None" false
       (List.mem_assoc "request_latency_ms" fields);
     check bool "ttfrc_ms key omitted when None" false
       (List.mem_assoc "ttfrc_ms" fields)
   | _ -> fail "to_json did not produce an object");
  match Turn_record.of_json json with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check (option string) "model absent stays None" None decoded.model;
    check (option string) "finish_reason absent stays None (not \"stop\")" None
      decoded.finish_reason;
    check (option int) "context_window absent stays None" None decoded.context_window;
    check (option (float 0.0001)) "price_input_per_million absent" None
      decoded.price_input_per_million;
    check (option (float 0.0001)) "price_output_per_million absent" None
      decoded.price_output_per_million;
    check (option int) "request_latency_ms absent" None
      decoded.request_latency_ms;
    check (option (float 0.0001)) "ttfrc_ms absent" None
      decoded.ttfrc_ms;
    check (option (float 0.0001)) "temperature absent" None
      decoded.sampling.temperature;
    check (option (float 0.0001)) "top_p absent" None decoded.sampling.top_p;
    check (option int) "max_tokens absent" None decoded.sampling.max_tokens;
    check (option int) "input_tokens absent" None decoded.usage.input_tokens;
    check bool "turn_ref remains exact" true
      (Ids.Turn_ref.equal record.turn_ref decoded.turn_ref)

let test_codec_rejects_malformed () =
  (match Turn_record.of_json (`String "not a record") with
   | Ok _ -> fail "decoded a non-object"
   | Error _ -> ());
  match Turn_record.of_json (`Assoc [ ("keeper", `String "x") ]) with
  | Ok _ -> fail "decoded a row with missing fields"
  | Error msg ->
    check string "error names the required current field"
      "turn_record: missing field \"trace_id\"" msg

let test_codec_rejects_retired_execution_ids () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields -> `Assoc (("execution_ids", `List []) :: fields)
    | _ -> fail "to_json did not produce an object"
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded the retired execution_ids field"
  | Error msg ->
    check string "retired field is explicitly unexpected"
      "turn_record: row unexpected field \"execution_ids\"" msg

let test_codec_requires_turn_ref () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields -> `Assoc (List.remove_assoc "turn_ref" fields)
    | _ -> fail "to_json did not produce an object"
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded a TurnRecord without its canonical turn_ref"
  | Error msg ->
    check string "missing join identity is explicit"
      "turn_record: missing field \"turn_ref\"" msg

let test_codec_rejects_mismatched_turn_ref () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (( "turn_ref"
         , Ids.Turn_ref.to_yojson
             (Ids.Turn_ref.make ~trace_id:"other-trace" ~absolute_turn:4071) )
         :: List.remove_assoc "turn_ref" fields)
    | _ -> fail "to_json did not produce an object"
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded a turn_ref that contradicts the TurnRecord clock"
  | Error msg ->
    check string "contradictory identity is explicit"
      "turn_record: turn_ref does not match trace_id/absolute_turn" msg

let test_codec_unknown_block_decodes_as_other () =
  let json =
    Turn_record.to_json
      (sample_record
         ~blocks:[ sample_block (Prompt_block_id.Other "future_block") "dddd" ]
         ())
  in
  match Turn_record.of_json json with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    (match decoded.blocks with
     | [ { block; _ } ] ->
       check block_id "forward-open block id" (Prompt_block_id.Other "future_block") block
     | _ -> fail "expected exactly one block")

let test_constructor_and_codec_reject_duplicate_block_ids () =
  let duplicate_blocks =
    [ sample_block Prompt_block_id.Persona "aaaa"
    ; sample_block Prompt_block_id.Persona "bbbb"
    ]
  in
  check_make_error "constructor rejects duplicate id"
    "turn_record: duplicate prompt block id \"persona\""
    (make_sample_record ~blocks:duplicate_blocks ());
  check_make_error "constructor rejects duplicate wire identity"
    "turn_record: duplicate prompt block id \"persona\""
    (make_sample_record
       ~blocks:
         [ sample_block Prompt_block_id.Persona "aaaa"
         ; sample_block (Prompt_block_id.Other "persona") "bbbb"
         ]
       ());
  check_make_error "constructor rejects non-canonical typed id"
    "turn_record: non-canonical prompt block id \"persona\""
    (make_sample_record
       ~blocks:[ sample_block (Prompt_block_id.Other "persona") "bbbb" ]
       ());
  let duplicate_json =
    Turn_record.to_json (sample_record ())
    |> replace_field "blocks"
         (`List (List.map Turn_record.prompt_block_to_json duplicate_blocks))
  in
  match Turn_record.of_json duplicate_json with
  | Ok _ -> fail "closed decoder accepted duplicate prompt block ids"
  | Error reason ->
    check string "decoder rejects duplicate id"
      "turn_record: duplicate prompt block id \"persona\""
      reason

let test_constructor_rejects_invalid_numeric_invariants () =
  let negative_block =
    { Turn_record.block = Prompt_block_id.Persona; bytes = -1; digest = "aaaa" }
  in
  let negative_sampling field =
    match field with
    | `Temperature -> { default_sampling with temperature = Some (-0.1) }
    | `Top_p -> { default_sampling with top_p = Some (-0.1) }
  in
  let invalid_cases =
    [ ( "absolute turn"
      , "turn_record: absolute_turn must be positive"
      , make_sample_record ~absolute_turn:0 () )
    ; ( "empty trace"
      , "turn_record: trace_id must not be empty"
      , make_sample_record ~trace_id:"" () )
    ; ( "block bytes"
      , "turn_record: field \"blocks[].bytes\" must be nonnegative"
      , make_sample_record ~blocks:[ negative_block ] () )
    ; ( "context window"
      , "turn_record: field \"context_window\" must be nonnegative"
      , make_sample_record ~context_window:(Some (-1)) () )
    ; ( "input price finite"
      , "turn_record: field \"price_input_per_million\" must be finite"
      , make_sample_record ~price_input_per_million:(Some Float.nan) () )
    ; ( "output price"
      , "turn_record: field \"price_output_per_million\" must be nonnegative"
      , make_sample_record ~price_output_per_million:(Some (-0.01)) () )
    ; ( "request latency"
      , "turn_record: field \"request_latency_ms\" must be nonnegative"
      , make_sample_record ~request_latency_ms:(Some (-1)) () )
    ; ( "ttfrc finite"
      , "turn_record: field \"ttfrc_ms\" must be finite"
      , make_sample_record ~ttfrc_ms:(Some Float.infinity) () )
    ; ( "temperature"
      , "turn_record: field \"temperature\" must be nonnegative"
      , make_sample_record ~sampling:(negative_sampling `Temperature) () )
    ; ( "top_p"
      , "turn_record: field \"top_p\" must be nonnegative"
      , make_sample_record ~sampling:(negative_sampling `Top_p) () )
    ; ( "max tokens"
      , "turn_record: field \"max_tokens\" must be nonnegative"
      , make_sample_record
          ~sampling:{ default_sampling with max_tokens = Some (-1) }
          () )
    ; ( "thinking budget"
      , "turn_record: field \"thinking_budget\" must be nonnegative"
      , make_sample_record
          ~sampling:{ default_sampling with thinking_budget = Some (-1) }
          () )
    ; ( "input tokens"
      , "turn_record: field \"input_tokens\" must be nonnegative"
      , make_sample_record
          ~usage:{ default_usage with input_tokens = Some (-1) }
          () )
    ; ( "output tokens"
      , "turn_record: field \"output_tokens\" must be nonnegative"
      , make_sample_record
          ~usage:{ default_usage with output_tokens = Some (-1) }
          () )
    ; ( "timestamp finite"
      , "turn_record: field \"ts\" must be finite"
      , make_sample_record ~ts:Float.nan () )
    ; ( "timestamp nonnegative"
      , "turn_record: field \"ts\" must be nonnegative"
      , make_sample_record ~ts:(-0.1) () )
    ]
  in
  List.iter
    (fun (label, expected, result) -> check_make_error label expected result)
    invalid_cases

let test_codec_rejects_invalid_numeric_invariants () =
  let valid = Turn_record.to_json (sample_record ()) in
  let invalid_fields =
    [ "context_window", `Int (-1)
    ; "price_input_per_million", `Float Float.nan
    ; "price_output_per_million", `Float (-0.1)
    ; "request_latency_ms", `Int (-1)
    ; "ttfrc_ms", `Float Float.infinity
    ; "temperature", `Float (-0.1)
    ; "top_p", `Float Float.nan
    ; "max_tokens", `Int (-1)
    ; "thinking_budget", `Int (-1)
    ; "input_tokens", `Int (-1)
    ; "output_tokens", `Int (-1)
    ; "ts", `Float (-0.1)
    ]
  in
  List.iter
    (fun (field, value) ->
      match Turn_record.of_json (replace_field field value valid) with
      | Ok _ -> failf "closed decoder accepted invalid numeric field %s" field
      | Error _ -> ())
    invalid_fields;
  let invalid_block =
    `Assoc
      [ "block", `String "persona"
      ; "bytes", `Int (-1)
      ; "digest", `String "aaaa"
      ]
  in
  match Turn_record.of_json (replace_field "blocks" (`List [ invalid_block ]) valid) with
  | Ok _ -> fail "closed decoder accepted a negative prompt block size"
  | Error reason ->
    check string "decoder routes block numeric validation through constructor"
      "turn_record: field \"blocks[].bytes\" must be nonnegative"
      reason

(* ── Block diff (RFC §5: exact added/removed set) ─────── *)

let record_with_blocks blocks = sample_record ~blocks ()

let test_diff_added_removed_changed () =
  let prev =
    record_with_blocks
      [ sample_block Prompt_block_id.Persona "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Retry_nudge "rrrr"
      ]
  in
  let next =
    record_with_blocks
      [ sample_block Prompt_block_id.Persona "aaaa" (* unchanged *)
      ; sample_block Prompt_block_id.Dynamic_context "BBBB" (* changed *)
      ; sample_block Prompt_block_id.Memory_os_recall "mmmm" (* added *)
      ]
  in
  let diff = Turn_record.diff_blocks ~prev ~next in
  check (list block_id) "added = exactly memory_os_recall"
    [ Prompt_block_id.Memory_os_recall ]
    (List.map (fun (b : Turn_record.prompt_block) -> b.block) diff.added);
  check (list block_id) "removed = exactly retry_nudge"
    [ Prompt_block_id.Retry_nudge ]
    (List.map (fun (b : Turn_record.prompt_block) -> b.block) diff.removed);
  check (list block_id) "changed = exactly dynamic_context"
    [ Prompt_block_id.Dynamic_context ]
    (List.map
       (fun ((_, b) : Turn_record.prompt_block * Turn_record.prompt_block) -> b.block)
       diff.changed)

let test_diff_identical_records_is_empty () =
  let record = sample_record () in
  let diff = Turn_record.diff_blocks ~prev:record ~next:record in
  check int "no added" 0 (List.length diff.added);
  check int "no removed" 0 (List.length diff.removed);
  check int "no changed" 0 (List.length diff.changed)

let test_entries_with_diffs_same_trace_only () =
  let r1 =
    sample_record
      ~trace_id:"trace-A"
      ~absolute_turn:1
      ~blocks:[ sample_block Prompt_block_id.Persona "aaaa" ]
      ()
  in
  let r2 =
    sample_record
      ~trace_id:"trace-A"
      ~absolute_turn:2
      ~blocks:
        [ sample_block Prompt_block_id.Persona "aaaa"
        ; sample_block Prompt_block_id.Retry_nudge "rrrr"
        ]
      ()
  in
  let r3 =
    sample_record
      ~trace_id:"trace-B"
      ~absolute_turn:3
      ~blocks:[ sample_block Prompt_block_id.Persona "zzzz" ]
      ()
  in
  match Turn_record.entries_with_diffs [ r1; r2; r3 ] with
  | [ (_, first); (_, second); (_, third) ] ->
    check bool "first record has no predecessor" true (first = None);
    (match second with
     | Some diff ->
       check (list block_id) "same-trace diff sees the added nudge"
         [ Prompt_block_id.Retry_nudge ]
         (List.map (fun (b : Turn_record.prompt_block) -> b.block) diff.added)
     | None -> fail "expected a diff for the same-trace successor");
    check bool "trace boundary yields no diff" true (third = None)
  | _ -> fail "expected three paired entries"

(* ── Turn_ref (RFC-0233 §7) ───────────────────────────── *)

let turn_ref_t =
  testable (Fmt.of_to_string Ids.Turn_ref.to_string) Ids.Turn_ref.equal

let test_turn_ref_roundtrip () =
  let r =
    Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000" ~absolute_turn:4071
  in
  check string "to_string" "trace-1780648779957-00000#4071"
    (Ids.Turn_ref.to_string r);
  (match Ids.Turn_ref.of_string (Ids.Turn_ref.to_string r) with
   | Some back -> check turn_ref_t "of_string roundtrip" r back
   | None -> fail "of_string returned None on its own output");
  check string "trace_id accessor" "trace-1780648779957-00000"
    (Ids.Turn_ref.trace_id r);
  check int "absolute_turn accessor" 4071 (Ids.Turn_ref.absolute_turn r)

let test_turn_ref_trace_with_hash () =
  (* trace_id containing '#' still parses: split on the LAST '#'. *)
  match Ids.Turn_ref.of_string "weird#trace#12" with
  | Some r ->
    check string "trace keeps inner '#'" "weird#trace" (Ids.Turn_ref.trace_id r);
    check int "turn is the last segment" 12 (Ids.Turn_ref.absolute_turn r)
  | None -> fail "expected Some for a trace_id containing '#'"

let test_turn_ref_rejects_malformed () =
  check bool "no separator -> None" true (Ids.Turn_ref.of_string "noseparator" = None);
  check bool "non-int suffix -> None" true (Ids.Turn_ref.of_string "trace#abc" = None);
  check bool "empty trace -> None" true (Ids.Turn_ref.of_string "#4" = None)

let () =
  run "turn_record"
    [ ( "prompt_block_id"
      , [ test_case "all known constructors roundtrip" `Quick test_block_id_roundtrip
        ; test_case "unknown maps to Other" `Quick test_block_id_unknown_maps_to_other
        ] )
    ; ( "codec"
      , [ test_case "roundtrip" `Quick test_codec_roundtrip
        ; test_case "optional fields absent" `Quick test_codec_optional_fields_absent
        ; test_case "rejects malformed rows" `Quick test_codec_rejects_malformed
        ; test_case "rejects retired execution_ids field" `Quick
            test_codec_rejects_retired_execution_ids
        ; test_case "requires canonical turn_ref" `Quick
            test_codec_requires_turn_ref
        ; test_case "rejects mismatched turn_ref" `Quick
            test_codec_rejects_mismatched_turn_ref
        ; test_case "unknown block decodes as Other" `Quick
            test_codec_unknown_block_decodes_as_other
        ; test_case "constructor/codec reject duplicate block ids" `Quick
            test_constructor_and_codec_reject_duplicate_block_ids
        ; test_case "constructor rejects invalid numeric invariants" `Quick
            test_constructor_rejects_invalid_numeric_invariants
        ; test_case "codec rejects invalid numeric invariants" `Quick
            test_codec_rejects_invalid_numeric_invariants
        ] )
    ; ( "block_diff"
      , [ test_case "exact added/removed/changed sets" `Quick
            test_diff_added_removed_changed
        ; test_case "identical records diff empty" `Quick
            test_diff_identical_records_is_empty
        ; test_case "entries_with_diffs pairs same-trace only" `Quick
            test_entries_with_diffs_same_trace_only
        ] )
    ; ( "turn_ref"
      , [ test_case "make/to_string/of_string roundtrip" `Quick
            test_turn_ref_roundtrip
        ; test_case "trace_id with '#' splits on last separator" `Quick
            test_turn_ref_trace_with_hash
        ; test_case "of_string rejects malformed" `Quick
            test_turn_ref_rejects_malformed
        ] )
    ]
