open Tool_repair_loop_types

let store_config (state : state) =
  Artifact_store.default_config ~session_id:state.artifact_session_id

let metadata ~state ~kind ~artifact_id =
  {
    Artifact_store.artifact_id;
    kind;
    producer = "tool_repair_loop";
    schema_version = "v1";
    created_at_iso = Types.now_iso ();
    owner = "masc";
    session_id = state.artifact_session_id;
  }

let latest_attempt_json (state : state) =
  match List.rev state.attempts with
  | latest :: _ -> attempt_record_to_json latest
  | [] -> `Null

let emit_advisory_artifacts (state : state) : (string list, string) result =
  try
    let config = store_config state in
    Artifact_store.init config;
    let summary_id = Printf.sprintf "%s-summary" state.loop_id in
    let evidence_id =
      Printf.sprintf "%s-attempt-%02d" state.loop_id state.attempt_count
    in
    Artifact_store.write config
      ~metadata:(metadata ~state ~kind:Artifact_store.Evaluator_result
                   ~artifact_id:summary_id)
      ~payload:
        (`Assoc
          [
            ("loop_id", `String state.loop_id);
            ("plugin_id", `String state.plugin_id);
            ("status", `String (repair_status_to_string state.status));
            ("attempt_count", `Int state.attempt_count);
            ("latest_attempt", latest_attempt_json state);
          ]);
    Artifact_store.write config
      ~metadata:(metadata ~state ~kind:Artifact_store.Evidence_bundle
                   ~artifact_id:evidence_id)
      ~payload:(state_to_json state);
    Ok
      [
        Artifact_store.make_ref ~session_id:state.artifact_session_id
          ~kind:Artifact_store.Evaluator_result ~artifact_id:summary_id;
        Artifact_store.make_ref ~session_id:state.artifact_session_id
          ~kind:Artifact_store.Evidence_bundle ~artifact_id:evidence_id;
      ]
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "repair loop CDAL projection failed: %s" (Printexc.to_string exn))
