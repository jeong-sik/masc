open Alcotest
open Masc

module Snapshot = Keeper_provider_input_snapshot
module Wire = Llm_provider.Request_wire_observer

let keeper = "provider-input-fixture"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-provider-input-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    (try Unix.rmdir path with
     | Unix.Unix_error _ -> ())
  | _ ->
    (try Unix.unlink path with
     | Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

let with_workspace_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f env sw config
;;

let with_workspace f =
  with_workspace_env (fun _env _sw config -> f config)
;;

let wire : Wire.observation =
  { phase = Wire.Pre_dispatch_serialization
  ; capture_id = Some "capture-fixture"
  ; provider = "openai-compatible"
  ; model = "fixture-model"
  ; http_codec = "responses"
  ; stream = true
  ; body_bytes = 8192
  ; body_sha256 = String.make 64 'a'
  }
;;

let message = Agent_core.Types.text_message Agent_core.Types.User "remember exact fact"

let tool =
  Agent_core.Tool.create
    ~name:"masc_status"
    ~description:"read current status"
    ~parameters:[]
    (fun _ -> Ok { Agent_core.Types.content = "ok"; content_blocks = None; _meta = None })
;;

let write_for config keeper absolute_turn =
  Snapshot.write_best_effort
    ~config
    ~keeper
    ~trace_id:"trace-provider-input"
    ~absolute_turn
    ~runtime_profile:"local"
    ~wire
    ~system_prompt:"exact system prompt"
    ~messages:[ message ]
    ~tools:[ tool ]
;;

let write config absolute_turn = write_for config keeper absolute_turn

let turn_ref absolute_turn =
  Ids.Turn_ref.make ~trace_id:"trace-provider-input" ~absolute_turn
;;

let test_continuity_export_keeps_every_attributed_request_and_exact_boundary () =
  with_workspace (fun config ->
    let module C = Keeper_continuity_request in
    let module E = Keeper_continuity_evidence in
    let module B = Keeper_turn_boundaries in
    let reference = turn_ref 7 in
    let request_store =
      Dated_jsonl.open_store
        (Dated_jsonl.Store.keeper
           (Workspace.dated_store_root config)
           ~keeper
           Dated_jsonl.Store.Keeper.Continuity_requests)
    in
    (* Legacy v2 rows and explicitly unbound v3 rows (turn_ref: null) have no
       turn identity; they must be skipped and counted rather than aborting the
       scan or discarding collected rows for [reference]. *)
    Dated_jsonl.append
      request_store
      (`Assoc
         [ "schema", `String "masc.continuity-request.v2"
         ; "runtime_id", `String "local"
         ]);
    let range : C.range = { origin = Keeper_carried_front.Turn_start { end_atom = 0 };
      first_atom = 0; total_atoms = 1; custom_projection_changed = false } in
    let record_request ?(turn_ref = Some reference) ~range wire =
      C.record_best_effort ~config ~keeper_name:keeper ~turn_ref ~runtime_id:"local"
        ~selection:C.Without_snapshot ~range ~wire in
    record_request ~range:(Some range) { wire with capture_id = Some "first-wire" };
    record_request ~range:None wire;
    (* A range whose serialization has no capture identity stays explicitly
       unbound: the association must not advertise a projection that cannot be
       joined back to this serialization. *)
    record_request ~range:(Some range) { wire with capture_id = None };
    record_request ~turn_ref:None ~range:None { wire with capture_id = Some "unbound-later-wire" };
    write config 7;
    let position_one = match B.position_of_messages [message] with
      | Ok value -> value | Error detail -> fail detail in
    let position_two = match B.position_of_messages [message; message] with
      | Ok value -> value | Error detail -> fail detail in
    let boundary_one : B.record = { recorded_at = 1.; event = B.Turn_ended {
      turn_ref = reference; task_context = Keeper_turn_task_context.No_task;
      history_at_start = B.Fresh_history; position = position_one } } in
    let boundary_two : B.record = { recorded_at = 1.5; event = B.Turn_ended {
      turn_ref = reference; task_context = Keeper_turn_task_context.No_task;
      history_at_start = B.Fresh_history; position = position_two } } in
    let append record = match B.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
        ~keeper_id:keeper record with
      | Ok () -> () | Error error -> fail (B.append_error_to_string error) in
    append boundary_one;
    append boundary_two;
    let evidence = match E.read ~config ~keeper ~turn_ref:reference with
      | Ok value -> value | Error error -> fail (Snapshot.read_error_to_string error) in
    let open Yojson.Safe.Util in
    check string "schema matches constant" E.schema (evidence |> member "schema" |> to_string);
    check string "exact owner" keeper (evidence |> member "keeper" |> to_string);
    check bool "last wire is the retained canonical manifest" true
      (member "wire" evidence = Wire.observation_to_yojson wire);
    let requests_obs = evidence |> member "requests" in
    let requests = requests_obs |> member "value" |> to_list in
    check int "all three attributed serializations retained" 3 (List.length requests);
    check int "all 5 store rows scanned" 5 (requests_obs |> member "scanned_rows" |> to_int);
    check int "legacy v2 and unbound v3 counted as skipped" 2
      (requests_obs |> member "skipped_unattributed_rows" |> to_int);
    check bool "unassociated serialization never inherits an older range" true
      (List.nth requests 1 |> member "bounded_range" = `Null);
    check bool "a range without capture identity stays unbound" true
      (let row = List.nth requests 2 in
       member "association" row = `String "projection_unavailable"
       && member "bounded_range" row = `Null
       && member "binding" row = `String "unbound");
    check bool "latest completed boundary in generation exported" true
      (evidence |> member "completed_boundary" |> member "value" |> member "record"
       = B.record_to_json boundary_two);
    append { recorded_at = 2.; event = B.History_restarted { trace_id = Ids.Turn_ref.trace_id reference } };
    check string "another history generation cannot reuse the old boundary" "unavailable"
      (E.completed_boundary ~config ~keeper ~turn_ref:reference |> member "kind" |> to_string);
    (* Malformed turn_ref or owner mismatch in v3 still fails closed. *)
    Dated_jsonl.append
      request_store
      (`Assoc
         [ "schema", `String "masc.continuity-request.v3"
         ; "keeper", `String keeper
         ; "turn_ref", `String "not-a-valid-turn-ref"
         ]);
    let after_corrupt = match E.read ~config ~keeper ~turn_ref:reference with
      | Ok value -> value | Error error -> fail (Snapshot.read_error_to_string error) in
    check string "corrupt turn_ref fails closed" "unavailable"
      (after_corrupt |> member "requests" |> member "kind" |> to_string);
    check string "corrupt turn_ref reason" "malformed continuity request turn identity"
      (after_corrupt |> member "requests" |> member "reason" |> to_string);
    (* A v3 row with the turn_ref field entirely absent is corruption, not an
       unattributed request: the observation must fail closed instead of
       exporting a partial list as complete. The writer always records the
       field, writing an explicit null when unattributed. *)
    Dated_jsonl.append
      request_store
      (`Assoc
         [ "schema", `String "masc.continuity-request.v3"
         ; "keeper", `String keeper
         ]);
    let after_missing = match E.read ~config ~keeper ~turn_ref:reference with
      | Ok value -> value | Error error -> fail (Snapshot.read_error_to_string error) in
    check string "missing turn_ref field fails closed" "unavailable"
      (after_missing |> member "requests" |> member "kind" |> to_string);
    check string "missing turn_ref reason" "continuity request missing turn identity field"
      (after_missing |> member "requests" |> member "reason" |> to_string);
    (* A v3 row carrying the requested turn_ref but violating the row body
       (here: no wire observation at all) is corruption, not evidence: the
       export must fail closed instead of returning the raw row. *)
    Dated_jsonl.append
      request_store
      (`Assoc
         [ "schema", `String "masc.continuity-request.v3"
         ; "keeper", `String keeper
         ; "turn_ref", Ids.Turn_ref.to_yojson reference
         ]);
    let after_body_corrupt = match E.read ~config ~keeper ~turn_ref:reference with
      | Ok value -> value | Error error -> fail (Snapshot.read_error_to_string error) in
    check string "an attributed row with a violated body fails closed" "unavailable"
      (after_body_corrupt |> member "requests" |> member "kind" |> to_string);
    check string "violated body reason" "malformed continuity request row"
      (after_body_corrupt |> member "requests" |> member "reason" |> to_string))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper_provider_input_snapshot_continuity_export"
    [ ( "round trip"
      , [ test_case "continuity export preserves every request and history generation" `Quick
            test_continuity_export_keeps_every_attributed_request_and_exact_boundary
        ] )
    ]
;;
