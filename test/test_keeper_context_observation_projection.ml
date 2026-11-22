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
  Agent_core_sha256.digest_string label |> Agent_core_sha256.to_hex
;;

let sample_trace = "trace-1780648779957-00000"

let sample_record
      ?(absolute_turn = 4071)
      ?(input_tokens = Some 18_000)
      ?(context_window = Some 131_072)
      ?(provider_context_window = None)
      ?(usage_scope = Runtime_usage_scope.Per_request)
      ?(input_provenance = Some Turn_input_provenance.Measured_request)
      ()
  : Turn_record.t
  =
  { request_observations = [];  execution_ids = []
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
  ; provider_context_window
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1234
  ; ttfrc_ms = None
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding.glm-5-turbo"; body_bytes = 560_513 }
  ; model_input_window = None
  ; response_observed_model_input = None
  ; refused_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 15_000
      ; scope = usage_scope
      ; input_provenance
      }
  ; turn_output_tokens = None
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
  check bool "context_ratio is null" true (field fields "context_ratio" = `Null);
  check bool "context_tokens is null" true (field fields "context_tokens" = `Null);
  check bool "context_max is null" true (field fields "context_max" = `Null);
  check bool "context_source is null" true (field fields "context_source" = `Null)
;;

let test_missing_store_is_typed_absence () =
  with_temp_workspace (fun config ->
    let observation = Projection.context_observation ~config ~keeper_name:"nobody" ~current_trace_id:sample_trace in
    check_not_observed observation.fields ~reason:"context_measurement_missing";
    check bool "missing measurement is a complete absence" true
      (observation.completeness = Masc.Dashboard_projection_read.Complete))
;;

let test_storage_read_failure_and_raw_repair_keep_same_read_completeness () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ());
    let store = Masc.Keeper_types_support.keeper_turn_record_store config "beta" in
    Dated_jsonl.close store;
    let base_dir = Dated_jsonl.base_dir store in
    let held_dir = base_dir ^ ".fixture-held" in
    Sys.rename base_dir held_dir;
    let restored = ref false in
    let restore () =
      if not !restored then (
        if Sys.file_exists base_dir then Sys.remove base_dir;
        Sys.rename held_dir base_dir;
        restored := true) in
    Fun.protect ~finally:restore (fun () ->
      let channel = open_out_bin base_dir in
      output_string channel "not a directory";
      close_out channel;
      let failed = Projection.context_observation ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
      check_not_observed failed.fields ~reason:"turn_record_read_failed";
      (match failed.completeness with
       | Masc.Dashboard_projection_read.Partial detail ->
           check bool "storage failure retains its actual diagnostic" true (String.length detail > 0)
       | Complete -> fail "strict tail I/O failure was reported as complete");
      (* Restore only the original bytes. No append, metadata write or source
         notification supplies a different observation. *)
      restore ();
      let repaired = Projection.context_observation ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
      check bool "raw repair is complete" true
        (repaired.completeness = Masc.Dashboard_projection_read.Complete);
      check int "raw repair recovers the original measurement" 18_000
        (match field repaired.fields "context_tokens" with
         | `Int tokens -> tokens | _ -> fail "repaired context_tokens is not an int");
      check bool "raw repair clears the typed absence" true
        (field repaired.fields "context_metrics_unavailable" = `Null)))
;;

let remove_day_files config ~keeper_name =
  let store = Masc.Keeper_types_support.keeper_turn_record_store config keeper_name in
  Dated_jsonl.close store;
  let base_dir = Dated_jsonl.base_dir store in
  Array.iter
    (fun month ->
       let month_path = Filename.concat base_dir month in
       Array.iter (fun day -> Sys.remove (Filename.concat month_path day)) (Sys.readdir month_path))
    (Sys.readdir base_dir)
;;

let context_tokens fields =
  match field fields "context_tokens" with
  | `Int tokens -> Some tokens
  | _ -> None
;;

(* The newest TurnRecord is kept in memory by its store. The second
   projection has to come from there: the files it would read are gone. Once
   the store is told of a removal the projection reads the files again and
   finds none. *)
let test_a_kept_record_is_projected_without_the_files () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ());
    let project () =
      Projection.context_observation ~config ~keeper_name:"beta" ~current_trace_id:sample_trace
    in
    check (option int) "read from the files" (Some 18_000) (context_tokens (project ()).fields);
    remove_day_files config ~keeper_name:"beta";
    let kept = project () in
    check (option int) "projected again with the files gone" (Some 18_000) (context_tokens kept.fields);
    check bool "and complete" true (kept.completeness = Masc.Dashboard_projection_read.Complete);
    Dated_jsonl.directories_removed ();
    check_not_observed (project ()).fields ~reason:"context_measurement_missing")
;;

(* The append of a record moves the kept one: the projection after it is the
   new record's, with no read of the files in between. *)
let test_an_appended_record_replaces_the_kept_one () =
  with_temp_workspace (fun config ->
    append_record config (sample_record ());
    let project () =
      Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace
    in
    check (option int) "the first record" (Some 18_000) (context_tokens (project ()));
    append_record config (sample_record ~absolute_turn:4072 ~input_tokens:(Some 21_000) ());
    remove_day_files config ~keeper_name:"beta";
    check (option int) "the appended record, with the files gone" (Some 21_000) (context_tokens (project ())))
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
    let observation = Projection.context_observation ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    check_not_observed observation.fields ~reason:"turn_record_without_usage";
    check bool "unmeasured usage is a complete absence" true
      (observation.completeness = Masc.Dashboard_projection_read.Complete))
;;

let test_undecodable_newest_line_is_typed () =
  with_temp_workspace (fun config ->
    append_raw config ~keeper_name:"beta" (`Assoc [ "schema", `String "future" ]);
    let observation = Projection.context_observation ~config ~keeper_name:"beta" ~current_trace_id:sample_trace in
    check_not_observed observation.fields ~reason:"turn_record_undecodable";
    check bool "undecodable measurement retains complete absence semantics" true
      (observation.completeness = Masc.Dashboard_projection_read.Complete))
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

let roundtrip fields =
  Yojson.Safe.from_string (Yojson.Safe.to_string (`Assoc fields))
;;

let check_unavailable_diagnostics fields ~expected_reason ~raw_input_tokens ~context_window =
  let json = roundtrip fields in
  let open Yojson.Safe.Util in
  let unavail = json |> member "context_metrics_unavailable" in
  check string "reason survives JSON roundtrip" expected_reason
    (unavail |> member "reason" |> to_string);
  check (option int) "raw_input_tokens survives JSON roundtrip" raw_input_tokens
    (unavail |> member "raw_input_tokens" |> to_int_option);
  check (option int) "context_window survives JSON roundtrip" context_window
    (unavail |> member "context_window" |> to_int_option)
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
    check_unavailable_diagnostics fields
      ~expected_reason:"conversation_cumulative_usage"
      ~raw_input_tokens:(Some 1_063_857)
      ~context_window:(Some 128_000))
;;

let test_client_turn_total_is_diagnostic_not_occupancy () =
  with_temp_workspace (fun config ->
    append_record config
      (sample_record ~usage_scope:Runtime_usage_scope.Turn_total ());
    let fields =
      Projection.context_fields ~config ~keeper_name:"beta"
        ~current_trace_id:sample_trace
    in
    check_not_observed fields ~reason:"turn_total_usage";
    check bool "an aggregate below the window still has no occupancy ratio" true
      (field fields "context_ratio" = `Null);
    check_unavailable_diagnostics fields
      ~expected_reason:"turn_total_usage"
      ~raw_input_tokens:(Some 18_000)
      ~context_window:(Some 131_072))
;;

let test_provider_window_is_used_for_occupancy () =
  with_temp_workspace (fun config ->
    append_record config
      (sample_record ~input_tokens:(Some 414_200)
         ~context_window:(Some 1_000_000)
         ~provider_context_window:(Some 828_400) ());
    let fields = Projection.context_fields ~config ~keeper_name:"beta"
        ~current_trace_id:sample_trace in
    check bool "uses reported usable context" true
      (field fields "context_max" = `Int 828_400);
    check bool "half of the actual window" true
      (field fields "context_ratio" = `Float 0.5))
;;

let test_per_request_overflow_is_unavailable_not_clamped () =
  with_temp_workspace (fun config ->
    append_record
      config
      (sample_record
         ~input_tokens:(Some 310_209)
         ~context_window:(Some 1_000_000)
         ~provider_context_window:(Some 272_000)
         ());
    let fields =
      Projection.context_fields
        ~config
        ~keeper_name:"beta"
        ~current_trace_id:sample_trace
    in
    check_not_observed fields ~reason:"context_tokens_exceed_window";
    check_unavailable_diagnostics fields
      ~expected_reason:"context_tokens_exceed_window"
      ~raw_input_tokens:(Some 310_209)
      ~context_window:(Some 272_000))
;;

(* A newer compaction estimate or a count with no provenance must not
   expose the earlier measured row, nor become a measured overflow when its
   value is above the provider window. The raw durable row stays unchanged. *)
let test_newest_unmeasured_input_stays_diagnostic () =
  List.iter
    (fun provenance ->
       List.iter
         (fun tokens ->
            with_temp_workspace (fun config ->
              append_record config (sample_record ~absolute_turn:1 ());
              append_record config
                (sample_record ~absolute_turn:2 ~input_tokens:(Some tokens)
                   ~context_window:(Some 1_000_000)
                   ~provider_context_window:(Some 272_000)
                   ~input_provenance:provenance ());
              let store = Masc.Keeper_types_support.keeper_turn_record_store config "beta" in
              (match Dated_jsonl.read_recent_result store 1 with
               | Ok [Dated_jsonl.Parsed json] ->
                 (match Turn_record.of_json json with
                  | Ok record ->
                    check int "newest durable row is retained" 2 record.absolute_turn;
                    check (option int) "raw count is retained" (Some tokens) record.usage.input_tokens;
                    check bool "raw provenance is retained" true
                      (record.usage.input_provenance = provenance)
                  | Error detail -> fail detail)
               | Ok _ -> fail "expected the exact newest durable row"
               | Error error -> fail (Dated_jsonl.read_error_to_string error));
              let fields = Projection.context_fields ~config ~keeper_name:"beta"
                  ~current_trace_id:sample_trace in
              let reason = match provenance with
                | Some Turn_input_provenance.Context_estimate -> "context_input_estimate"
                | None -> "input_provenance_unavailable"
                | Some Turn_input_provenance.Measured_request -> fail "fixture must be unmeasured" in
              check_not_observed fields ~reason;
              check_unavailable_diagnostics fields
                ~expected_reason:reason
                ~raw_input_tokens:(Some tokens)
                ~context_window:(Some 272_000)))
         [45_000; 310_209])
    [Some Turn_input_provenance.Context_estimate; None]
;;

let test_every_projected_shape_decodes () =
  with_temp_workspace (fun config ->
    (* absence: no store at all *)
    let absent =
      Projection.context_fields ~config ~keeper_name:"nobody" ~current_trace_id:sample_trace
    in
    let absent_json = roundtrip absent in
    check bool "typed absence sets context_metrics_unavailable" true
      (Yojson.Safe.Util.member "context_metrics_unavailable" absent_json <> `Null);
    (* measurement: a record on the current trace *)
    append_record config (sample_record ());
    let measured =
      Projection.context_fields ~config ~keeper_name:"beta" ~current_trace_id:sample_trace
    in
    let measured_json = roundtrip measured in
    let open Yojson.Safe.Util in
    check bool "measured observation clears unavailability" true
      (measured_json |> member "context_metrics_unavailable" = `Null);
    check int "measured input does not include the output" 18_000
      (measured_json |> member "context_tokens" |> to_int);
    check (option int) "measured window survives" (Some 131_072)
      (measured_json |> member "context_max" |> to_int_option);
    check (option (float 1e-9)) "measured ratio survives"
      (Some (18_000.0 /. 131_072.0))
      (measured_json |> member "context_ratio" |> to_number_option);
    (* the two shapes are distinguishable, or decoding both proves nothing *)
    check
      bool
      "absence and measurement are different payloads"
      true
      (absent <> measured))
;;

(* This executable stands for the server, the process that writes the
   TurnRecords, so the stores keep their newest row in memory. *)
let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_context_observation_projection"
    [ ( "projection"
      , [ test_case "missing store is typed absence" `Quick
            test_missing_store_is_typed_absence
        ; test_case "strict tail I/O failure and raw repair keep same-read completeness" `Quick
            test_storage_read_failure_and_raw_repair_keep_same_read_completeness
        ; test_case "measured record projects tokens/window/provenance" `Quick
            test_measured_record_projects
        ; test_case "newest record wins" `Quick test_newest_record_wins
        ; test_case "a kept record is projected without the files" `Quick
            test_a_kept_record_is_projected_without_the_files
        ; test_case "an appended record replaces the kept one" `Quick
            test_an_appended_record_replaces_the_kept_one
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
        ; test_case "client-turn total is diagnostic, not occupancy" `Quick
            test_client_turn_total_is_diagnostic_not_occupancy
        ; test_case "provider window occupancy" `Quick
            test_provider_window_is_used_for_occupancy
        ; test_case "per-request overflow is unavailable, not clamped" `Quick
            test_per_request_overflow_is_unavailable_not_clamped
        ; test_case "newest estimate and unknown input retain diagnostics" `Quick
            test_newest_unmeasured_input_stays_diagnostic
        ; test_case "every projected shape decodes" `Quick
            test_every_projected_shape_decodes
        ] )
    ]
;;
