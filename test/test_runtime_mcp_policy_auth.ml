open Alcotest

module Policy = Runtime_transport
module Auth = Masc.Auth

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

let save_auth_config dir ~enabled ~require_token =
  Auth.save_auth_config dir { Masc_domain.default_auth_config with enabled; require_token }
;;

let save_raw_token dir ~agent_name ~raw_token =
  let auth_dir = Common.auth_dir_from_base_path ~base_path:dir in
  Auth.save_private_text_file (Filename.concat auth_dir (agent_name ^ ".token")) raw_token
;;

let test_policy_absent_without_required_bearer () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    with_env "MASC_TOKEN" None (fun () ->
      with_env "MASC_INTERNAL_MCP_TOKEN" (Some "internal-token") (fun () ->
        check
          bool
          "required bearer missing returns no runtime-MCP policy"
          true
          (Option.is_none
             (Policy.runtime_mcp_policy_of_tool_names
                ~base_path:dir
                [ "masc_tasks" ])))))
;;

let test_headerless_policy_when_bearer_not_required () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:false;
    with_env "MASC_TOKEN" None (fun () ->
      match
        Policy.runtime_mcp_policy_of_tool_names
          ~base_path:dir
          [ "masc_tasks" ]
      with
      | None -> fail "auth-optional workspace should allow headerless runtime-MCP policy"
      | Some policy ->
        check (list (pair string string)) "no auth headers" [] (masc_headers policy)))
;;

let test_keeper_policy_uses_per_keeper_token_independent_of_tool_name () =
  with_workspace (fun dir ->
    save_auth_config dir ~enabled:true ~require_token:true;
    let keeper_token = "deterministic-keeper-token" in
    save_raw_token
      dir
      ~agent_name:"keeper-rondo-agent"
      ~raw_token:keeper_token;
    with_env "MASC_TOKEN" None (fun () ->
      match
        Policy.runtime_mcp_policy_of_tool_names
          ~base_path:dir
          ~agent_name:"keeper-rondo-agent"
          [ "masc_future_tool_not_in_catalog" ]
      with
      | None -> fail "keeper runtime-MCP policy should use its persisted token"
      | Some policy ->
        let headers = masc_headers policy in
        check
          (option string)
          "per-Keeper bearer"
          (Some ("Bearer " ^ keeper_token))
          (find_header "Authorization" headers);
        check
          (option string)
          "exact agent identity header"
          (Some "keeper-rondo-agent")
          (find_header "x-masc-agent-name" headers);
        check
          (option string)
          "no role inferred from agent-name spelling"
          None
          (find_header "x-masc-keeper-name" headers);
        check
          (list string)
          "caller schema name is preserved without catalog filtering"
          [ "masc_future_tool_not_in_catalog" ]
          policy.allowed_tool_names))
;;

let test_policy_uses_explicit_base_path_not_ambient_env () =
  with_workspace (fun dir ->
    with_workspace (fun ambient_dir ->
      save_auth_config dir ~enabled:true ~require_token:true;
      save_auth_config ambient_dir ~enabled:true ~require_token:true;
      save_raw_token
        dir
        ~agent_name:"keeper-rondo-agent"
        ~raw_token:"explicit-base-token";
      save_raw_token
        ambient_dir
        ~agent_name:"keeper-rondo-agent"
        ~raw_token:"ambient-env-token";
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
        with_env "MASC_INTERNAL_MCP_TOKEN" None (fun () ->
          with_env "MASC_TOKEN" None build_policy))))
;;

let () =
  run
    "runtime_mcp_policy_auth"
    [ ( "auth"
      , [ test_case
            "policy absent when required bearer is missing"
            `Quick
            test_policy_absent_without_required_bearer
        ; test_case
            "policy allowed when bearer is optional"
            `Quick
            test_headerless_policy_when_bearer_not_required
        ; test_case
            "keeper policy uses per-Keeper token for any supplied schema"
            `Quick
            test_keeper_policy_uses_per_keeper_token_independent_of_tool_name
        ; test_case
            "policy uses explicit base path instead of ambient env"
            `Quick
            test_policy_uses_explicit_base_path_not_ambient_env
        ] )
    ]
;;
