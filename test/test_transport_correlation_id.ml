module Types = Masc_domain

(** Transport correlation identifier and HTTP actor-injection tests. *)

open Alcotest

module Http_transport = Server_mcp_transport_http
module Actor_injection = Server_mcp_actor_injection
module Auth = Masc.Auth

let setup_test_workspace () =
  let unique_id =
    Printf.sprintf "masc-session-coverage-%d-%d"
      (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))
  in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_test_workspace dir =
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()

let test_is_valid_simple () =
  check bool "simple" true (Transport_correlation_id.is_valid "abc123")

let test_is_valid_empty () =
  check bool "empty" false (Transport_correlation_id.is_valid "")

let test_is_valid_space () =
  check bool "space" false (Transport_correlation_id.is_valid "test id")

let test_generate_uuid_v7 () =
  let id = Transport_correlation_id.generate () in
  match Random_id.parse_uuid_v7 id with
  | Ok parsed -> check string "canonical" id parsed
  | Error error -> fail error

let test_generate_unique () =
  let id1 = Transport_correlation_id.generate () in
  let id2 = Transport_correlation_id.generate () in
  check bool "different" true (id1 <> id2)

let test_resolve_missing_rejects () =
  match Transport_correlation_id.resolve None with
  | Error Transport_correlation_id.Missing -> ()
  | Error error -> fail (Transport_correlation_id.error_to_string error)
  | Ok id -> fail ("unexpected generated id: " ^ id)

let test_resolve_explicit_preserves () =
  match Transport_correlation_id.resolve (Some "observer-1") with
  | Ok value -> check string "explicit" "observer-1" value
  | Error error -> fail (Transport_correlation_id.error_to_string error)

let test_resolve_invalid_rejects () =
  match Transport_correlation_id.resolve (Some "invalid id") with
  | Error Transport_correlation_id.Invalid_visible_ascii -> ()
  | Error Transport_correlation_id.Missing ->
    fail "an explicit identifier was supplied, so Missing is not reachable here"
  | Ok id -> fail ("unexpected fallback id: " ^ id)

let tool_arguments_of_body body =
  let open Yojson.Safe.Util in
  Yojson.Safe.from_string body
  |> member "params"
  |> member "arguments"

let test_inject_agent_name_adds_internal_actor_when_missing () =
  let body =
    {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_status","arguments":{"days":7}},"id":1}|}
  in
  let args =
    Http_transport.inject_agent_name_into_body ~agent_name:"codex" body
    |> tool_arguments_of_body
  in
  let open Yojson.Safe.Util in
  check (option string) "injects _agent_name" (Some "codex")
    (member "_agent_name" args |> to_string_option);
  check (option int) "keeps other args" (Some 7)
    (member "days" args |> to_int_option)

let test_inject_agent_name_preserves_tool_target_by_default () =
  let body =
    {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_agent_fitness","arguments":{"agent_name":"target-keeper","days":7}},"id":1}|}
  in
  let args =
    Http_transport.inject_agent_name_into_body ~agent_name:"codex" body
    |> tool_arguments_of_body
  in
  let open Yojson.Safe.Util in
  check (option string) "does not add _agent_name" None
    (member "_agent_name" args |> to_string_option);
  check (option string) "keeps tool target agent_name" (Some "target-keeper")
    (member "agent_name" args |> to_string_option)

let test_inject_agent_name_rewrites_internal_actor_only () =
  let body =
    {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_agent_fitness","arguments":{"_agent_name":"dashboard","agent_name":"target-keeper","days":7}},"id":1}|}
  in
  let args =
    Http_transport.inject_agent_name_into_body
      ~rewrite_existing:true ~agent_name:"codex" body
    |> tool_arguments_of_body
  in
  let open Yojson.Safe.Util in
  check (option string) "rewrites _agent_name" (Some "codex")
    (member "_agent_name" args |> to_string_option);
  check (option string) "preserves target agent_name" (Some "target-keeper")
    (member "agent_name" args |> to_string_option)

let test_actor_injection_reducer_skips_absent_actor () =
  let body =
    {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_status","arguments":{"days":7}},"id":1}|}
  in
  check string "body unchanged without actor" body
    (Actor_injection.reduce ~actor:None ~auth_token:(Some "token") body)

let test_actor_injection_reducer_rewrites_with_http_auth () =
  let body =
    {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_keeper_status","arguments":{"_agent_name":"dashboard","token":"stale-token","name":"sangsu"}},"id":1}|}
  in
  let args =
    Actor_injection.reduce ~actor:(Some "codex") ~auth_token:(Some "token") body
    |> tool_arguments_of_body
  in
  let open Yojson.Safe.Util in
  check (option string) "actor reducer rewrites _agent_name" (Some "codex")
    (member "_agent_name" args |> to_string_option);
  check (option string) "actor reducer strips stale token" None
    (member "token" args |> to_string_option);
  check (option string) "actor reducer preserves target name" (Some "sangsu")
    (member "name" args |> to_string_option)

let test_body_with_canonical_http_actor_uses_token_owner () =
  let dir = setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_workspace dir)
    (fun () ->
      let raw_token = "codex-token" in
      (match
         Auth.save_raw_token_credential dir ~agent_name:"codex"
           ~role:Masc_domain.Worker ~raw_token
       with
       | Ok _ -> ()
       | Error e -> fail (Masc_domain.masc_error_to_string e));
      let headers =
        Httpun.Headers.of_list
          [
            ("authorization", "Bearer " ^ raw_token);
            ("x-masc-agent", "dashboard");
          ]
      in
      let request = Httpun.Request.create ~headers `POST "/mcp" in
      let body =
        {|{"jsonrpc":"2.0","method":"tools/call","params":{"name":"masc_keeper_status","arguments":{"_agent_name":"dashboard","token":"stale-token","name":"sangsu"}},"id":1}|}
      in
      let args =
        Http_transport.body_with_canonical_http_actor ~base_path:dir
          ~auth_token:(Some raw_token) request body
        |> tool_arguments_of_body
      in
      let open Yojson.Safe.Util in
      check (option string) "token owner rewrites stale dashboard actor"
        (Some "codex")
        (member "_agent_name" args |> to_string_option);
      check (option string) "http auth strips stale argument token" None
        (member "token" args |> to_string_option);
      check (option string) "tool target arg preserved" (Some "sangsu")
        (member "name" args |> to_string_option))

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Transport_correlation_id" [
    "is_valid", [
      test_case "simple" `Quick test_is_valid_simple;
      test_case "empty" `Quick test_is_valid_empty;
      test_case "space" `Quick test_is_valid_space;
    ];
    "generate", [
      test_case "uuid v7" `Quick test_generate_uuid_v7;
      test_case "unique" `Quick test_generate_unique;
    ];
    "resolve", [
      test_case "missing rejects" `Quick test_resolve_missing_rejects;
      test_case "explicit preserves" `Quick test_resolve_explicit_preserves;
      test_case "invalid rejects" `Quick test_resolve_invalid_rejects;
    ];
    "inject_agent_name", [
      test_case "adds internal actor when missing" `Quick
        test_inject_agent_name_adds_internal_actor_when_missing;
      test_case "preserves tool target by default" `Quick
        test_inject_agent_name_preserves_tool_target_by_default;
      test_case "rewrite_existing only rewrites _agent_name" `Quick
        test_inject_agent_name_rewrites_internal_actor_only;
      test_case "reducer skips absent actor" `Quick
        test_actor_injection_reducer_skips_absent_actor;
      test_case "reducer rewrites actor and strips token with http auth" `Quick
        test_actor_injection_reducer_rewrites_with_http_auth;
      test_case "canonical http actor uses token owner" `Quick
        test_body_with_canonical_http_actor_uses_token_owner;
    ];
  ]
