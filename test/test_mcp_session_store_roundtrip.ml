(** Roundtrip tests for persisted MCP session records.

    Verifies that the ppx-generated serializers produce output compatible
    with the previous manual JSON construction, and that deserialization
    handles both complete and partial input correctly. *)

open Masc

let () =
  let open Alcotest in
  run "mcp_session_store_roundtrip"
    [
      ( "mcp_session_record",
        [
          test_case "roundtrip with agent_name" `Quick (fun () ->
              let s : Mcp_session_store.mcp_session_record =
                {
                  id = "sess-001";
                  agent_name = Some "claude";
                  created_at = 1711234567.0;
                  last_seen = 1711234890.0;
                }
              in
              let json =
                Mcp_session_store.mcp_session_to_json s
              in
              let s' =
                Mcp_session_store.mcp_session_of_json json
              in
              check (option pass) "roundtrip succeeds" (Some ()) (Option.map (fun _ -> ()) s');
              let s' = Option.get s' in
              check string "id" s.id s'.id;
              check (option string) "agent_name" s.agent_name s'.agent_name;
              check (float 0.001) "created_at" s.created_at s'.created_at;
              check (float 0.001) "last_seen" s.last_seen s'.last_seen);
          test_case "roundtrip without agent_name" `Quick (fun () ->
              let s : Mcp_session_store.mcp_session_record =
                {
                  id = "sess-002";
                  agent_name = None;
                  created_at = 1711234567.0;
                  last_seen = 1711234890.0;
                }
              in
              let json =
                Mcp_session_store.mcp_session_to_json s
              in
              let s' =
                Mcp_session_store.mcp_session_of_json json
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
                Mcp_session_store.mcp_session_of_json json
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
                Mcp_session_store.mcp_session_of_json json
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
                Mcp_session_store.mcp_session_of_json json
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
                Mcp_session_store.mcp_session_of_json json
              in
              check (option pass) "extra keys ignored" (Some ()) (Option.map (fun _ -> ()) s));
          test_case "invalid JSON returns None" `Quick (fun () ->
              let json = `String "not-a-record" in
              let s =
                Mcp_session_store.mcp_session_of_json json
              in
              check (option pass) "invalid returns None" None (Option.map (fun _ -> ()) s));
        ] );
    ]
