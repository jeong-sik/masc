(** Context-observation projection sources the newest TurnRecord: the
    provider-measured numbers reach the wire fields, and every absence is a
    typed reason instead of a pinned null. *)

open Alcotest

module Projection = Masc.Keeper_context_observation_projection

let with_temp_workspace f =
  let path = Filename.temp_file "ctx-observation-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f (Masc.Workspace.default_config path))
;;

let digest_of_label label =
  Digestif.SHA256.digest_string label |> Digestif.SHA256.to_hex
;;

let sample_trace = "trace-1780648779957-00000"

let sample_record
      ?(absolute_turn = 4071)
      ?(input_tokens = Some 18_000)
      ?(context_window = Some 131_072)
      ?(usage_scope = Runtime_usage_scope.Per_request)
      ()
  : Turn_record.t
  =
  { execution_ids = []
  ; keeper = "beta"
  ; agent_name = "beta-agent"
  ; turn_kind = Turn_record.Direct
  ; trace_id = sample_trace
  ; absolute_turn
  ; turn_ref = Ids.Turn_ref.make ~trace_id:sample_trace ~absolute_turn
  ; blocks =
      [ { Turn_record.block = Prompt_block_id.Keeper_instructions
        ; bytes = 4
        ; digest = digest_of_label "aaaa"
        }
      ]
  ; input_components = Some [ { component = Turn_record.Tool_schemas; bytes = 8192 } ]
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding.glm-5-turbo"
  ; selected_model = Some "glm-5-turbo"
  ; finish_reason = Some "completed"
  ; context_window
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1234
  ; ttfrc_ms = None
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding.glm-5-turbo"; body_bytes = 560_513 }
  ; model_input_window = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None
      ; top_p = None
      ; max_tokens = None
      ; thinking_budget = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 15_000
      ; scope = usage_scope
      }
  ; ts = 1_781_200_000.5
  }
;;

let append_record config record =
  let store =
    Masc.Keeper_types_support.keeper_turn_record_store config record.Turn_record.keeper
  in
  Dated_jsonl.append store (Turn_record.to_json record)
;;

let append_raw config ~keeper_name json =
  let store = Masc.Keeper_types_support.keeper_turn_record_store config keeper_name in
  Dated_jsonl.append store json
;;

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> failf "field %s is absent from the projection" name
;;

let context_object fields =
  match field fields "context" with
  | `Assoc context -> context
  | _ -> fail "context field is not an object"
;;

let check_not_observed fields ~reason =
  (match field fields "context_metrics_unavailable" with
   | `Assoc unavailable ->
     check string "kind" "not_observed"
       (match List.assoc_opt "kind" unavailable with
        | Some (`String kind) -> kind
        | _ -> "<missing>");
     check string "reason" reason
       (match List.assoc_opt "reason" unavailable with
        | Some (`String value) -> value
        | _ -> "<missing>")
   | _ -> fail "context_metrics_unavailable is not an object");
  check bool "context_tokens is null" true (field fields "context_tokens" = `Null);
  check bool "context_max is null" true (field fields "context_max" = `Null);
  check bool "context_source is null" true (field fields "context_source" = `Null)
;;

let test_missing_store_is_typed_absence () =
  with_temp_workspace (fun config ->
    let fields = Projection.context_fields ~config ~keeper_name:"nobody" ~current_trace_id:sample_trace in
    check_not_observed fields ~reason:"context_measurement_missing")
;;

let test_measured_record_projects () =
  with_temp_workspace (fun config ->
    let record = sample_record () in
    append_record config record;
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    (match field fields "context_tokens" with
     | `Int tokens -> check int "tokens" 18_000 tokens
     | _ -> fail "context_tokens is not an int");
    (match field fields "context_max" with
     | `Int window -> check int "window" 131_072 window
     | _ -> fail "context_max is not an int");
    (match field fields "context_ratio" with
     | `Float ratio ->
       check bool "ratio matches tokens/window" true
         (Float.abs (ratio -. (18_000.0 /. 131_072.0)) < 1e-9)
     | _ -> fail "context_ratio is not a float");
    (match field fields "context_source" with
     | `String source -> check string "source" "turn_record" source
     | _ -> fail "context_source is not a string");
    check bool "unavailable is null" true
      (field fields "context_metrics_unavailable" = `Null);
    let context = context_object fields in
    (match List.assoc_opt "absolute_turn" context with
     | Some (`Int turn) -> check int "absolute_turn" 4071 turn
     | _ -> fail "context.absolute_turn missing");
    (match List.assoc_opt "request_body_bytes" context with
     | Some (`Int bytes) -> check int "request bytes" 560_513 bytes
     | _ -> fail "context.request_body_bytes missing");
    (match List.assoc_opt "turn_ref" context with
     | Some (`String turn_ref) ->
       check string "turn_ref" "trace-1780648779957-00000#4071" turn_ref
     | _ -> fail "context.turn_ref missing");
    match List.assoc_opt "observed_at" context with
    | Some (`String _) -> ()
    | _ -> fail "context.observed_at missing")
;;

let test_newest_record_wins () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ~absolute_turn:1 ~input_tokens:(Some 100) ());
    append_record config (sample_record ~absolute_turn:2 ~input_tokens:(Some 200) ());
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    match field fields "context_tokens" with
    | `Int tokens -> check int "newest tokens" 200 tokens
    | _ -> fail "context_tokens is not an int")
;;

let test_record_without_usage_is_typed () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ~input_tokens:None ());
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    check_not_observed fields ~reason:"turn_record_without_usage")
;;

let test_undecodable_newest_line_is_typed () =
  with_temp_workspace (fun config ->
    append_raw config ~keeper_name:"beta" (`Assoc [ "schema", `String "future" ]);
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    check_not_observed fields ~reason:"turn_record_undecodable")
;;

(* Raw non-JSON tail: the permissive reader would silently skip it and serve
   the previous row as "the measurement"; the strict reader keeps it visible
   as a typed decode failure. *)
let test_malformed_raw_tail_is_undecodable_not_previous_row () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ());
    let store = Masc.Keeper_types_support.keeper_turn_record_store config "beta" in
    let base_dir = Dated_jsonl.base_dir store in
    let day_files =
      Sys.readdir base_dir
      |> Array.to_list
      |> List.concat_map (fun month ->
        let month_path = Filename.concat base_dir month in
        Sys.readdir month_path
        |> Array.to_list
        |> List.map (Filename.concat month_path))
    in
    (match day_files with
     | [ day_file ] ->
       let channel =
         open_out_gen [ Open_append; Open_wronly ] 0o600 day_file
       in
       output_string channel "not a json line\n";
       close_out channel
     | files -> failf "expected exactly one day file, found %d" (List.length files));
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    check_not_observed fields ~reason:"turn_record_undecodable")
;;

let test_previous_trace_row_is_typed_absent () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ());
    let fields =
      Projection.context_fields
        ~config
        ~keeper_name:"beta"
        ~current_trace_id:"trace-1780648779957-99999"
    in
    check_not_observed fields ~reason:"turn_record_trace_mismatch")
;;

let test_missing_window_keeps_tokens_without_ratio () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ~context_window:None ());
    let fields = Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    (match field fields "context_tokens" with
     | `Int tokens -> check int "tokens survive" 18_000 tokens
     | _ -> fail "context_tokens is not an int");
    check bool "ratio is null without a window" true
      (field fields "context_ratio" = `Null);
    check bool "max is null without a window" true (field fields "context_max" = `Null))
;;

let decodes fields =
  Masc.Tui_decode.decode_context_observation
    ~expected_trace_id:sample_trace
    (`Assoc fields)
;;

let test_cumulative_usage_is_diagnostic_not_occupancy () =
  with_temp_workspace (fun config ->
    append_record
      config
      (sample_record
         ~input_tokens:(Some 1_063_857)
         ~context_window:(Some 128_000)
         ~usage_scope:Runtime_usage_scope.Conversation_cumulative
         ());
    let fields =
      Projection.context_fields
        ~config
        ~keeper_name:"beta"
        ~current_trace_id:sample_trace
    in
    check_not_observed fields ~reason:"conversation_cumulative_usage";
    match decodes fields with
    | Ok
        (Masc.Tui_decode.Context_unavailable
          (Context_conversation_cumulative_usage
            { raw_input_tokens = Some 1_063_857
            ; context_window = Some 128_000
            })) -> ()
    | Ok _ -> fail "cumulative usage lost its typed raw diagnostics"
    | Error detail -> fail detail)
;;

let test_per_request_overflow_is_unavailable_not_clamped () =
  with_temp_workspace (fun config ->
    append_record
      config
      (sample_record
         ~input_tokens:(Some 128_001)
         ~context_window:(Some 128_000)
         ());
    let fields =
      Projection.context_fields
        ~config
        ~keeper_name:"beta"
        ~current_trace_id:sample_trace
    in
    check_not_observed fields ~reason:"context_tokens_exceed_window";
    match decodes fields with
    | Ok
        (Masc.Tui_decode.Context_unavailable
          (Context_tokens_exceed_window
            { raw_input_tokens = 128_001; context_window = 128_000 })) -> ()
    | Ok _ -> fail "per-request overflow was clamped or lost"
    | Error detail -> fail detail)
;;

(* The projection writes these fields and Tui_decode reads them, but each side
   had only its own tests: the producer checked what it emitted and the decoder
   checked hand-written JSON. A field the producer stopped emitting therefore
   left both suites green while the Live Context surface fell back to zeros
   (#29320). Every shape the producer can emit is decoded here. *)
let test_every_projected_shape_decodes () =
  with_temp_workspace (fun config ->
    (* absence: no store at all *)
    let absent =
      Projection.context_fields ~config ~keeper_name:"nobody" ~current_trace_id:sample_trace
    in
    (match decodes absent with
     | Ok _ -> ()
     | Error detail -> failf "typed absence must decode: %s" detail);
    (* measurement: a record on the current trace *)
    append_record config (sample_record ());
    let measured =
      Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace
    in
    (match decodes measured with
     | Ok _ -> ()
     | Error detail -> failf "measured observation must decode: %s" detail);
    (* the two shapes are distinguishable, or decoding both proves nothing *)
    check
      bool
      "absence and measurement are different payloads"
      true
      (absent <> measured))
;;

let () =
  run
    "keeper_context_observation_projection"
    [ ( "projection"
      , [ test_case "missing store is typed absence" `Quick
            test_missing_store_is_typed_absence
        ; test_case "measured record projects tokens/window/provenance" `Quick
            test_measured_record_projects
        ; test_case "newest record wins" `Quick test_newest_record_wins
        ; test_case "record without usage is typed" `Quick
            test_record_without_usage_is_typed
        ; test_case "undecodable newest line is typed" `Quick
            test_undecodable_newest_line_is_typed
        ; test_case "malformed raw tail is undecodable, not previous row" `Quick
            test_malformed_raw_tail_is_undecodable_not_previous_row
        ; test_case "previous trace row is typed absent" `Quick
            test_previous_trace_row_is_typed_absent
        ; test_case "missing window keeps tokens without ratio" `Quick
            test_missing_window_keeps_tokens_without_ratio
        ; test_case "cumulative usage is diagnostic, not occupancy" `Quick
            test_cumulative_usage_is_diagnostic_not_occupancy
        ; test_case "per-request overflow is unavailable, not clamped" `Quick
            test_per_request_overflow_is_unavailable_not_clamped
        ; test_case "every projected shape decodes" `Quick
            test_every_projected_shape_decodes
        ] )
    ]
;;
