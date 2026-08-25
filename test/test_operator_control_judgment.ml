module Types = Masc_domain

open Masc
open Test_operator_control_support

let test_digest_workspace_prefers_fresh_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      ignore (Workspace.bind_session config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"Pause the namespace before taking any destructive action."
        ~recommended_action:
          (`Assoc
            [
              ("action_kind", `String "pause_workspace");
              ("resolved_tool", `String "masc_operator_confirm");
              ( "target_type"
              , `String Operator_action_constants.workspace_target_type );
              ("target_id", `Null);
              ("reason", `String "operator judge requires manual gate");
              ("payload_preview", `Assoc [ ("reason", `String "manual review") ]);
            ])
        ~fresh_for_sec:90.0 ();
      Alcotest.(check int) "stored judgments" 1
        (List.length (Operator_judgment.load_all config));
      (match
         Operator_judgment.latest_active config ~surface:"command.namespace"
           ~target_type:Operator_judgment.Workspace ~target_id:None
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected workspace judgment in %s"
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
      let recommended_actions =
        Yojson.Safe.Util.(digest |> member "recommended_actions" |> to_list)
      in
      Alcotest.(check int) "authoritative action reaches top-level projection" 1
        (List.length recommended_actions);
      (match recommended_actions with
       | action :: _ ->
         Alcotest.(check string) "top-level action comes from judgment"
           "pause_workspace"
           Yojson.Safe.Util.(action |> member "action_kind" |> to_string)
       | [] -> Alcotest.fail "expected one authoritative recommendation");
      Alcotest.(check bool) "top-level recommendation summary is authoritative"
        true
        Yojson.Safe.Util.
          (digest |> member "recommendation_summary" |> member "authoritative"
          |> to_bool);
      Alcotest.(check bool) "judgment present" true
        (Yojson.Safe.Util.member "judgment" digest <> `Null))

let test_digest_workspace_ignores_stale_operator_judgment () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      ignore (Workspace.bind_session config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
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
        (Yojson.Safe.Util.member "judgment" digest = `Null);
      Alcotest.(check int) "stale judgment cannot leave fallback actions" 0
        Yojson.Safe.Util.(digest |> member "recommended_actions" |> to_list |> List.length);
      Alcotest.(check int) "stale judgment recommendation summary is empty" 0
        Yojson.Safe.Util.
          (digest |> member "recommendation_summary" |> member "count" |> to_int))

let test_guidance_ignores_unsupported_target_type () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      record_operator_judgment config ~surface:"command.namespace"
        ~target_type:Operator_judgment.Workspace ~target_id:None
        ~summary:"Root guidance must not leak to keeper targets."
        ~fresh_for_sec:90.0 ();
      let fields =
        Operator_digest_guidance.active_guidance ~config
          ~target_type:"keeper" ~target_id:None
          ~fallback_observation_summary:(`Assoc [ ("count", `Int 0) ])
          ~empty_recommendation_summary:(`Assoc [ ("count", `Int 0) ])
      in
      let guidance = `Assoc fields.fields in
      Alcotest.(check string) "judgment owner fallback" "fallback_read_model"
        Yojson.Safe.Util.(guidance |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment unavailable" false
        Yojson.Safe.Util.
          (guidance |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer fallback" "fallback"
        Yojson.Safe.Util.(guidance |> member "active_guidance_layer" |> to_string);
      Alcotest.(check bool) "judgment missing" true
        (Yojson.Safe.Util.member "judgment" guidance = `Null);
      Alcotest.(check int) "fallback cannot synthesize actions" 0
        (List.length fields.recommended_actions))

(* Each surface carries its own freshness default: a namespace judgment goes
   stale in 60s, an intervention in 300s. The selection used to match the
   normalized surface string with a wildcard default of 120s — unreachable,
   because normalize_judgment_surface rejects everything else first, but it
   would have absorbed a third surface in silence. Nothing pinned the two
   values, so collapsing or swapping them was invisible. *)
let test_judgment_freshness_default_is_per_surface () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let ttl_for surface =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [ ("surface", `String surface)
              ; ("target_type", `String "workspace")
              ; ("summary", `String "default freshness probe")
              ; ("confidence", `Float 0.5)
              ; ("evidence_refs", `List [])
              ])
        with
        | Error err -> Alcotest.fail err
        | Ok json ->
          let open Yojson.Safe.Util in
          let judgment = json |> member "judgment" in
          let generated = judgment |> member "generated_at_unix" |> to_float in
          let fresh_until = judgment |> member "fresh_until_unix" |> to_float in
          Float.round (fresh_until -. generated)
      in
      Alcotest.(check (float 0.5))
        "command.namespace default ttl" 60.0 (ttl_for "command.namespace");
      Alcotest.(check (float 0.5))
        "intervene default ttl" 300.0 (ttl_for "intervene"))

let test_operator_judgment_write_and_latest_roundtrip () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let written =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [
                ("surface", `String "command.namespace");
                ("target_type", `String "workspace");
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
            (`Assoc
              [ ("surface", `String "command.namespace"); ("target_type", `String "workspace") ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "latest ok" "ok"
        Yojson.Safe.Util.(latest |> member "status" |> to_string);
      Alcotest.(check string) "latest summary"
        "Operator judge requests a human checkpoint."
        Yojson.Safe.Util.(latest |> member "judgment" |> member "summary" |> to_string))

let test_operator_judgment_rejects_retired_target_type_aliases () =
  Alcotest.(check bool)
    "namespace no longer parses"
    true
    (Option.is_none (Operator_judgment.target_type_of_string "namespace"));
  Alcotest.(check (result string string))
    "digest rejects namespace"
    (Error Operator_action_constants.workspace_target_type_error)
    (Operator_digest_types.normalize_digest_target_type (Some "namespace"));
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      match
        Operator_control.judgment_write_json ctx
          (`Assoc
            [
              ("surface", `String "command.namespace");
              ("target_type", `String "namespace");
              ("summary", `String "Retired alias must be rejected.");
            ])
      with
      | Ok _ -> Alcotest.fail "namespace target_type should be rejected"
      | Error err ->
          Alcotest.(check string)
            "write rejects namespace"
            Operator_action_constants.workspace_target_type_error err)

let test_operator_judgment_requires_numeric_timestamps () =
  let base_fields =
    [ ("target_type", `String "workspace")
    ; ("generated_at_unix", `Float 1.0)
    ; ("fresh_until_unix", `Float 2.0)
    ]
  in
  let without key = `Assoc (List.remove_assoc key base_fields) in
  Alcotest.(check (result reject string))
    "missing generated timestamp is rejected"
    (Error "missing generated_at_unix")
    (Operator_judgment.of_yojson (without "generated_at_unix"));
  Alcotest.(check (result reject string))
    "missing freshness timestamp is rejected"
    (Error "missing fresh_until_unix")
    (Operator_judgment.of_yojson (without "fresh_until_unix"));
  let invalid =
    `Assoc
      (("generated_at_unix", `String "1970-01-01T00:00:01Z")
       :: List.remove_assoc "generated_at_unix" base_fields)
  in
  Alcotest.(check (result reject string))
    "display timestamp is not silently reparsed"
    (Error "invalid generated_at_unix")
    (Operator_judgment.of_yojson invalid)

(* [confidence] used to default to 0.5 when omitted and was clamped into range
   on the way to disk. Both spellings put a number the judge never stated into
   the operator digest, next to ["authoritative": true]. No code compares the
   value, so a fabricated one is indistinguishable from a stated one — the
   operator is the only reader, and they cannot tell. *)
let test_operator_judgment_requires_stated_confidence () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let write confidence_fields =
        Operator_control.judgment_write_json ctx
          (`Assoc
            ([ ("surface", `String "command.namespace");
               ("target_type", `String "workspace");
               ("summary", `String "Judgment without a stated confidence.") ]
             @ confidence_fields))
      in
      List.iter
        (fun (label, fields) ->
          match write fields with
          | Error message ->
            Alcotest.(check bool)
              (label ^ " names the field") true
              (Astring.String.is_infix ~affix:"confidence" message)
          | Ok _ -> Alcotest.failf "%s must be rejected, got Ok" label)
        [ ("omitted confidence", []);
          ("string confidence", [ ("confidence", `String "0.9") ]);
          ("null confidence", [ ("confidence", `Null) ]);
          ("negative confidence", [ ("confidence", `Float (-0.1)) ]);
          ("confidence above one", [ ("confidence", `Float 1.1) ]) ];
      (* An integer 1 is a number a JSON encoder may emit for 1.0. *)
      match write [ ("confidence", `Int 1) ] with
      | Ok _ -> ()
      | Error message -> Alcotest.failf "integer confidence must be accepted: %s" message)


let tests =
  [
    Alcotest.test_case "digest prefers fresh operator judgment" `Quick
      test_digest_workspace_prefers_fresh_operator_judgment;
    Alcotest.test_case "digest ignores stale operator judgment" `Quick
      test_digest_workspace_ignores_stale_operator_judgment;
    Alcotest.test_case "guidance ignores unsupported target type" `Quick
      test_guidance_ignores_unsupported_target_type;
    Alcotest.test_case "freshness default is per surface" `Quick
      test_judgment_freshness_default_is_per_surface;
    Alcotest.test_case "operator judgment write/latest roundtrip" `Quick
      test_operator_judgment_write_and_latest_roundtrip;
    Alcotest.test_case "rejects retired target type aliases" `Quick
      test_operator_judgment_rejects_retired_target_type_aliases;
    Alcotest.test_case "requires numeric timestamps" `Quick
      test_operator_judgment_requires_numeric_timestamps;
    Alcotest.test_case "requires a stated confidence" `Quick
      test_operator_judgment_requires_stated_confidence;
  ]

let () = Alcotest.run "operator_control_judgment" [ ("operator_control_judgment", tests) ]
