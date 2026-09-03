module Types = Masc_domain

open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

(* With_expiry path: caller passes the default env var name, mint
   honors it verbatim. Agent_name is just a free string — the server
   no longer derives env names from it. *)
let test_login_with_expiry_uses_caller_env_var () =
  with_temp_dir "auth-login" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"test-agent" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
      failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
      let cfg = Auth.load_auth_config base_path in
      check bool "auth enabled" true cfg.enabled;
      check bool "require token" true cfg.require_token;
      check string "agent" "test-agent" report.agent_name;
      check string "role" "worker"
        (Masc_domain.agent_role_to_string report.role);
      check (option string) "worker login creates no bootstrap admin" None
        (Auth.read_initial_admin base_path);
      check string "client env passthrough" "MASC_TOKEN"
        report.mcp_token_env_var;
      check bool "raw token file exists" true
        (Sys.file_exists report.raw_token_file);
      (match
         Auth.find_credential_by_token base_path
           ~token:report.bearer_token
       with
       | Ok cred ->
           check string "token owner" "test-agent" cred.agent_name
       | Error err ->
           failf "minted token did not verify: %s"
             (Masc_domain.masc_error_to_string err));
      (match
         Auth.check_permission base_path ~agent_name:"test-agent"
           ~token:(Some report.bearer_token)
           ~permission:Masc_domain.CanInit
       with
       | Ok () -> fail "worker login token must not have admin permission"
       | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
       | Error err ->
           failf "expected forbidden for worker admin action: %s"
             (Masc_domain.masc_error_to_string err));
      (match
         Auth.resolve_role base_path ~agent_name:"test-agent"
           ~token:(Some report.bearer_token)
       with
       | Ok Masc_domain.Worker -> ()
       | Ok role ->
           failf "expected worker effective role, got %s"
             (Masc_domain.agent_role_to_string role)
       | Error err ->
           failf "expected worker effective role: %s"
             (Masc_domain.masc_error_to_string err));
      let shell = Auth_login.render_shell report in
      check bool "shell exports caller-named env var" true
        (String_util.string_contains_substring ~needle:"export MASC_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json status" "ok"
        (Yojson.Safe.Util.member "status" json
        |> Yojson.Safe.Util.to_string);
      check (list string) "json login schema"
        [ "agent_name"
        ; "auth_change"
        ; "auth_config_path"
        ; "base_path"
        ; "bearer_token"
        ; "dashboard_url"
        ; "mcp_client"
        ; "mcp_url"
        ; "raw_token_file"
        ; "role"
        ; "status"
        ]
        (json
         |> Yojson.Safe.Util.to_assoc
         |> List.map fst
         |> List.sort String.compare);
      check string "json raw token file" report.raw_token_file
        (Yojson.Safe.Util.member "raw_token_file" json
         |> Yojson.Safe.Util.to_string);
      check string "json mcp url" report.mcp_url
        (Yojson.Safe.Util.member "mcp_url" json
         |> Yojson.Safe.Util.to_string)

(* Long_lived path: caller passes an arbitrary env var name and
   asks for a no-expiry credential. The server passes the name
   through verbatim and stores a credential with expires_at=None.
   The choice is the caller's — there is no agent-name match. *)
let test_login_long_lived_passes_env_var_through () =
  with_temp_dir "auth-login-long-lived" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"long-lived-daemon" ~role:Masc_domain.Worker
      ~token_env_var:"CUSTOM_MCP_TOKEN"
      ~token_lifetime:Auth_login.Long_lived ()
  with
  | Error err ->
      failf "long-lived login mint failed: %s"
        (Masc_domain.masc_error_to_string err)
  | Ok report ->
      check string "agent" "long-lived-daemon" report.agent_name;
      check string "client env passthrough" "CUSTOM_MCP_TOKEN"
        report.mcp_token_env_var;
      (match
         Auth.find_credential_by_token base_path
           ~token:report.bearer_token
       with
       | Ok cred ->
           check (option string) "long-lived token has no expires_at"
             None cred.expires_at
       | Error err ->
           failf "minted long-lived token did not verify: %s"
             (Masc_domain.masc_error_to_string err));
      let shell = Auth_login.render_shell report in
      check bool "shell exports caller-named env var" true
        (String_util.string_contains_substring ~needle:"export CUSTOM_MCP_TOKEN="
           shell);
      let json = Auth_login.to_yojson report in
      check string "json client env passthrough" "CUSTOM_MCP_TOKEN"
        (Yojson.Safe.Util.member "mcp_client" json
         |> Yojson.Safe.Util.member "token_env_var"
         |> Yojson.Safe.Util.to_string)

(* Expires_in_hours path: the caller names the window and the credential
   carries it. The workspace default is a day, so a credential that outlives a
   day is proof the caller's number won rather than the config's.

   The bound is checked by bracketing rather than parsing: rfc3339 UTC strings
   are fixed-width and zero-padded, so string order is time order, and a
   two-day bracket around the target cannot flake on clock skew or on the test
   running across a midnight. *)
let test_login_expires_in_hours_outlives_the_config_window () =
  with_temp_dir "auth-login-named-window" @@ fun base_path ->
  let hours = 24 * 30 in
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"month-long-client" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:(Auth_login.Expires_in_hours hours) ()
  with
  | Error err ->
      failf "named-window login mint failed: %s"
        (Masc_domain.masc_error_to_string err)
  | Ok report -> (
      match
        Auth.find_credential_by_token base_path ~token:report.bearer_token
      with
      | Error err ->
          failf "minted named-window token did not verify: %s"
            (Masc_domain.masc_error_to_string err)
      | Ok cred -> (
          match cred.expires_at with
          | None ->
              fail "a named window must still expire; this one never does"
          | Some expires_at ->
              let day = 24. *. 3600. in
              let at offset_days =
                Masc_domain.iso8601_of_unix_seconds
                  (Unix.gettimeofday () +. (offset_days *. day))
              in
              check bool "later than twenty-nine days out" true
                (String.compare expires_at (at 29.) > 0);
              check bool "sooner than thirty-one days out" true
                (String.compare expires_at (at 31.) < 0)))

(* A window the auth config could never hold comes back as an error. The config
   path answers the same question by raising, because a config that got past
   decoding cannot be out of range; a number a caller computed can be, and the
   caller is the one who can report it. *)
let test_login_rejects_a_window_outside_the_bound () =
  with_temp_dir "auth-login-impossible-window" @@ fun base_path ->
  let mint hours =
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"impossible-window" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:(Auth_login.Expires_in_hours hours) ()
  in
  check bool "zero hours is not a window" true (Result.is_error (mint 0));
  check bool "a negative window is not a window" true
    (Result.is_error (mint (-1)));
  check bool "beyond a year is not a window" true
    (Result.is_error (mint 8_761));
  check bool "a year exactly still is" true (Result.is_ok (mint 8_760))

(* The two flags that can name a lifetime name different ones, so asking for
   both is refused rather than resolved by precedence. A precedence rule would
   quietly hand back the policy the operator did not ask for, and how long a
   bearer lives is not something to pick for them. *)
let test_lifetime_flags_refuse_to_pick_for_the_operator () =
  let asked ~no_expiry ~expiry_hours =
    Auth_login.lifetime_of_flags ~no_expiry ~expiry_hours
  in
  check bool "neither flag leaves the workspace's window" true
    (asked ~no_expiry:false ~expiry_hours:None = Ok Auth_login.With_expiry);
  check bool "--no-expiry alone means no expiry" true
    (asked ~no_expiry:true ~expiry_hours:None = Ok Auth_login.Long_lived);
  check bool "--expiry-hours alone names the window" true
    (asked ~no_expiry:false ~expiry_hours:(Some 720)
     = Ok (Auth_login.Expires_in_hours 720));
  check bool "both together is refused, not resolved" true
    (Result.is_error (asked ~no_expiry:true ~expiry_hours:(Some 720)))

let test_login_url_uses_uri_components () =
  with_temp_dir "auth-login-uri" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"2001:db8::1" ~port:8935
      ~agent_name:"agent +&" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN" ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
    failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
    let dashboard = Uri.of_string report.dashboard_url in
    check (option string) "IPv6 host" (Some "2001:db8::1") (Uri.host dashboard);
    check (option int) "port" (Some 8935) (Uri.port dashboard);
    check string "dashboard path" "/dashboard" (Uri.path dashboard);
    check (option string) "agent query round-trip" (Some "agent +&")
      (Uri.get_query_param dashboard "agent");
    let mcp = Uri.of_string report.mcp_url in
    check (option string) "MCP IPv6 host" (Some "2001:db8::1") (Uri.host mcp);
    check string "MCP path" "/mcp" (Uri.path mcp)

(* --host is the flag for the address to *bind*, and its own help text offers
   0.0.0.0. These two URLs are what the operator opens and pastes, so a
   wildcard has to become something dialable before it is printed. Asserting
   both because they are built separately and only one used to be checked. *)
let test_login_urls_do_not_advertise_a_bind_wildcard () =
  with_temp_dir "auth-login-wildcard" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"0.0.0.0" ~port:8935 ~agent_name:"agent"
      ~role:Masc_domain.Worker ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
    failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
    check (option string) "dashboard URL names a reachable host"
      (Some "127.0.0.1")
      (Uri.host (Uri.of_string report.dashboard_url));
    check (option string) "MCP URL names a reachable host" (Some "127.0.0.1")
      (Uri.host (Uri.of_string report.mcp_url));
    check (option string) "the token still rides the dashboard URL"
      (Some report.bearer_token)
      (Uri.get_query_param (Uri.of_string report.dashboard_url) "token")

(* What login persists is what a local client can read back. Asserting the
   round trip rather than the path keeps the two sides free to move together
   and pinned to each other. *)
let test_persisted_token_round_trips () =
  with_temp_dir "auth-login-read" @@ fun base_path ->
  check (option string) "absent agent has no persisted token" None
    (Auth_login.read_persisted_token ~base_path ~agent_name:"masc-tui");
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"masc-tui" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN"
      ~token_lifetime:Auth_login.With_expiry ()
  with
  | Error err ->
      failf "login mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
      check (option string) "the client reads back what login wrote"
        (Some report.bearer_token)
        (Auth_login.read_persisted_token ~base_path ~agent_name:"masc-tui");
      check (option string) "another agent's file is not borrowed" None
        (Auth_login.read_persisted_token ~base_path ~agent_name:"other-agent")

let string_contains haystack needle =
  let nlen = String.length needle and hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else begin
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then found := true
    done;
    !found
  end

let test_mcp_client_config_renders_each_client () =
  with_temp_dir "auth-login-mcp" @@ fun base_path ->
  match
    Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
      ~agent_name:"mcp-agent" ~role:Masc_domain.Worker
      ~token_env_var:"MASC_TOKEN" ~token_lifetime:Auth_login.Long_lived ()
  with
  | Error err -> failf "mint failed: %s" (Masc_domain.masc_error_to_string err)
  | Ok report ->
      check bool "codex name parses" true
        (Auth_login.mcp_client_of_string "codex" = Some Auth_login.Codex);
      check bool "claude-desktop name parses" true
        (Auth_login.mcp_client_of_string "claude-desktop"
        = Some Auth_login.Claude_desktop);
      check bool "env name parses" true
        (Auth_login.mcp_client_of_string "env" = Some Auth_login.Env);
      check bool "unknown client name is rejected" true
        (Auth_login.mcp_client_of_string "cursor" = None);
      let codex = Auth_login.render_mcp_client_config report Auth_login.Codex in
      check bool "codex block carries the mcp url" true
        (string_contains codex report.mcp_url);
      check bool "codex block names the bearer env var" true
        (string_contains codex "bearer_token_env_var");
      check bool "codex block exports the minted token" true
        (string_contains codex report.bearer_token);
      let claude =
        Auth_login.render_mcp_client_config report Auth_login.Claude_desktop
      in
      check bool "claude-desktop block bridges over mcp-remote" true
        (string_contains claude "mcp-remote");
      check bool "claude-desktop block carries the minted token" true
        (string_contains claude report.bearer_token);
      let env = Auth_login.render_mcp_client_config report Auth_login.Env in
      check bool "env block equals the shell exports" true
        (String.equal env (Auth_login.render_shell report))

let () =
  run "auth_login"
    [
      ( "login",
        [
          test_case "with-expiry honors caller env var" `Quick
            test_login_with_expiry_uses_caller_env_var;
          test_case "long-lived honors caller env var + no expires_at"
            `Quick test_login_long_lived_passes_env_var_through;
          test_case "naming both lifetimes is refused" `Quick
            test_lifetime_flags_refuse_to_pick_for_the_operator;
          test_case "a named window outlives the config window" `Quick
            test_login_expires_in_hours_outlives_the_config_window;
          test_case "a window outside the bound is refused, not raised" `Quick
            test_login_rejects_a_window_outside_the_bound;
          test_case "URL uses URI components" `Quick
            test_login_url_uses_uri_components;
          test_case "URLs do not advertise a bind wildcard" `Quick
            test_login_urls_do_not_advertise_a_bind_wildcard;
          test_case "persisted token round-trips" `Quick
            test_persisted_token_round_trips;
          test_case "mcp-config renders each client block" `Quick
            test_mcp_client_config_renders_each_client;
        ] );
    ]
