open Alcotest
open Masc

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f
;;

let temp_dir () =
  let path = Filename.temp_file "masc-ssh-secret-policy-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let contains needle haystack =
  let needle_len = String.length needle and haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  loop 0
;;

let make_meta name =
  match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ]) with
  | Error error -> fail error
  | Ok meta ->
    { meta with
      Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
    ; always_allow = Some true
    }
;;

let setup f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    let base_path = temp_dir () in
    let config = Workspace.default_config base_path in
    let keeper_name = "remote-secret-test" in
    let meta = make_meta keeper_name in
    let playground = Keeper_sandbox.host_root_abs_of_meta ~config meta in
    ensure_dir playground;
    write_file
      (Filename.concat base_path ".masc/config/keepers/remote-secret-test.toml")
      {|[keeper]
instructions = "remote secret policy test"
sandbox_profile = "remote_ssh"
remote_endpoint = "fixture"
|};
    (* RFC-0121: the endpoint resolver reads .masc/config/runtime.toml — the
       live layout — not the .masc root this fixture used to write to. *)
    write_file (Filename.concat base_path ".masc/config/runtime.toml")
      {|[exec.ssh.endpoints.fixture]
host = "fixture.invalid"
user = "masc"
remote_root = "/srv/masc/playground"
connect_timeout_sec = 1
max_concurrent_sessions = 2
env_allowlist = ["LANG"]
|};
    f ~config ~meta ~playground)
;;

let args ~cwd env =
  `Assoc
    [ "argv", `List [ `String "echo"; `String "ok" ]
    ; "cwd", `String cwd
    ; "timeout_sec", `Float 2.0
    ; "env", `Assoc (List.map (fun (name, value) -> name, `String value) env)
    ]
;;

let with_dispatch_override f =
  Keeper_tool_execute_runtime.For_testing.dispatch_override :=
    Some
      (fun () ->
        Ok
          { Masc_exec.Exec_dispatch.status = Unix.WEXITED 0
          ; stdout = "ok"
          ; stderr = ""
          });
  Fun.protect
    ~finally:(fun () ->
      Keeper_tool_execute_runtime.For_testing.dispatch_override := None)
    f
;;

let test_typed_github_token_is_rejected_before_dispatch () =
  setup @@ fun ~config ~meta ~playground ->
  with_dispatch_override @@ fun () ->
  let raw =
    Keeper_tool_execute_runtime.handle_tool_execute ~turn_sandbox_factory:None
      ~config ~meta ~args:(args ~cwd:playground [ "GH_TOKEN", "must-not-cross" ]) ()
  in
  check bool "Keeper-owned token rejected" true
    (contains
       "typed Execute env must not override Keeper-owned GitHub identity variable GH_TOKEN"
       raw)
;;

let test_allowlisted_nonsecret_env_reaches_dispatch_branch () =
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  setup @@ fun ~config ~meta ~playground ->
  with_dispatch_override @@ fun () ->
  let raw =
    Keeper_tool_execute_runtime.handle_tool_execute ~turn_sandbox_factory:None
      ~config ~meta ~args:(args ~cwd:playground [ "LANG", "C" ]) ()
  in
  let ok =
    match Yojson.Safe.from_string raw with
    | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool true)
    | _ -> false
  in
  check bool "allowlisted env reached authorized SSH dispatch" true ok
;;

let () =
  run "keeper_ssh_secret_policy"
    [ ( "policy"
      , [ test_case "typed GH_TOKEN rejected" `Quick
            test_typed_github_token_is_rejected_before_dispatch
        ; test_case "allowlisted nonsecret env dispatches" `Quick
            test_allowlisted_nonsecret_env_reaches_dispatch_branch
        ] )
    ]
