(** Regression pin for masc#28983.

    A process that runs and exits nonzero is an observed tool result the
    model reads and reacts to — not a failed terminal effect. The previous
    routing sent every nonzero exit through
    [Keeper_tool_execution.failure], whose [Failed] disposition the tool
    bundle promotes to a sticky [Terminal_effect_failed], killing the
    whole turn: four keeper turn deaths across the E0 campaign and the
    eta pilot (2026-08-18) traced to probes like [ls] on a missing
    path.

    Pins: a nonzero exit produces a [Completed] execution whose payload
    still reports [ok=false] and the exit status; an exit-0 run stays
    [Completed] with [ok=true]. *)

open Alcotest
open Masc

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat p name)) (Sys.readdir p);
      Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  rm path

let make_local_meta ~name : Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String ("keeper-" ^ name ^ "-agent"))
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("allowed_paths", `List [ `String "*" ])
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with sandbox_profile = Keeper_types_profile_sandbox.Local }
  | Error e -> Alcotest.fail e

let rec mkdir_p path =
  if path = "" || path = Filename.dir_sep || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let playground_dir ~base ~name =
  let dir =
    List.fold_left Filename.concat base [ ".masc"; "playground"; name ]
  in
  mkdir_p dir;
  dir

(* The live workspace runs the Gate in always_allow mode (mode.json); the
   test mirrors that so tool_execute is authorized instead of deferred. *)
let install_always_allow_gate ~base =
  let gate_dir = List.fold_left Filename.concat base [ ".masc"; "gate" ] in
  mkdir_p gate_dir;
  let oc = open_out (Filename.concat gate_dir "mode.json") in
  output_string oc
    {|{"mode":"always_allow","updated_by":"test","updated_at":"2026-08-18T00:00:00Z"}|};
  close_out oc

let run_execute ~config ~meta ~argv ~cwd =
  Keeper_tool_execute_runtime.handle_tool_execute_with_outcome
    ~turn_sandbox_factory:None
    ~config
    ~meta
    ~args:
      (`Assoc
        [ "argv", `List (List.map (fun a -> `String a) argv)
        ; "cwd", `String cwd
        ])
    ()

let payload_of (execution : Keeper_tool_execution.t) =
  Yojson.Safe.from_string execution.raw_output

let test_nonzero_exit_is_a_completed_result () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir "exec_exit_result_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
      let config = Workspace.default_config base in
      (match Keeper_approval_queue.install_persistence ~base_path:base with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_approval_queue.install_error_to_string error));
      install_always_allow_gate ~base;
      let meta = make_local_meta ~name:"exit-result-pin" in
      (* Inside the keeper playground the effect is authorized via
         workspace_always_allow, so the test needs no Gate store. *)
      let cwd = playground_dir ~base ~name:"exit-result-pin" in
      let execution =
        run_execute ~config ~meta ~argv:[ "ls"; "definitely-missing-dir" ] ~cwd
      in
      (match execution.disposition with
       | Tool_result.Completed () -> ()
       | Tool_result.Failed _ ->
         Alcotest.failf
           "nonzero exit must stay a completed tool result, got failure: %s"
           execution.raw_output
       | Tool_result.Deferred () ->
         Alcotest.fail "nonzero exit must not defer");
      let open Yojson.Safe.Util in
      let payload = payload_of execution in
      check bool "payload reports ok=false" false
        (payload |> member "ok" |> to_bool);
      check string "payload reports the exit status" "exit"
        (payload |> member "status" |> member "kind" |> to_string);
      check bool "payload keeps a nonzero code" true
        (payload |> member "status" |> member "code" |> to_int <> 0))

let test_zero_exit_stays_ok () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir "exec_exit_ok_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
      let config = Workspace.default_config base in
      (match Keeper_approval_queue.install_persistence ~base_path:base with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_approval_queue.install_error_to_string error));
      install_always_allow_gate ~base;
      let meta = make_local_meta ~name:"exit-ok-pin" in
      let cwd = playground_dir ~base ~name:"exit-ok-pin" in
      let execution = run_execute ~config ~meta ~argv:[ "true" ] ~cwd in
      (match execution.disposition with
       | Tool_result.Completed () -> ()
       | Tool_result.Failed _ | Tool_result.Deferred () ->
         Alcotest.failf "exit 0 must complete, got: %s" execution.raw_output);
      let open Yojson.Safe.Util in
      check bool "payload reports ok=true" true
        (payload_of execution |> member "ok" |> to_bool))

let () =
  run
    "keeper_tool_execute_exit_result"
    [ ( "exit-status-is-a-result"
      , [ test_case
            "nonzero exit is a completed result"
            `Quick
            test_nonzero_exit_is_a_completed_result
        ; test_case "zero exit stays ok" `Quick test_zero_exit_stays_ok
        ] )
    ]
