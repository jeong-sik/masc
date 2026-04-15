open Masc_mcp
open Test_operator_control_support

let test_digest_room_prefers_fresh_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      ignore (Coord.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Coord ~target_id:None
        ~summary:"Pause the namespace before taking any destructive action."
        ~recommended_action:
          (`Assoc
            [
              ("action_kind", `String "pause_room");
              ("resolved_tool", `String "masc_operator_confirm");
              ("target_type", `String "namespace");
              ("target_id", `Null);
              ("reason", `String "operator judge requires manual gate");
              ("payload_preview", `Assoc [ ("reason", `String "manual review") ]);
            ])
        ~fresh_for_sec:90.0 ();
      Alcotest.(check int) "stored judgments" 1
        (List.length (Operator_judgment.load_all config));
      (match
         Operator_judgment.latest_active config ~surface:"command.namespace"
           ~target_type:Operator_judgment.Coord ~target_id:None
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected room judgment in %s"
            (Operator_judgment.judgments_path config));
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner" "operator_keeper"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment available" true
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer" "judgment"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check string) "active summary from judgment"
        "Pause the namespace before taking any destructive action."
        Yojson.Safe.Util.
          (digest |> member "active_summary" |> member "summary" |> to_string);
      Alcotest.(check string) "active recommendation source" "judgment"
        Yojson.Safe.Util.(digest |> member "active_recommendation_source" |> to_string);
      Alcotest.(check bool) "judgment present" true
        (Yojson.Safe.Util.member "judgment" digest <> `Null))

let test_digest_room_ignores_stale_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      ignore (Coord.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Coord ~target_id:None
        ~summary:"This judgment is stale." ~fresh_for_sec:(-5.0) ();
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner fallback" "fallback_read_model"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment unavailable" false
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer fallback" "fallback"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check bool) "judgment missing" true
        (Yojson.Safe.Util.member "judgment" digest = `Null))

let test_operator_judgment_write_and_latest_roundtrip () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let written =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [
                ("surface", `String "command.namespace");
                ("target_type", `String "namespace");
                ("summary", `String "Operator judge requests a human checkpoint.");
                ("confidence", `Float 0.88);
                ("fresh_ttl_sec", `Int 90);
                ("evidence_refs", `List [ `String "trace:opsd-1" ]);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "write ok" "ok"
        Yojson.Safe.Util.(written |> member "status" |> to_string);
      let latest =
        match
          Operator_control.judgment_latest_json ctx
            (`Assoc [ ("surface", `String "command.namespace"); ("target_type", `String "namespace") ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "latest ok" "ok"
        Yojson.Safe.Util.(latest |> member "status" |> to_string);
      Alcotest.(check string) "latest summary"
        "Operator judge requests a human checkpoint."
        Yojson.Safe.Util.(latest |> member "judgment" |> member "summary" |> to_string))

let test_confirm_keeps_pending_token_when_delegated_action_fails () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Coord.masc_dir config) "operator" in
      let path = Filename.concat pending_dir "pending_confirms.json" in
      Coord_utils.mkdir_p pending_dir;
      let token = "retry-token" in
      let entry_json =
        `Assoc
          [
            ("token", `String token);
            ("trace_id", `String "trace-retry");
            ("actor", `String "operator");
            ("action_type", `String "missing_action_type");
            ("target_type", `String "namespace");
            ("target_id", `Null);
            ("payload", `Assoc []);
            ("delegated_tool", `String "missing_operator_tool");
            ("created_at", `String (Types.now_iso ()));
            ("expires_at", `Null);
          ]
      in
      Coord_utils.write_json config path (`List [ entry_json ]);
      let ctx = operator_ctx env sw config "operator" in
      (match
         Operator_control.confirm_json ctx
           (`Assoc [ ("actor", `String "operator"); ("confirm_token", `String token) ])
       with
      | Ok _ -> Alcotest.fail "expected delegated action failure"
      | Error err ->
          Alcotest.(check bool) "non-empty error" true (String.length err > 0));
      let pending_confirms =
        Operator_control.pending_confirms_json ~actor:"operator" config
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm retained" 1 (List.length pending_confirms);
      Alcotest.(check string) "same token retained" token
        Yojson.Safe.Util.(List.hd pending_confirms |> member "token" |> to_string))

(* test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn
   removed: depended on team session start/update which is no longer available. *)
