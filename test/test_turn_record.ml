(** RFC-0233 §5 harness for PR-3: Prompt_block_id round-trip, TurnRecord
    codec round-trip, and block-diff exactness (the "what entered/left
    context" question as a test). *)

open Alcotest

let block_id = testable (Fmt.of_to_string Prompt_block_id.to_string) Prompt_block_id.equal

(* ── Prompt_block_id ──────────────────────────────────── *)

let test_block_id_roundtrip () =
  List.iter
    (fun block ->
      match Prompt_block_id.of_string (Prompt_block_id.to_string block) with
      | Ok decoded ->
        check block_id
          (Printf.sprintf "roundtrip %s" (Prompt_block_id.to_string block))
          block
          decoded
      | Error error -> failf "known prompt block failed: %s" error)
    Prompt_block_id.all

let test_block_id_unknown_fails_closed () =
  match Prompt_block_id.of_string "future_block" with
  | Ok _ -> fail "decoded an unknown prompt block"
  | Error error ->
    check bool "unknown prompt block is explicit" true
      (Astring.String.is_infix ~affix:"future_block" error)

(* ── TurnRecord codec ─────────────────────────────────── *)

let sample_block block digest =
  { Turn_record.block; bytes = String.length digest; digest }

let sample_component component bytes =
  { Turn_record.component = component; bytes }

let sample_record () : Turn_record.t =
  { execution_ids =
      [ Ids.Execution_id.of_string "exec-1781200000000-0001"
      ; Ids.Execution_id.of_string "exec-1781200000001-0002"
      ]
  ; keeper = "sangsu"
  ; trace_id = "trace-1780648779957-00000"
  ; absolute_turn = 4071
  ; turn_ref =
      Ids.Turn_ref.make
        ~trace_id:"trace-1780648779957-00000"
        ~absolute_turn:4071
  ; blocks =
      [ sample_block Prompt_block_id.Persona "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Memory_os_recall "cccc"
      ]
  ; input_components =
      [ sample_component
          (Turn_record.Prompt_block Prompt_block_id.Persona)
          4
      ; sample_component Turn_record.Tool_schemas 2048
      ; sample_component Turn_record.Message_tool_result 512
      ]
  ; runtime_profile = "ollama_cloud.deepseek-v4-flash"
  ; model = Some "deepseek-v4-flash"
  ; finish_reason = Some "completed"
  ; context_window = Some 131072
  ; price_input_per_million = Some 0.15
  ; price_output_per_million = Some 0.6
  ; request_latency_ms = Some 1234
  ; ttfrc_ms = Some 567.8
  ; request_runtime_profile = Some "ollama_cloud.deepseek-v4-flash"
  ; request_body_bytes = Some 560_513
  ; sampling =
      { temperature = Some 0.3
      ; top_p = Some 0.9
      ; max_tokens = Some 8192
      ; thinking_budget = Some 1500
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 18000
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = Some 2048
      ; cache_read_input_tokens = Some 15000
      }
  ; ts = 1781200000.5
  }

(* The cache counts used to be dropped at the writer, so a row with a large
   input_tokens could not be read as either a cache-heavy turn or a genuinely large
   prompt. context_window denominates the ctx-fill percentage against the compaction
   ceiling, so those two situations look identical on a dashboard while calling for
   different action. A current turn whose provider reports no cache usage omits
   them and decodes to None rather than a fabricated zero. *)
let test_cache_counts_round_trip_and_stay_optional () =
  let record = sample_record () in
  (match Turn_record.of_json (Turn_record.to_json record) with
   | Error e -> failf "decode failed: %s" e
   | Ok decoded ->
     check (option int) "cache creation survives" (Some 2048)
       decoded.usage.cache_creation_input_tokens;
     check (option int) "cache read survives" (Some 15000)
       decoded.usage.cache_read_input_tokens);
  let without_cache_usage =
    match Turn_record.to_json record with
    | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (k, _) ->
             k <> "cache_creation_input_tokens" && k <> "cache_read_input_tokens")
           fields)
    | other -> other
  in
  match Turn_record.of_json without_cache_usage with
  | Error e -> failf "row without provider cache usage failed to decode: %s" e
  | Ok decoded ->
    check (option int) "absent cache creation decodes as None" None
      decoded.usage.cache_creation_input_tokens;
    check (option int) "absent cache read decodes as None" None
      decoded.usage.cache_read_input_tokens;
    check (option int) "the rest of the row is unaffected" (Some 18000)
      decoded.usage.input_tokens
;;

let test_codec_roundtrip () =
  let record = sample_record () in
  match Turn_record.of_json (Turn_record.to_json record) with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check int "execution_ids count" 2 (List.length decoded.execution_ids);
    check bool "execution_ids preserved" true
      (List.for_all2 Ids.Execution_id.equal record.execution_ids
         decoded.execution_ids);
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
    check (list string) "input component ids preserved in order"
      (List.map
         (fun (component : Turn_record.input_component) ->
           Turn_record.input_component_id_to_string component.component)
         record.input_components)
      (List.map
         (fun (component : Turn_record.input_component) ->
           Turn_record.input_component_id_to_string component.component)
         decoded.input_components);
    check (list int) "input component bytes preserved"
      (List.map
         (fun (component : Turn_record.input_component) -> component.bytes)
         record.input_components)
      (List.map
         (fun (component : Turn_record.input_component) -> component.bytes)
         decoded.input_components);
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
    check (option string) "request runtime profile round-trip"
      record.request_runtime_profile decoded.request_runtime_profile;
    check (option int) "request_body_bytes round-trip"
      record.request_body_bytes decoded.request_body_bytes;
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
    { (sample_record ()) with
      model = None
    ; finish_reason = None
    ; context_window = None
    ; price_input_per_million = None
    ; price_output_per_million = None
    ; request_latency_ms = None
    ; ttfrc_ms = None
    ; request_runtime_profile = None
    ; request_body_bytes = None
    ; sampling =
        { temperature = None
        ; top_p = None
        ; max_tokens = None
        ; thinking_budget = None
        ; enable_thinking = None
        }
    ; usage =
        { input_tokens = None
        ; output_tokens = None
        ; cache_creation_input_tokens = None
        ; cache_read_input_tokens = None
        }
    }
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
       (List.mem_assoc "ttfrc_ms" fields);
     check bool "request_body_bytes key remains required" true
       (List.mem_assoc "request_body_bytes" fields);
     check bool "request_body_bytes None is explicit null" true
       (List.assoc_opt "request_body_bytes" fields = Some `Null);
     check bool "request_runtime_profile key remains required" true
       (List.mem_assoc "request_runtime_profile" fields);
     check bool "request_runtime_profile None is explicit null" true
       (List.assoc_opt "request_runtime_profile" fields = Some `Null)
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
    check (option int) "request body observation absent" None
      decoded.request_body_bytes;
    check (option string) "request runtime profile absent" None
      decoded.request_runtime_profile;
    check (option (float 0.0001)) "temperature absent" None
      decoded.sampling.temperature;
    check (option (float 0.0001)) "top_p absent" None decoded.sampling.top_p;
    check (option int) "max_tokens absent" None decoded.sampling.max_tokens;
    check (option int) "input_tokens absent" None decoded.usage.input_tokens

let test_codec_rejects_malformed () =
  (match Turn_record.of_json (`String "not a record") with
   | Ok _ -> fail "decoded a non-object"
   | Error _ -> ());
  match Turn_record.of_json (`Assoc [ ("keeper", `String "x") ]) with
  | Ok _ -> fail "decoded a row with missing fields"
  | Error msg ->
    check bool "error names the missing field" true
      (Astring.String.is_infix ~affix:"execution_ids" msg)

let test_codec_requires_current_input_composition () =
  let without_components =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc (List.remove_assoc "input_components" fields)
    | other -> other
  in
  match Turn_record.of_json without_components with
  | Ok _ -> fail "decoded a row without current input composition"
  | Error msg ->
    check bool "missing current field is explicit" true
      (Astring.String.is_infix ~affix:"input_components" msg)

let test_codec_requires_turn_ref () =
  let without_turn_ref =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields -> `Assoc (List.remove_assoc "turn_ref" fields)
    | other -> other
  in
  match Turn_record.of_json without_turn_ref with
  | Ok _ -> fail "decoded a row without current turn_ref"
  | Error msg ->
    check bool "missing current field is explicit" true
      (Astring.String.is_infix ~affix:"turn_ref" msg)

let test_codec_rejects_mismatched_turn_ref () =
  let mismatched =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        ( ( "turn_ref"
          , Ids.Turn_ref.to_yojson
              (Ids.Turn_ref.make ~trace_id:"other-trace" ~absolute_turn:9) )
        :: List.remove_assoc "turn_ref" fields )
    | other -> other
  in
  match Turn_record.of_json mismatched with
  | Ok _ -> fail "decoded a turn_ref that disagrees with its source fields"
  | Error msg ->
    check bool "mismatched derived field is explicit" true
      (Astring.String.is_infix ~affix:"does not match" msg)

let test_codec_requires_current_request_body_observation () =
  let without_request_body_bytes =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc (List.remove_assoc "request_body_bytes" fields)
    | other -> other
  in
  match Turn_record.of_json without_request_body_bytes with
  | Ok _ -> fail "decoded a row without current request body observation"
  | Error msg ->
    check bool "missing current field is explicit" true
      (Astring.String.is_infix ~affix:"request_body_bytes" msg)

let test_codec_requires_current_request_runtime_profile () =
  let without_request_runtime_profile =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc (List.remove_assoc "request_runtime_profile" fields)
    | other -> other
  in
  match Turn_record.of_json without_request_runtime_profile with
  | Ok _ -> fail "decoded a row without current request runtime attribution"
  | Error msg ->
    check bool "missing current field is explicit" true
      (Astring.String.is_infix ~affix:"request_runtime_profile" msg)

let test_codec_rejects_invalid_request_body_observation () =
  let with_request_body_bytes value =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (("request_body_bytes", value)
         :: List.remove_assoc "request_body_bytes" fields)
    | other -> other
  in
  List.iter
    (fun value ->
      match Turn_record.of_json (with_request_body_bytes value) with
      | Ok _ -> fail "decoded an invalid request body observation"
      | Error msg ->
        check bool "invalid current field is explicit" true
          (Astring.String.is_infix ~affix:"request_body_bytes" msg))
    [ `Int (-1); `String "560513" ]

let test_codec_rejects_unknown_input_component () =
  let with_component component =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        ( ( "input_components"
          , `List
              [ `Assoc
                  [ "component", `String component
                  ; "bytes", `Int 1
                  ]
              ] )
        :: List.remove_assoc "input_components" fields )
    | other -> other
  in
  List.iter
    (fun (component, error_token) ->
      match Turn_record.of_json (with_component component) with
      | Ok _ -> failf "decoded unknown input component %s" component
      | Error msg ->
        check bool "unknown component is explicit" true
          (Astring.String.is_infix ~affix:error_token msg))
    [ "history_guess", "history_guess"
    ; "prompt.future_block", "future_block"
    ]

let test_codec_unknown_block_fails_closed () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        ( ( "blocks"
          , `List
              [ `Assoc
                  [ "block", `String "future_block"
                  ; "bytes", `Int 4
                  ; "digest", `String "dddd"
                  ]
              ] )
        :: List.remove_assoc "blocks" fields )
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded an unknown prompt block"
  | Error error ->
    check bool "unknown prompt block is explicit" true
      (Astring.String.is_infix ~affix:"future_block" error)

(* ── Block diff (RFC §5: exact added/removed set) ─────── *)

let record_with_blocks blocks = { (sample_record ()) with blocks }

let test_diff_added_removed_changed () =
  let prev =
    record_with_blocks
      [ sample_block Prompt_block_id.Persona "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Temporal_summary "tttt"
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
  check (list block_id) "removed = exactly temporal_summary"
    [ Prompt_block_id.Temporal_summary ]
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
    { (record_with_blocks [ sample_block Prompt_block_id.Persona "aaaa" ]) with
      trace_id = "trace-A"
    ; absolute_turn = 1
    }
  in
  let r2 =
    { (record_with_blocks
         [ sample_block Prompt_block_id.Persona "aaaa"
         ; sample_block Prompt_block_id.Memory_os_recall "mmmm"
         ])
      with
      trace_id = "trace-A"
    ; absolute_turn = 2
    }
  in
  let r3 =
    { (record_with_blocks [ sample_block Prompt_block_id.Persona "zzzz" ]) with
      trace_id = "trace-B" (* new generation: diff must be None *)
    ; absolute_turn = 3
    }
  in
  match Turn_record.entries_with_diffs [ r1; r2; r3 ] with
  | [ (_, first); (_, second); (_, third) ] ->
    check bool "first record has no predecessor" true (first = None);
    (match second with
     | Some diff ->
       check (list block_id) "same-trace diff sees the added recall block"
         [ Prompt_block_id.Memory_os_recall ]
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
        ; test_case "unknown fails closed" `Quick
            test_block_id_unknown_fails_closed
        ] )
    ; ( "codec"
      , [ test_case "roundtrip" `Quick test_codec_roundtrip
        ; test_case "cache counts round-trip and stay optional" `Quick
            test_cache_counts_round_trip_and_stay_optional
        ; test_case "optional fields absent" `Quick test_codec_optional_fields_absent
        ; test_case "rejects malformed rows" `Quick test_codec_rejects_malformed
        ; test_case "current input composition required" `Quick
            test_codec_requires_current_input_composition
        ; test_case "turn_ref required" `Quick test_codec_requires_turn_ref
        ; test_case "mismatched turn_ref rejected" `Quick
            test_codec_rejects_mismatched_turn_ref
        ; test_case "current request body observation required" `Quick
            test_codec_requires_current_request_body_observation
        ; test_case "current request runtime attribution required" `Quick
            test_codec_requires_current_request_runtime_profile
        ; test_case "invalid request body observation rejected" `Quick
            test_codec_rejects_invalid_request_body_observation
        ; test_case "unknown input component rejected" `Quick
            test_codec_rejects_unknown_input_component
        ; test_case "unknown prompt block rejected" `Quick
            test_codec_unknown_block_fails_closed
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
