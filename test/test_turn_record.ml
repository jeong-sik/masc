(** RFC-0233 §5 harness for PR-3: Prompt_block_id round-trip, TurnRecord
    codec round-trip, and block-diff exactness (the "what entered/left
    context" question as a test). *)

open Alcotest

let block_id = testable (Fmt.of_to_string Prompt_block_id.to_string) Prompt_block_id.equal
let turn_ref_t =
  testable (Fmt.of_to_string Ids.Turn_ref.to_string) Ids.Turn_ref.equal

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
      | Error error -> failf "current block failed to decode: %s" error)
    Prompt_block_id.all_known

let test_block_id_unknown_rejected () =
  match Prompt_block_id.of_string "future_block" with
  | Ok _ -> fail "decoded an unknown block id"
  | Error message ->
    check bool "unknown block id is explicit" true
      (Astring.String.is_infix ~affix:"unknown prompt block id" message)

(* Recurring world-state blocks stay on the first provider round of a turn;
   only a genuine mid-turn message (the operator note) rides a post-tool
   round. Pinned per constructor so a new block declares its class rather
   than inheriting one (task-514). *)
let test_block_id_post_tool_round_classes () =
  List.iter
    (fun (block, expected) ->
      check bool
        (Printf.sprintf "post-tool class of %s" (Prompt_block_id.to_string block))
        expected
        (Prompt_block_id.injected_on_post_tool_round block))
    [ (Prompt_block_id.Keeper_instructions, true)
    ; (Prompt_block_id.Dynamic_context, false)
    ; (Prompt_block_id.Temporal_summary, false)
    ; (Prompt_block_id.Memory_os_recall, false)
    ; (Prompt_block_id.Operator_note, true)
    ]

(* ── TurnRecord codec ─────────────────────────────────── *)

let digest_of_label label =
  Digestif.SHA256.digest_string label |> Digestif.SHA256.to_hex

let sample_block block label =
  { Turn_record.block
  ; bytes = String.length label
  ; digest = digest_of_label label
  }

let input_components_or_fail = function
  | Some components -> components
  | None -> fail "expected available input components"

let sample_record () : Turn_record.t =
  { execution_ids =
      [ Ids.Execution_id.of_string "exec-1781200000000-0001"
      ; Ids.Execution_id.of_string "exec-1781200000001-0002"
      ]
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = "trace-1780648779957-00000"
  ; absolute_turn = 4071
  ; turn_ref =
      Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000" ~absolute_turn:4071
  ; blocks =
      [ sample_block Prompt_block_id.Keeper_instructions "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Memory_os_recall "cccc"
      ]
  ; input_components =
      Some
        [ { component = Turn_record.Prompt_block Prompt_block_id.Keeper_instructions
          ; bytes = 4
          }
        ; { component = Turn_record.Tool_schemas; bytes = 8192 }
        ; { component = Turn_record.Message_user; bytes = 256 }
        ]
  ; tool_surface_ref = None
  ; runtime_profile = "ollama_cloud.deepseek-v4-flash"
  ; selected_model = Some "deepseek-v4-flash"
  ; finish_reason = Some "completed"
  ; context_window = Some 131072
  ; price_input_per_million = Some 0.15
  ; price_output_per_million = Some 0.6
  ; request_latency_ms = Some 1234
  ; ttfrc_ms = Some 567.8
  ; request_wire_observation =
      Some
        { runtime_profile = "ollama_cloud.deepseek-v4-flash"
        ; body_bytes = 560_513
        }
  ; model_input_window = Some { transmitted_atoms = 15; total_atoms = 7_706; measurement = Wire_shape }
  ; raw_trace_run_ref =
      Some
        { worker_run_id = "worker-run-41"
        ; path = "/tmp/turn-record-test.jsonl"
        ; start_seq = 8
        ; end_seq = 15
        ; agent_name = "agent_core-test-runtime"
        ; session_id = "trace-1780648779957-00000"
        }
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
      ; scope = Runtime_usage_scope.Per_request
      }
  ; ts = 1781200000.5
  }

(* Cache counts distinguish a cache-heavy turn from a genuinely large prompt.
   A current provider may omit those usage values; absence stays [None] rather
   than becoming a fabricated zero. *)
(* [input_components] says the tool schemas cost N bytes; this says which
   tools they were, which N alone can never recover. The value is the
   canonical marker for a content-addressed blob, so what has to survive the
   round trip is the marker text exactly -- a re-encoded or trimmed marker
   would not resolve, and the blob maintenance scan would stop counting the
   record as a reference and collect the bytes it points at. *)
let test_tool_surface_ref_round_trips_and_stays_optional () =
  (* Built through the codec that owns the grammar, not spelled here: a
     hand-typed marker would round-trip through JSON just as happily while
     resolving to nothing, and this test would still pass. *)
  let marker =
    match
      Tool_output.make_artifact_ref ~sha256:(String.make 64 'a') ~bytes:12
        ~preview:"[{\"name\"" ~mime:"application/json"
    with
    | Ok reference ->
        Tool_output.encode_for_agent_core (Tool_output.Stored reference)
    | Error error -> failf "%s" (Tool_output.make_error_to_string error)
  in
  let record = { (sample_record ()) with tool_surface_ref = Some marker } in
  (match Turn_record.of_json (Turn_record.to_json record) with
   | Error e -> failf "decode failed: %s" e
   | Ok decoded ->
     check (option string) "the marker survives byte for byte" (Some marker)
       decoded.tool_surface_ref);
  match Turn_record.of_json (Turn_record.to_json (sample_record ())) with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check (option string) "a turn that recorded no surface stays absent" None
      decoded.tool_surface_ref
;;

(* The keeper writes this payload into the blob and the context inspector
   reads it back in a different binary. They agree only because both go
   through the codec declared here; this pins that the codec is in fact a
   round trip, and that a listing with one bad entry fails whole rather than
   arriving short. A short listing would understate the surface, which is the
   one number the reader exists to report. *)
let test_the_tool_surface_payload_round_trips () =
  let entries =
    [ { Turn_record.name = "masc_schedule_create"; schema_bytes = 4093 }
    ; { Turn_record.name = "masc_gc"; schema_bytes = 0 }
    ]
  in
  (match
     Turn_record.tool_surface_of_json (Turn_record.tool_surface_to_json entries)
   with
   | Error detail -> failf "decode failed: %s" detail
   | Ok decoded ->
       check int "every entry survives" 2 (List.length decoded);
       check string "the first name survives" "masc_schedule_create"
         (List.hd decoded).Turn_record.name;
       check int "a zero-byte schema is a size, not an absence" 0
         (List.nth decoded 1).Turn_record.schema_bytes);
  check bool "an empty surface decodes as an empty surface" true
    (Turn_record.tool_surface_of_json (Turn_record.tool_surface_to_json [])
     = Ok []);
  List.iter
    (fun (label, json) ->
       check bool label true
         (Result.is_error (Turn_record.tool_surface_of_json json)))
    [ ( "a nameless entry fails the listing"
      , `List [ `Assoc [ "schema_bytes", `Int 4 ] ] )
    ; ( "an empty name fails the listing"
      , `List [ `Assoc [ "name", `String ""; "schema_bytes", `Int 4 ] ] )
    ; ( "a negative size fails the listing"
      , `List [ `Assoc [ "name", `String "t"; "schema_bytes", `Int (-1) ] ] )
    ; ("a non-array payload fails", `Assoc [ "name", `String "t" ])
    ]
;;

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

let test_historical_row_without_usage_scope_is_unavailable () =
  let historical =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields -> `Assoc (List.remove_assoc "usage_scope" fields)
    | other -> other
  in
  match Turn_record.of_json historical with
  | Error detail -> failf "historical row failed to decode: %s" detail
  | Ok decoded ->
    check bool
      "missing scope is not guessed"
      true
      (decoded.usage.scope = Runtime_usage_scope.Usage_scope_unavailable)
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
    check string "agent_name" record.agent_name decoded.agent_name;
    check string "turn_kind" (Turn_record.turn_kind_to_string record.turn_kind)
      (Turn_record.turn_kind_to_string decoded.turn_kind);
    check string "trace_id" record.trace_id decoded.trace_id;
    check int "absolute_turn" record.absolute_turn decoded.absolute_turn;
    check turn_ref_t "turn_ref preserved" record.turn_ref decoded.turn_ref;
    check int "blocks count" 3 (List.length decoded.blocks);
    check bool "blocks preserved in order" true
      (List.for_all2
         (fun (a : Turn_record.prompt_block) (b : Turn_record.prompt_block) ->
           Prompt_block_id.equal a.block b.block
           && a.bytes = b.bytes
           && String.equal a.digest b.digest)
         record.blocks decoded.blocks);
    check (list string) "input component ids preserved"
      (List.map
         (fun (component : Turn_record.input_component) ->
            Turn_record.input_component_id_to_string component.component)
         (input_components_or_fail record.input_components))
      (List.map
         (fun (component : Turn_record.input_component) ->
            Turn_record.input_component_id_to_string component.component)
         (input_components_or_fail decoded.input_components));
    check (list int) "input component bytes preserved"
      (List.map
         (fun (component : Turn_record.input_component) -> component.bytes)
         (input_components_or_fail record.input_components))
      (List.map
         (fun (component : Turn_record.input_component) -> component.bytes)
         (input_components_or_fail decoded.input_components));
    check string "runtime_profile" record.runtime_profile decoded.runtime_profile;
    check (option string) "selected_model" record.selected_model decoded.selected_model;
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
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.runtime_profile)
         record.request_wire_observation)
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.runtime_profile)
         decoded.request_wire_observation);
    check (option int) "request body bytes round-trip"
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.body_bytes)
         record.request_wire_observation)
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.body_bytes)
         decoded.request_wire_observation);
    check (option string) "exact raw trace run survives"
      (Option.map
         (fun (run_ref : Turn_record.raw_trace_run_ref) -> run_ref.worker_run_id)
         record.raw_trace_run_ref)
      (Option.map
         (fun (run_ref : Turn_record.raw_trace_run_ref) -> run_ref.worker_run_id)
         decoded.raw_trace_run_ref);
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
      selected_model = None
    ; finish_reason = None
    ; context_window = None
    ; price_input_per_million = None
    ; price_output_per_million = None
    ; request_latency_ms = None
    ; ttfrc_ms = None
    ; request_wire_observation = None
    ; model_input_window = None
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
        ; scope = Runtime_usage_scope.Usage_scope_unavailable
        }
    }
  in
  let json = Turn_record.to_json record in
  (* RFC-0233 §2.3/§8: absent meta fields are omitted from the wire, never
     emitted as a fabricated value (no "stop", no placeholder selected model, no
     fabricated 200K window or Claude $3/$15 price). *)
  (match json with
   | `Assoc fields ->
     check bool "finish_reason key omitted when None" false
       (List.mem_assoc "finish_reason" fields);
     check bool "selected_model key omitted when None" false
       (List.mem_assoc "selected_model" fields);
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
     check bool "request runtime key required" true
       (List.mem_assoc "request_runtime_profile" fields);
     check bool "request runtime None is explicit null" true
       (List.assoc_opt "request_runtime_profile" fields = Some `Null);
     check bool "request bytes key required" true
       (List.mem_assoc "request_body_bytes" fields);
     check bool "request bytes None is explicit null" true
       (List.assoc_opt "request_body_bytes" fields = Some `Null)
   | _ -> fail "to_json did not produce an object");
  match Turn_record.of_json json with
  | Error e -> failf "decode failed: %s" e
  | Ok decoded ->
    check (option string) "selected_model absent stays None" None
      decoded.selected_model;
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
    check (option string) "request runtime absent" None
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.runtime_profile)
         decoded.request_wire_observation);
    check (option int) "request bytes absent" None
      (Option.map
         (fun (observation : Turn_record.request_wire_observation) ->
           observation.body_bytes)
         decoded.request_wire_observation);
    check (option (float 0.0001)) "temperature absent" None
      decoded.sampling.temperature;
    check (option (float 0.0001)) "top_p absent" None decoded.sampling.top_p;
    check (option int) "max_tokens absent" None decoded.sampling.max_tokens;
    check (option int) "input_tokens absent" None decoded.usage.input_tokens;
    check turn_ref_t "required turn_ref remains exact" record.turn_ref
      decoded.turn_ref

let test_codec_rejects_malformed () =
  (match Turn_record.of_json (`String "not a record") with
   | Ok _ -> fail "decoded a non-object"
   | Error _ -> ());
  (match Turn_record.to_json (sample_record ()) with
   | `Assoc fields ->
     let blank_selected_model =
       `Assoc
         (("selected_model", `String " ")
          :: List.remove_assoc "selected_model" fields)
     in
     (match Turn_record.of_json blank_selected_model with
      | Ok _ -> fail "decoded a blank selected_model"
      | Error message ->
        check bool "blank selected_model is explicit" true
          (Astring.String.is_infix ~affix:"selected_model" message))
   | _ -> fail "sample turn record is not an object");
  match Turn_record.of_json (`Assoc [ ("keeper", `String "x") ]) with
  | Ok _ -> fail "decoded a row with missing fields"
  | Error msg ->
    check bool "error names the missing field" true
      (Astring.String.is_infix ~affix:"execution_ids" msg)

let test_codec_requires_current_observation_fields () =
  let remove field =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields -> `Assoc (List.remove_assoc field fields)
    | other -> other
  in
  List.iter
    (fun field ->
      match Turn_record.of_json (remove field) with
      | Ok _ -> failf "decoded a row without %s" field
      | Error message ->
        check bool "missing current field is explicit" true
          (Astring.String.is_infix ~affix:field message))
    [ "turn_ref"
    ; "agent_name"
    ; "turn_kind"
    ; "raw_trace_run_ref"
    ; "input_components"
    ; "request_runtime_profile"
    ; "request_body_bytes"
    ; "transmitted_atoms"
    ; "total_atoms"
    ]

(* The record has to carry how much of its own history the turn transmitted,
   because nothing downstream can recover it: the request itself keeps no trace
   of what was cut. *)
let test_record_carries_transmitted_history_share () =
  let record =
    { (sample_record ()) with
      Turn_record.model_input_window =
        Some
          { Turn_record.transmitted_atoms = 7
          ; total_atoms = 7_700
          ; measurement = Wire_shape
          }
    }
  in
  match Turn_record.of_json (Turn_record.to_json record) with
  | Error message -> failf "roundtrip rejected the share: %s" message
  | Ok decoded ->
    (match decoded.Turn_record.model_input_window with
     | None -> failf "roundtrip dropped the share"
     | Some window ->
       check int "transmitted survives" 7 window.Turn_record.transmitted_atoms;
       check int "total survives" 7_700 window.Turn_record.total_atoms)

(* A share above 1 is not a large number, it is a contradiction: the reader
   would render a keeper transmitting more history than it holds. *)
let test_codec_rejects_transmitting_more_than_held () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (("transmitted_atoms", `Int 9)
         :: ("total_atoms", `Int 8)
         :: List.remove_assoc "transmitted_atoms"
              (List.remove_assoc "total_atoms" fields))
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> failf "decoded a row transmitting more atoms than it held"
  | Error message ->
    check bool "error names the contradiction" true
      (Astring.String.is_infix ~affix:"transmitted_atoms" message)

(* Half an observation is not an observation. Accepting one side would let the
   reader compute a share against a fabricated denominator. *)
let test_codec_rejects_half_an_observation () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (("transmitted_atoms", `Int 7)
         :: ("total_atoms", `Null)
         :: List.remove_assoc "transmitted_atoms"
              (List.remove_assoc "total_atoms" fields))
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> failf "decoded a row with only one of the two counts"
  | Error message ->
    check bool "error says both or neither" true
      (Astring.String.is_infix ~affix:"total_atoms" message)

let test_codec_rejects_mismatched_turn_ref () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (("turn_ref", `String "different-trace#4071")
         :: List.remove_assoc "turn_ref" fields)
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded a turn_ref that disagrees with row identity"
  | Error message ->
    check bool "turn_ref mismatch is explicit" true
      (Astring.String.is_infix ~affix:"does not match" message)

let test_codec_rejects_mismatched_raw_trace_session () =
  let replace_run_ref_field field value =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      let run_ref =
        match List.assoc "raw_trace_run_ref" fields with
        | `Assoc run_ref_fields ->
          `Assoc ((field, value) :: List.remove_assoc field run_ref_fields)
        | _ -> fail "sample raw trace run ref is not an object"
      in
      `Assoc
        (("raw_trace_run_ref", run_ref)
         :: List.remove_assoc "raw_trace_run_ref" fields)
    | other -> other
  in
  match
    Turn_record.of_json
      (replace_run_ref_field "session_id" (`String "different-trace"))
  with
  | Ok _ -> fail "decoded mismatched raw trace session_id"
  | Error message ->
    check bool "raw trace session mismatch is explicit" true
      (Astring.String.is_infix ~affix:"session_id does not match" message)

let test_codec_rejects_partial_or_invalid_request_wire_observation () =
  let replace fields =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc current ->
      `Assoc
        (List.fold_left
           (fun acc (name, value) ->
             (name, value) :: List.remove_assoc name acc)
           current
           fields)
    | other -> other
  in
  List.iter
    (fun fields ->
      match Turn_record.of_json (replace fields) with
      | Ok _ -> fail "decoded an invalid request wire observation"
      | Error _ -> ())
    [ [ "request_runtime_profile", `Null ]
    ; [ "request_body_bytes", `Null ]
    ; [ "request_runtime_profile", `String "" ]
    ; [ "request_body_bytes", `Int (-1) ]
    ]

let test_codec_rejects_unknown_input_component () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (( "input_components"
         , `List
             [ `Assoc
                 [ "component", `String "history_guess"
                 ; "bytes", `Int 1
                 ]
             ] )
         :: List.remove_assoc "input_components" fields)
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded an unknown input component"
  | Error message ->
    check bool "unknown component is explicit" true
      (Astring.String.is_infix ~affix:"unknown input component" message)

let test_codec_rejects_input_component_extra_field () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (( "input_components"
         , `List
             [ `Assoc
                 [ "component", `String "tool_schemas"
                 ; "bytes", `Int 1
                 ; "estimated", `Bool true
                 ]
             ] )
         :: List.remove_assoc "input_components" fields)
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded an input component with an extra field"
  | Error message ->
    check bool "extra field is explicit" true
      (Astring.String.is_infix ~affix:"fields are not exact" message)

let test_codec_preserves_explicit_unavailable_input_components () =
  let record = { (sample_record ()) with input_components = None } in
  let json = Turn_record.to_json record in
  (match json with
   | `Assoc fields ->
     check bool "unavailable is serialized as null" true
       (List.assoc_opt "input_components" fields = Some `Null)
   | _ -> fail "record did not encode as an object");
  match Turn_record.of_json json with
  | Error message -> failf "explicit unavailable failed to decode: %s" message
  | Ok decoded ->
    check bool "unavailable survives round-trip" true
      (decoded.input_components = None)

let replace_blocks blocks =
  match Turn_record.to_json (sample_record ()) with
  | `Assoc fields ->
    `Assoc (("blocks", `List blocks) :: List.remove_assoc "blocks" fields)
  | other -> other

let valid_block_json ?(bytes = 4) ?(digest = digest_of_label "block") block =
  `Assoc
    [ "block", `String (Prompt_block_id.to_string block)
    ; "bytes", `Int bytes
    ; "digest", `String digest
    ]

let test_codec_rejects_malformed_blocks () =
  let cases =
    [ ( "negative bytes"
      , valid_block_json ~bytes:(-1) Prompt_block_id.Keeper_instructions )
    ; ( "non-sha256 digest"
      , valid_block_json ~digest:"abcd" Prompt_block_id.Keeper_instructions )
    ; ( "uppercase digest"
      , valid_block_json
          ~digest:(String.make 64 'A')
          Prompt_block_id.Keeper_instructions )
    ]
  in
  List.iter
    (fun (label, block) ->
      match Turn_record.of_json (replace_blocks [ block ]) with
      | Ok _ -> failf "decoded block with %s" label
      | Error _ -> ())
    cases

let test_codec_rejects_duplicate_blocks_and_components () =
  let keeper_instructions = valid_block_json Prompt_block_id.Keeper_instructions in
  (match Turn_record.of_json (replace_blocks [ keeper_instructions; keeper_instructions ]) with
   | Ok _ -> fail "decoded duplicate prompt blocks"
   | Error message ->
     check bool "duplicate block is explicit" true
       (Astring.String.is_infix ~affix:"duplicate block" message));
  let duplicate_components =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      let tool_schema =
        `Assoc
          [ "component", `String "tool_schemas"
          ; "bytes", `Int 1
          ]
      in
      `Assoc
        (( "input_components"
         , `List [ tool_schema; tool_schema ] )
         :: List.remove_assoc "input_components" fields)
    | other -> other
  in
  match Turn_record.of_json duplicate_components with
  | Ok _ -> fail "decoded duplicate input components"
  | Error message ->
    check bool "duplicate component is explicit" true
      (Astring.String.is_infix ~affix:"duplicate input component" message)

let test_codec_rejects_unknown_block () =
  let json =
    match Turn_record.to_json (sample_record ()) with
    | `Assoc fields ->
      `Assoc
        (( "blocks"
         , `List
             [ `Assoc
                 [ "block", `String "future_block"
                 ; "bytes", `Int 4
                 ; "digest", `String (digest_of_label "dddd")
                 ]
             ] )
         :: List.remove_assoc "blocks" fields)
    | other -> other
  in
  match Turn_record.of_json json with
  | Ok _ -> fail "decoded a prompt block without a current producer"
  | Error message ->
    check bool "unknown block is explicit" true
      (Astring.String.is_infix ~affix:"future_block" message)

let test_codec_rejects_unknown_fields () =
  let record_json = Turn_record.to_json (sample_record ()) in
  let with_unknown_record_field =
    match record_json with
    | `Assoc fields -> `Assoc (("model", `String "runtime") :: fields)
    | other -> other
  in
  (match Turn_record.of_json with_unknown_record_field with
   | Ok _ -> fail "decoded a turn record with an unknown field"
   | Error message ->
     check bool "record field rejection is explicit" true
       (Astring.String.is_infix ~affix:"fields are not exact" message));
  let with_unknown_block_field =
    match record_json with
    | `Assoc fields ->
      let blocks =
        match List.assoc "blocks" fields with
        | `List (`Assoc block_fields :: rest) ->
          `List (`Assoc (("retired_rank", `Int 1) :: block_fields) :: rest)
        | other -> other
      in
      `Assoc (("blocks", blocks) :: List.remove_assoc "blocks" fields)
    | other -> other
  in
  match Turn_record.of_json with_unknown_block_field with
  | Ok _ -> fail "decoded a prompt block with an unknown field"
  | Error message ->
    check bool "block field rejection is explicit" true
      (Astring.String.is_infix ~affix:"prompt block fields are not exact" message)
;;

(* ── Block diff (RFC §5: exact added/removed set) ─────── *)

let record_with_blocks blocks = { (sample_record ()) with blocks }

let test_diff_added_removed_changed () =
  let prev =
    record_with_blocks
      [ sample_block Prompt_block_id.Keeper_instructions "aaaa"
      ; sample_block Prompt_block_id.Dynamic_context "bbbb"
      ; sample_block Prompt_block_id.Temporal_summary "rrrr"
      ]
  in
  let next =
    record_with_blocks
      [ sample_block Prompt_block_id.Keeper_instructions "aaaa" (* unchanged *)
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
    { (record_with_blocks [ sample_block Prompt_block_id.Keeper_instructions "aaaa" ]) with
      trace_id = "trace-A"
    ; absolute_turn = 1
    ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-A" ~absolute_turn:1
    }
  in
  let r2 =
    { (record_with_blocks
         [ sample_block Prompt_block_id.Keeper_instructions "aaaa"
         ; sample_block Prompt_block_id.Temporal_summary "rrrr"
         ])
      with
      trace_id = "trace-A"
    ; absolute_turn = 2
    ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-A" ~absolute_turn:2
    }
  in
  let r3 =
    { (record_with_blocks [ sample_block Prompt_block_id.Keeper_instructions "zzzz" ]) with
      trace_id = "trace-B" (* new generation: diff must be None *)
    ; absolute_turn = 3
    ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-B" ~absolute_turn:3
    }
  in
  match Turn_record.entries_with_diffs [ r1; r2; r3 ] with
  | [ (_, first); (_, second); (_, third) ] ->
    check bool "first record has no predecessor" true (first = None);
    (match second with
     | Some diff ->
       check (list block_id) "same-trace diff sees the added summary"
         [ Prompt_block_id.Temporal_summary ]
         (List.map (fun (b : Turn_record.prompt_block) -> b.block) diff.added)
     | None -> fail "expected a diff for the same-trace successor");
    check bool "trace boundary yields no diff" true (third = None)
  | _ -> fail "expected three paired entries"

(* ── Turn_ref (RFC-0233 §7) ───────────────────────────── *)

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

(* The 61 rows in #30190 that named a deepseek profile next to GLM's 200,000
   were all error-path rows, and the number they carried was the turn budget,
   not that profile's window. Both halves of the contract are pinned here: the
   number recorded is the budget the prompt was shaped to, and the error path
   records no number at all. *)
let test_context_window_records_the_turn_budget () =
  Alcotest.(check (option int))
    "a completed turn records the budget it was shaped to"
    (Some 200_000)
    (Masc.Keeper_turn_record_writer.context_window_of_turn
       ~turn_budget:200_000
       `Produced_result)

let test_context_window_absent_on_the_error_path () =
  Alcotest.(check (option int))
    "an errored turn records no ceiling"
    None
    (Masc.Keeper_turn_record_writer.context_window_of_turn
       ~turn_budget:200_000
       `Errored)


let () =
  run "turn_record"
    [ ( "prompt_block_id"
      , [ test_case "all known constructors roundtrip" `Quick test_block_id_roundtrip
        ; test_case "unknown block rejected" `Quick test_block_id_unknown_rejected
        ; test_case "post-tool round classes" `Quick
            test_block_id_post_tool_round_classes
        ] )
    ; ( "codec"
      , [ test_case "roundtrip" `Quick test_codec_roundtrip
        ; test_case "cache counts round-trip and stay optional" `Quick
            test_cache_counts_round_trip_and_stay_optional
        ; test_case "historical row without usage scope is unavailable" `Quick
            test_historical_row_without_usage_scope_is_unavailable
        ; test_case "optional fields absent" `Quick test_codec_optional_fields_absent
        ; test_case "rejects malformed rows" `Quick test_codec_rejects_malformed
        ; test_case "current observation fields required" `Quick
            test_codec_requires_current_observation_fields
        ; test_case "record carries transmitted history share" `Quick
            test_record_carries_transmitted_history_share
        ; test_case "transmitting more than held rejected" `Quick
            test_codec_rejects_transmitting_more_than_held
        ; test_case "half an observation rejected" `Quick
            test_codec_rejects_half_an_observation
        ; test_case "mismatched turn_ref rejected" `Quick
            test_codec_rejects_mismatched_turn_ref
        ; test_case "mismatched raw trace session rejected" `Quick
            test_codec_rejects_mismatched_raw_trace_session
        ; test_case "partial or invalid request wire observation rejected"
            `Quick
            test_codec_rejects_partial_or_invalid_request_wire_observation
        ; test_case "unknown input component rejected" `Quick
            test_codec_rejects_unknown_input_component
        ; test_case "input component extra field rejected" `Quick
            test_codec_rejects_input_component_extra_field
        ; test_case "explicit unavailable input components round-trip" `Quick
            test_codec_preserves_explicit_unavailable_input_components
        ; test_case "malformed blocks rejected" `Quick
            test_codec_rejects_malformed_blocks
        ; test_case "duplicate blocks and components rejected" `Quick
            test_codec_rejects_duplicate_blocks_and_components
        ; test_case "unknown block is rejected" `Quick
            test_codec_rejects_unknown_block
        ; test_case "unknown fields are rejected" `Quick
            test_codec_rejects_unknown_fields
        ] )
    ; ( "block_diff"
      , [ test_case "exact added/removed/changed sets" `Quick
            test_diff_added_removed_changed
        ; test_case "identical records diff empty" `Quick
            test_diff_identical_records_is_empty
        ; test_case "entries_with_diffs pairs same-trace only" `Quick
            test_entries_with_diffs_same_trace_only
        ] )
    ; ( "context_window"
      , [ test_case "records the turn budget" `Quick
            test_context_window_records_the_turn_budget
        ; test_case "absent on the error path" `Quick
            test_context_window_absent_on_the_error_path
        ; test_case "tool surface ref round trips and stays optional" `Quick
            test_tool_surface_ref_round_trips_and_stays_optional
        ; test_case "the tool surface payload round trips" `Quick
            test_the_tool_surface_payload_round_trips
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
