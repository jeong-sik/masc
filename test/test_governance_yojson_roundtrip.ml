(** Roundtrip tests for ppx_deriving_yojson migration of governance types.

    Verifies that the ppx-generated serializers produce output compatible
    with the previous manual JSON construction, and that deserialization
    handles both complete and partial input correctly. *)

open Masc

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let config_with_masc_file prefix =
  let base_path = temp_dir prefix in
  let masc_path = Filename.concat base_path ".masc" in
  let oc = open_out masc_path in
  close_out oc;
  Workspace.default_config base_path

let () =
  let open Alcotest in
  run "governance_yojson_roundtrip"
    [
      ( "mcp_session_record",
        [
          test_case "roundtrip with agent_name" `Quick (fun () ->
              let s : Mcp_server_eio_governance.mcp_session_record =
                {
                  id = "sess-001";
                  agent_name = Some "claude";
                  created_at = 1711234567.0;
                  last_seen = 1711234890.0;
                }
              in
              let json =
                Mcp_server_eio_governance.mcp_session_to_json s
              in
              let s' =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              check (option pass) "roundtrip succeeds" (Some ()) (Option.map (fun _ -> ()) s');
              let s' = Option.get s' in
              check string "id" s.id s'.id;
              check (option string) "agent_name" s.agent_name s'.agent_name;
              check (float 0.001) "created_at" s.created_at s'.created_at;
              check (float 0.001) "last_seen" s.last_seen s'.last_seen);
          test_case "roundtrip without agent_name" `Quick (fun () ->
              let s : Mcp_server_eio_governance.mcp_session_record =
                {
                  id = "sess-002";
                  agent_name = None;
                  created_at = 1711234567.0;
                  last_seen = 1711234890.0;
                }
              in
              let json =
                Mcp_server_eio_governance.mcp_session_to_json s
              in
              let s' =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              let s' = Option.get s' in
              check (option string) "agent_name is None" None s'.agent_name);
          test_case "backward compat: parse old-format JSON" `Quick (fun () ->
              (* JSON matching the structure the manual serializer produced *)
              let json =
                `Assoc
                  [
                    ("id", `String "legacy-sess");
                    ("agent_name", `Null);
                    ("created_at", `Float 1000.0);
                    ("last_seen", `Float 2000.0);
                  ]
              in
              let s =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              let s = Option.get s in
              check string "id" "legacy-sess" s.id;
              check (option string) "agent_name" None s.agent_name);
          test_case "backward compat: integer timestamps" `Quick (fun () ->
              (* JSON with Int instead of Float for timestamps *)
              let json =
                `Assoc
                  [
                    ("id", `String "int-ts-sess");
                    ("agent_name", `String "gemini");
                    ("created_at", `Int 1711234567);
                    ("last_seen", `Int 1711234890);
                  ]
              in
              let s =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              let s = Option.get s in
              check (float 0.001) "created_at from int" 1711234567.0 s.created_at;
              check (float 0.001) "last_seen from int" 1711234890.0 s.last_seen);
          test_case "missing agent_name key" `Quick (fun () ->
              (* JSON without agent_name key at all *)
              let json =
                `Assoc
                  [
                    ("id", `String "no-agent");
                    ("created_at", `Float 1000.0);
                    ("last_seen", `Float 2000.0);
                  ]
              in
              let s =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              let s = Option.get s in
              check (option string) "agent_name defaults to None" None s.agent_name);
          test_case "extra keys ignored" `Quick (fun () ->
              let json =
                `Assoc
                  [
                    ("id", `String "extra-keys");
                    ("agent_name", `String "codex");
                    ("created_at", `Float 1000.0);
                    ("last_seen", `Float 2000.0);
                    ("extra_field", `String "should be ignored");
                  ]
              in
              let s =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              check (option pass) "extra keys ignored" (Some ()) (Option.map (fun _ -> ()) s));
          test_case "invalid JSON returns None" `Quick (fun () ->
              let json = `String "not-a-record" in
              let s =
                Mcp_server_eio_governance.mcp_session_of_json json
              in
              check (option pass) "invalid returns None" None (Option.map (fun _ -> ()) s));
        ] );
      ( "governance_config",
        [
          test_case "save roundtrip via to_yojson" `Quick (fun () ->
              let g : Mcp_server_eio_governance.governance_config =
                {
                  level = "production";
                  audit_enabled = true;
                  anomaly_detection = false;
                }
              in
              let json =
                Mcp_server_eio_governance.governance_config_to_yojson g
              in
              match
                Mcp_server_eio_governance.governance_config_of_yojson json
              with
              | Ok g' ->
                  Alcotest.(check string) "level" g.level g'.level;
                  Alcotest.(check bool) "audit" g.audit_enabled g'.audit_enabled;
                  Alcotest.(check bool) "anomaly" g.anomaly_detection g'.anomaly_detection
              | Error msg -> Alcotest.failf "governance roundtrip failed: %s" msg);
          test_case "extra keys in governance JSON" `Quick (fun () ->
              let json =
                `Assoc
                  [
                    ("level", `String "development");
                    ("audit_enabled", `Bool false);
                    ("anomaly_detection", `Bool false);
                    ("updated_at", `String "2026-03-25T00:00:00Z");
                  ]
              in
              match
                Mcp_server_eio_governance.governance_config_of_yojson json
              with
              | Ok g ->
                  Alcotest.(check string) "level" "development" g.level;
                  Alcotest.(check bool) "audit" false g.audit_enabled
              | Error msg ->
                  Alcotest.failf "should ignore extra keys: %s" msg);
          test_case "save_governance_result reports write failure" `Quick (fun () ->
              let config = config_with_masc_file "governance-save-result-" in
              let g : Mcp_server_eio_governance.governance_config =
                {
                  level = "production";
                  audit_enabled = true;
                  anomaly_detection = false;
                }
              in
              match Mcp_server_eio_governance.save_governance_result config g with
              | Ok () -> Alcotest.fail "save_governance_result hid write failure"
              | Error msg ->
                  Alcotest.(check bool)
                    "write failure has diagnostic"
                    true
                    (String.length msg > 0));
          test_case "save_mcp_sessions_result reports write failure" `Quick (fun () ->
              let config = config_with_masc_file "mcp-sessions-save-result-" in
              let session : Mcp_server_eio_governance.mcp_session_record =
                {
                  id = "sess-write-failure";
                  agent_name = Some "codex";
                  created_at = 1711234567.0;
                  last_seen = 1711234890.0;
                }
              in
              match
                Mcp_server_eio_governance.save_mcp_sessions_result config [ session ]
              with
              | Ok () -> Alcotest.fail "save_mcp_sessions_result hid write failure"
              | Error msg ->
                  Alcotest.(check bool)
                    "write failure has diagnostic"
                    true
                    (String.length msg > 0));
        ] );
    ]
