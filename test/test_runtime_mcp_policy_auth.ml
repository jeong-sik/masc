open Alcotest

module Policy = Runtime_transport
module Auth = Masc.Auth
module Auth_bridging = Runtime_transport_auth_bridging

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let with_workspace f =
  let dir = Filename.temp_file "masc-runtime-mcp-policy-auth-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let masc_dir = Filename.concat dir Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path
        then
          if Sys.is_directory path
          then (
            Array.iter
              (fun child -> rm_rf (Filename.concat path child))
              (Sys.readdir path);
            Unix.rmdir path)
          else Sys.remove path
      in
      rm_rf dir)
    (fun () ->
       with_env "MASC_BASE_PATH" (Some dir) (fun () ->
         with_env "MASC_BASE_PATH_INPUT" None (fun () ->
           with_env "MASC_HTTP_BASE_URL" (Some "http://127.0.0.1:8935") (fun () ->
             f dir))))
;;

let masc_headers policy =
  policy.Llm_provider.Llm_transport.servers
  |> List.find_map (function
    | Llm_provider.Llm_transport.Http_server { name = "masc"; headers; _ } ->
      Some headers
    | _ -> None)
  |> Option.value ~default:[]
;;

let find_header key headers =
  let key_lc = String.lowercase_ascii key in
  List.find_map
    (fun (actual, value) ->
       if String.equal (String.lowercase_ascii actual) key_lc
       then Some value
       else None)
    headers
;;

let policy_with_tool_names allowed_tool_names =
  {
    Llm_provider.Llm_transport.empty_runtime_mcp_policy with
    servers =
      [
        Llm_provider.Llm_transport.Http_server
          {
            name = "masc";
            url = "http://127.0.0.1:8935/mcp";
            headers = [];
          };
      ];
    allowed_server_names = [ "masc" ];
    allowed_tool_names;
  }
;;

let save_auth_config dir ~enabled ~require_token =
  Auth.save_auth_config dir { Masc_domain.default_auth_config with enabled; require_token }
;;

let save_raw_token dir ~agent_name ~raw_token =
  match
    Auth.save_raw_token_credential_without_expiry dir ~agent_name
      ~role:Masc_domain.Worker ~raw_token
  with
  | Ok credential ->
      let auth_dir = Common.auth_dir_from_base_path ~base_path:dir in
      Auth.save_private_text_file
        (Filename.concat auth_dir (agent_name ^ ".token"))
        raw_token;
      credential
  | Error error ->
      failf "failed to create test credential: %s"
        (Masc_domain.masc_error_to_string error)
;;

let overwrite_raw_token_file dir ~agent_name ~raw_token =
  let auth_dir = Common.auth_dir_from_base_path ~base_path:dir in
  Auth.save_private_text_file (Filename.concat auth_dir (agent_name ^ ".token"))
    raw_token
;;

let test_public_policy_absent_without_required_bearer () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    with_env "MASC_TOKEN" None (fun () ->
      with_env "MASC_INTERNAL_MCP_TOKEN" (Some "internal-token") (fun () ->
        check
          bool
	          "required bearer missing returns no public runtime-MCP policy"
	          true
	          (Option.is_none
	             (Policy.public_mcp_runtime_policy_of_tool_names
	                ~base_path:dir
	                [ "masc_tasks" ])))))
;;

let test_protected_policy_absent_when_workspace_bearer_is_optional () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:false;
    with_env "MASC_TOKEN" None (fun () ->
	      check bool "protected runtime-MCP never emits a headerless policy" true
	        (Option.is_none
	           (Policy.public_mcp_runtime_policy_of_tool_names
	              ~base_path:dir
	              [ "masc_tasks" ]))))
;;

let test_keeper_policy_uses_exact_credential_not_shared_tokens () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    ignore
      (save_raw_token dir ~agent_name:"keeper-rondo-agent"
         ~raw_token:"exact-keeper-token");
    with_env "MASC_TOKEN" (Some "global-token") (fun () ->
      with_env "MASC_INTERNAL_MCP_TOKEN" (Some "shared-internal-token") (fun () ->
        match
	          Policy.runtime_mcp_policy_of_tool_names
	            ~base_path:dir
	            ~agent_name:"keeper-rondo-agent"
	            [ "masc_tasks" ]
        with
        | None -> fail "keeper runtime-MCP policy should use exact credential"
        | Some policy ->
          let headers = masc_headers policy in
          check
            (option string)
            "exact per-keeper Authorization"
            (Some "Bearer exact-keeper-token")
            (find_header "Authorization" headers);
          check
            (option string)
            "shared internal token is not projected"
            None
            (find_header "x-masc-internal-token" headers);
          let projected =
            Policy.runtime_mcp_policy_with_masc_agent_name
              ~agent_name:"keeper-rondo-agent"
              policy
          in
          let projected_headers = masc_headers projected in
          check
            (option string)
            "agent identity header"
            (Some "keeper-rondo-agent")
	            (find_header "x-masc-agent-name" projected_headers);
          check
            (option string)
            "keeper identity header"
            (Some "rondo")
            (find_header "x-masc-keeper-name" projected_headers);
          check
            (option string)
            "identity projection preserves exact Authorization"
            (Some "Bearer exact-keeper-token")
            (find_header "Authorization" projected_headers))))
;;

let test_policy_uses_explicit_base_path_not_ambient_env () =
  with_workspace (fun dir ->
    with_workspace (fun ambient_dir ->
      save_auth_config dir ~enabled:true ~require_token:true;
      save_auth_config ambient_dir ~enabled:true ~require_token:true;
      ignore
        (save_raw_token dir ~agent_name:"keeper-rondo-agent"
           ~raw_token:"explicit-base-token");
      ignore
        (save_raw_token ambient_dir ~agent_name:"keeper-rondo-agent"
           ~raw_token:"ambient-env-token");
      with_env "MASC_BASE_PATH" (Some ambient_dir) (fun () ->
        let build_policy () =
          match
            Policy.runtime_mcp_policy_of_tool_names
              ~base_path:dir
              ~agent_name:"keeper-rondo-agent"
              [ "masc_tasks" ]
          with
          | None -> fail "explicit base path should provide keeper token"
          | Some policy ->
            let headers = masc_headers policy in
            check
              (option string)
              "authorization header comes from explicit base path"
              (Some "Bearer explicit-base-token")
              (find_header "Authorization" headers)
        in
        with_env "MASC_INTERNAL_MCP_TOKEN" (Some "ambient-internal-token") (fun () ->
          with_env "MASC_TOKEN" (Some "ambient-global-token") build_policy))))
;;

let test_unbound_policy_verifies_masc_token () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    ignore
      (save_raw_token dir ~agent_name:"runtime-client-agent"
         ~raw_token:"verified-global-token");
    with_env "MASC_TOKEN" (Some "verified-global-token") (fun () ->
      match
        Policy.public_mcp_runtime_policy_of_tool_names ~base_path:dir
          [ "masc_tasks" ]
      with
      | None -> fail "verified MASC_TOKEN should build an unbound policy"
      | Some policy ->
          check (option string) "verified unbound bearer"
            (Some "Bearer verified-global-token")
            (find_header "Authorization" (masc_headers policy))))
;;

let test_unbound_policy_rejects_unknown_masc_token () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    with_env "MASC_TOKEN" (Some "not-a-workspace-credential") (fun () ->
      check bool "unbound token must resolve to a current credential" true
        (Option.is_none
           (Policy.public_mcp_runtime_policy_of_tool_names ~base_path:dir
              [ "masc_tasks" ]))))
;;

let test_corrupted_per_keeper_raw_token_fails_closed () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    ignore
      (save_raw_token dir ~agent_name:"keeper-rondo-agent"
         ~raw_token:"credential-token");
    overwrite_raw_token_file dir ~agent_name:"keeper-rondo-agent"
      ~raw_token:"corrupted-token";
    check bool "corrupted raw token does not produce a policy" true
      (Option.is_none
         (Policy.runtime_mcp_policy_of_tool_names ~base_path:dir
            ~agent_name:"keeper-rondo-agent" [ "masc_tasks" ]));
    match
      Auth_resolve.resolve_runtime_mcp ~base_path:dir
        ~agent_name:(Some "keeper-rondo-agent")
    with
    | Error
        (Auth_resolve.Credential_verification_failed
          { failure = Auth_resolve.Invalid_token; _ }) ->
        ()
    | Error error ->
        failf "wrong corrupted-token error: %s"
          (Auth_resolve.show_auth_error error)
    | Ok _ -> fail "corrupted token unexpectedly verified")
;;

let test_expired_per_keeper_credential_fails_closed () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    let credential =
      save_raw_token dir ~agent_name:"keeper-rondo-agent"
        ~raw_token:"expired-token"
    in
    Auth.save_credential dir
      { credential with expires_at = Some "2000-01-01T00:00:00Z" };
    check bool "expired credential does not produce a policy" true
      (Option.is_none
         (Policy.runtime_mcp_policy_of_tool_names ~base_path:dir
            ~agent_name:"keeper-rondo-agent" [ "masc_tasks" ]));
    match
      Auth_resolve.resolve_runtime_mcp ~base_path:dir
        ~agent_name:(Some "keeper-rondo-agent")
    with
    | Error
        (Auth_resolve.Credential_verification_failed
          { failure = Auth_resolve.Token_expired _; _ }) ->
        ()
    | Error error ->
        failf "wrong expired-token error: %s"
          (Auth_resolve.show_auth_error error)
    | Ok _ -> fail "expired token unexpectedly verified")
;;

let test_alias_owner_token_is_not_an_exact_keeper_credential () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    ignore
      (save_raw_token dir ~agent_name:"rondo" ~raw_token:"bare-owner-token");
    overwrite_raw_token_file dir ~agent_name:"keeper-rondo-agent"
      ~raw_token:"bare-owner-token";
    check bool "alias-owned token does not produce an exact keeper policy" true
      (Option.is_none
         (Policy.runtime_mcp_policy_of_tool_names ~base_path:dir
            ~agent_name:"keeper-rondo-agent" [ "masc_tasks" ]));
    match
      Auth_resolve.resolve_runtime_mcp ~base_path:dir
        ~agent_name:(Some "keeper-rondo-agent")
    with
    | Error
        (Auth_resolve.Credential_owner_mismatch
          {
            expected_agent_name = "keeper-rondo-agent";
            actual_agent_name = "rondo";
            _;
          }) ->
        ()
    | Error error ->
        failf "wrong alias-owner error: %s" (Auth_resolve.show_auth_error error)
    | Ok _ -> fail "alias-owned token unexpectedly passed exact-owner verification")
;;

let test_bridge_returns_typed_error_instead_of_headerless_policy () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    let policy = policy_with_tool_names [ "masc_plan_set_task" ] in
    match
      Auth_bridging.bridged_runtime_mcp_policy_for_agent ~base_path:dir
        ~agent_name:"keeper-rondo-agent" policy
    with
    | Error (Auth_resolve.Raw_token_unavailable _) -> ()
    | Error error ->
        failf "wrong missing bridge credential error: %s"
          (Auth_resolve.show_auth_error error)
    | Ok policy ->
        failf "bridge silently emitted policy with %d headers"
          (List.length (masc_headers policy)))
;;

let test_bridge_rejects_corrupted_raw_token () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    ignore
      (save_raw_token dir ~agent_name:"keeper-rondo-agent"
         ~raw_token:"bridge-credential-token");
    overwrite_raw_token_file dir ~agent_name:"keeper-rondo-agent"
      ~raw_token:"bridge-corrupted-token";
    let policy = policy_with_tool_names [ "masc_plan_set_task" ] in
    match
      Auth_bridging.bridged_runtime_mcp_policy_for_agent ~base_path:dir
        ~agent_name:"keeper-rondo-agent" policy
    with
    | Error
        (Auth_resolve.Credential_verification_failed
          { failure = Auth_resolve.Invalid_token; _ }) ->
        ()
    | Error error ->
        failf "wrong corrupted bridge credential error: %s"
          (Auth_resolve.show_auth_error error)
    | Ok _ -> fail "bridge accepted corrupted raw token")
;;

let () =
  run
    "runtime_mcp_policy_auth"
    [ ( "auth"
      , [ test_case
            "public policy absent when required bearer is missing"
            `Quick
            test_public_policy_absent_without_required_bearer
        ; test_case
            "protected policy absent when workspace bearer is optional"
            `Quick
            test_protected_policy_absent_when_workspace_bearer_is_optional
	        ; test_case
	            "keeper policy uses exact credential, not shared tokens"
	            `Quick
	            test_keeper_policy_uses_exact_credential_not_shared_tokens
	        ; test_case
	            "policy uses explicit base path instead of ambient env"
	            `Quick
	            test_policy_uses_explicit_base_path_not_ambient_env
	        ; test_case "unbound policy verifies MASC_TOKEN" `Quick
	            test_unbound_policy_verifies_masc_token
	        ; test_case "unbound policy rejects unknown MASC_TOKEN" `Quick
	            test_unbound_policy_rejects_unknown_masc_token
	        ; test_case "corrupted per-keeper token fails closed" `Quick
	            test_corrupted_per_keeper_raw_token_fails_closed
	        ; test_case "expired per-keeper credential fails closed" `Quick
	            test_expired_per_keeper_credential_fails_closed
	        ; test_case "alias owner is not an exact keeper credential" `Quick
	            test_alias_owner_token_is_not_an_exact_keeper_credential
	        ; test_case "bridge missing credential is typed" `Quick
	            test_bridge_returns_typed_error_instead_of_headerless_policy
	        ; test_case "bridge rejects corrupted raw token" `Quick
	            test_bridge_rejects_corrupted_raw_token
	        ] )
    ]
;;
