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

let sample_record () : Turn_record.t =
  { execution_ids =
      [ Ids.Execution_id.of_string "exec-1781200000000-0001"
      ; Ids.Execution_id.of_string "exec-1781200000001-0002"
      ]
  ; keeper = "sangsu"
  ; trace_id = "trace-1780648779957-00000"
  ; absolute_turn = 4071
  ; blocks =
      [ sample_block Prompt_block_id.Persona "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Memory_os_recall "cccc"
      ]
  ; runtime_profile = "ollama_cloud.deepseek-v4-flash"
  ; sampling =
      { temperature = Some 0.3; thinking_budget = Some 1500; enable_thinking = Some true }
  ; usage = { input_tokens = Some 18000; output_tokens = Some 412 }
  ; ts = 1781200000.5
  }

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
    check int "blocks count" 3 (List.length decoded.blocks);
    check bool "blocks preserved in order" true
      (List.for_all2
         (fun (a : Turn_record.prompt_block) (b : Turn_record.prompt_block) ->
           Prompt_block_id.equal a.block b.block
           && a.bytes = b.bytes
           && String.equal a.digest b.digest)
         record.blocks decoded.blocks);
    check string "runtime_profile" record.runtime_profile decoded.runtime_profile;
    check (option (float 0.0001)) "temperature" record.sampling.temperature
      decoded.sampling.temperature;
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
      sampling = { temperature = None; thinking_budget = None; enable_thinking = None }
    ; usage = { input_tokens = None; output_tokens = None }
    }
  in
  match Turn_record.of_json (Turn_record.to_json record) with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check (option (float 0.0001)) "temperature absent" None
      decoded.sampling.temperature;
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

let test_codec_unknown_block_decodes_as_other () =
  let json =
    Turn_record.to_json
      { (sample_record ()) with
        blocks = [ sample_block (Prompt_block_id.Other "future_block") "dddd" ]
      }
  in
  match Turn_record.of_json json with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    (match decoded.blocks with
     | [ { block; _ } ] ->
       check block_id "forward-open block id" (Prompt_block_id.Other "future_block") block
     | _ -> fail "expected exactly one block")

(* ── Block diff (RFC §5: exact added/removed set) ─────── *)

let record_with_blocks blocks = { (sample_record ()) with blocks }

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
        ; test_case "unknown block decodes as Other" `Quick
            test_codec_unknown_block_decodes_as_other
        ] )
    ; ( "block_diff"
      , [ test_case "exact added/removed/changed sets" `Quick
            test_diff_added_removed_changed
        ; test_case "identical records diff empty" `Quick
            test_diff_identical_records_is_empty
        ] )
    ]
