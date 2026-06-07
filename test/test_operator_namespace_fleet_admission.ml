open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_operator_namespace_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir dir =
  if Sys.file_exists dir then
    if Sys.is_directory dir then (
      Array.iter
        (fun name -> cleanup_dir (Filename.concat dir name))
        (Sys.readdir dir);
      Unix.rmdir dir)
    else Unix.unlink dir
;;

let ensure_fs env =
  Masc_test_deps.init_eio_clock env;
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env)
;;

let operator_ctx env sw config agent_name : _ Operator_control.context =
  { config
  ; agent_name
  ; sw
  ; clock = Eio.Stdenv.clock env
  ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
  ; net = Some (Eio.Stdenv.net env)
  ; mcp_session_id = None
  }
;;

type hook_call =
  | Pause of string * string * string
  | Resume of string * string

let with_fleet_admission_hooks calls f =
  let original_pause = Atomic.get Workspace_hooks.fleet_admission_pause_fn in
  let original_resume = Atomic.get Workspace_hooks.fleet_admission_resume_fn in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.fleet_admission_pause_fn original_pause;
      Atomic.set Workspace_hooks.fleet_admission_resume_fn original_resume)
    (fun () ->
      Atomic.set Workspace_hooks.fleet_admission_pause_fn
        (fun ~base_path ~reason ~updated_by ->
          calls := Pause (base_path, reason, updated_by) :: !calls);
      Atomic.set Workspace_hooks.fleet_admission_resume_fn
        (fun ~base_path ~updated_by ->
          calls := Resume (base_path, updated_by) :: !calls);
      f ())
;;

let action_or_fail ctx json =
  match Operator_control.action_json ctx json with
  | Ok json -> json
  | Error err -> Alcotest.fail err
;;

let confirm_or_fail ctx json =
  match Operator_control.confirm_json ctx json with
  | Ok json -> json
  | Error err -> Alcotest.fail err
;;

let test_namespace_pause_resume_updates_fleet_admission () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let calls = ref [] in
      with_fleet_admission_hooks calls (fun () ->
        let pause_preview =
          action_or_fail ctx
            (`Assoc
              [ "actor", `String "operator-a"
              ; "action_type", `String "namespace_pause"
              ; "target_type", `String "workspace"
              ; "payload", `Assoc [ "reason", `String "manual gate" ]
              ])
        in
        Alcotest.(check bool)
          "namespace pause requires confirmation"
          true
          Yojson.Safe.Util.(pause_preview |> member "confirm_required" |> to_bool);
        Alcotest.(check int)
          "preview does not call hook"
          0
          (List.length !calls);
        let confirm_token =
          Yojson.Safe.Util.(pause_preview |> member "confirm_token" |> to_string)
        in
        ignore
          (confirm_or_fail ctx
             (`Assoc
               [ "actor", `String "operator-a"
               ; "confirm_token", `String confirm_token
               ]));
        ignore
          (action_or_fail ctx
             (`Assoc
               [ "actor", `String "operator-b"
               ; "action_type", `String "namespace_resume"
               ; "target_type", `String "workspace"
               ; "payload", `Assoc []
               ])));
      Alcotest.(check int) "hook calls" 2 (List.length !calls);
      match !calls with
      | [ Resume (resume_base, resume_actor)
        ; Pause (pause_base, pause_reason, pause_actor) ] ->
          Alcotest.(check string) "pause base_path" config.base_path pause_base;
          Alcotest.(check string) "pause reason" "manual gate" pause_reason;
          Alcotest.(check string) "pause actor" "operator-a" pause_actor;
          Alcotest.(check string) "resume base_path" config.base_path resume_base;
          Alcotest.(check string) "resume actor" "operator-b" resume_actor
      | _ -> Alcotest.fail "unexpected hook call order")
;;

let () =
  Alcotest.run "operator_namespace_fleet_admission"
    [ ( "operator namespace actions"
      , [ Alcotest.test_case
            "namespace pause/resume updates fleet admission hooks"
            `Quick
            test_namespace_pause_resume_updates_fleet_admission
        ] )
    ]
;;
