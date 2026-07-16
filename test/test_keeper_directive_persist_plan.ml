open Alcotest
open Masc

module Post = Server_dashboard_http_keeper_api_post

let plan = Post.paused_state_persist_plan

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o700)
;;

let with_temp_dir f =
  let path = Filename.temp_file "keeper-directive-plan-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let response_status response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "invalid HTTP response: %S" response
;;

let directive_response ~base_path ~name ~body =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let state = Mcp_server_eio.For_testing.create_state ~base_path () in
  let target = Printf.sprintf "/api/v1/keepers/%s/directive" name in
  let response = Buffer.create 512 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Post.handle_keeper_directive_post
        ~sw
        ~clock:(Eio.Stdenv.clock env)
        state
        "operator"
        (Httpun.Reqd.request reqd)
        reqd
        body)
  in
  let request =
    Printf.sprintf "POST %s HTTP/1.1\r\nhost: localhost\r\ncontent-length: 0\r\n\r\n" target
  in
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
  let consumed =
    Httpun.Server_connection.read_eof
      connection
      bytes
      ~off:0
      ~len:(Bigstringaf.length bytes)
  in
  check int "complete request consumed" (Bigstringaf.length bytes) consumed;
  let rec flush () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0
          iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      flush ()
    | `Yield | `Close _ -> ()
  in
  flush ();
  Buffer.contents response
;;

let test_paused_state_persist_plan () =
  check bool
    "pause persists true for an existing registration"
    true
    (plan Keeper_directive.Pause Post.Already_registered
     = Post.Persist_paused_state true);
  check bool
    "pause persists true after registration recovery"
    true
    (plan Keeper_directive.Pause Post.Booted_missing_registry
     = Post.Persist_paused_state true);
  check bool
    "resume persists false for an existing registration"
    true
    (plan Keeper_directive.Resume Post.Already_registered
     = Post.Persist_paused_state false);
  check bool
    "resume recovery does not overwrite freshly booted metadata"
    true
    (plan Keeper_directive.Resume Post.Booted_missing_registry
     = Post.Skip_paused_state_persist);
  check bool
    "wakeup does not mutate paused state"
    true
    (plan Keeper_directive.Wakeup Post.Already_registered
     = Post.Skip_paused_state_persist)
;;

let test_missing_meta_is_not_a_silent_pause_success () =
  with_temp_dir
  @@ fun base_path ->
  let response =
    directive_response
      ~base_path
      ~name:"missing-meta"
      ~body:{|{"action":"pause"}|}
  in
  check int "missing meta is not found" 404 (response_status response)
;;

let test_malformed_meta_is_an_explicit_pause_failure () =
  with_temp_dir
  @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let path = Keeper_types_profile.keeper_meta_path config "malformed-meta" in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
    output_string channel {|{"name":|});
  let response =
    directive_response
      ~base_path
      ~name:"malformed-meta"
      ~body:{|{"action":"pause"}|}
  in
  check int "malformed meta is an internal error" 500 (response_status response)
;;

let () =
  run
    "keeper_directive_persist_plan"
    [ ( "planner"
      , [ test_case "typed paused-state plan" `Quick test_paused_state_persist_plan
        ; test_case
            "missing meta pause fails explicitly"
            `Quick
            test_missing_meta_is_not_a_silent_pause_success
        ; test_case
            "malformed meta pause fails explicitly"
            `Quick
            test_malformed_meta_is_an_explicit_pause_failure
        ] )
    ]
;;
