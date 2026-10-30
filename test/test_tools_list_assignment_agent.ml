(* tools/list records a tool assignment for the caller. The caller is the
   verified credential's owner, the name tools/call looks the assignment up
   by; the bearer is a secret and never reaches the telemetry files. *)

open Alcotest
module Mcp_eio = Masc.Mcp_server_eio
module Telemetry = Masc.Tool_assignment_telemetry

let () = Mirage_crypto_rng_unix.use_default ()

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

(* The telemetry store follows MASC_BASE_PATH, so the workspace and the store
   share one temporary directory. *)
let with_workspace ~auth f =
  let base_path = Filename.temp_dir "tools-list-agent-" "" in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_BASE_PATH" (Option.value previous ~default:"");
      remove_tree base_path)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Masc_test_deps.init_eio_clock env;
        Telemetry.reset_for_testing ();
        let clock = Eio.Stdenv.clock env in
        Eio.Switch.run (fun sw ->
          let state = Mcp_eio.For_testing.create_state ~base_path () in
          if auth then
            Auth.save_auth_config base_path
              { Masc_domain.default_auth_config with enabled = true; require_token = true };
          let token =
            match Auth.create_token base_path ~agent_name:"worker1" ~role:Masc_domain.Worker with
            | Ok (token, _) -> token
            | Error err -> fail (Masc_domain.masc_error_to_string err)
          in
          let list_tools () =
            ignore
              (Mcp_eio.handle_request ~clock ~sw ~auth_token:token state
                 {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|})
          in
          f ~base_path ~token list_tools)))

let assigned_agents () =
  match Telemetry.read_recent ~n:50 with
  | Error msg -> fail msg
  | Ok events ->
    List.filter_map
      (function
        | Telemetry.Assigned { agent_id; _ } -> Some agent_id
        | Telemetry.Called _ | Telemetry.Completed _ -> None)
      events

let rec file_contents dir =
  if not (Sys.file_exists dir) then []
  else
    Array.to_list (Sys.readdir dir)
    |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then file_contents path
      else [ In_channel.with_open_bin path In_channel.input_all ])

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

let test_the_assignment_names_the_credential_owner () =
  with_workspace ~auth:true (fun ~base_path ~token list_tools ->
    list_tools ();
    check (list string) "the assignment names the credential's owner" [ "worker1" ]
      (assigned_agents ());
    check bool "tools/call can find it by that name" true
      (Option.is_some (Telemetry.find_latest_assignment_id ~agent_id:"worker1"));
    check bool "the bearer is in no telemetry file" false
      (List.exists (contains ~sub:token) (file_contents (Filename.concat base_path "data"))))

let test_without_auth_nothing_names_the_bearer () =
  with_workspace ~auth:false (fun ~base_path ~token list_tools ->
    list_tools ();
    check bool "no assignment is keyed by the bearer" false
      (List.mem token (assigned_agents ()));
    check bool "the bearer is in no telemetry file" false
      (List.exists (contains ~sub:token) (file_contents (Filename.concat base_path "data"))))

let () =
  run "tools_list_assignment_agent"
    [ ( "tools/list"
      , [ test_case "the assignment names the credential owner" `Quick
            test_the_assignment_names_the_credential_owner
        ; test_case "without auth nothing names the bearer" `Quick
            test_without_auth_nothing_names_the_bearer
        ] )
    ]
