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
    [Completed] with [ok=true].

    Also pins where the escaped-shell advice lives. The payload is what the
    model reads -- [raw_output] is the serialized [data] -- and [metadata] is
    not: every read of [_meta] in agent_core discards it. Advice attached to
    metadata would be advice the caller it is written for never sees. *)

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
      ; ("trace_id", `String ("trace-" ^ name))
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh }
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

let test_escaped_shell_advice_is_in_what_the_model_reads () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir "exec_costume_advice_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
      let config = Workspace.default_config base in
      (match Keeper_approval_queue.install_persistence ~base_path:base with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_approval_queue.install_error_to_string error));
      install_always_allow_gate ~base;
      let meta = make_local_meta ~name:"costume-advice" in
      let cwd = playground_dir ~base ~name:"costume-advice" in
      (* [;] used to be the construct this test reached for; RFC-0391 put it
         in Shell_ir.connector, so a substitution stands in. What is being
         checked is unchanged: a costume the subset cannot say still runs, and
         the caller is told what the typed call should have been. *)
      let execution =
        run_execute
          ~config
          ~meta
          ~argv:[ "sh"; "-c"; "echo $(echo two)" ]
          ~cwd
      in
      (match execution.disposition with
       | Tool_result.Completed () -> ()
       | Tool_result.Failed _ ->
         Alcotest.fail "telling the caller must not fail the call"
       | Tool_result.Deferred _ ->
         Alcotest.fail "telling the caller must not defer the call");
      let payload = payload_of execution in
      let field name =
        match payload with
        | `Assoc fields -> List.assoc_opt name fields
        | _ -> Alcotest.fail "payload was not an object"
      in
      check (option bool) "the call still reports success" (Some true)
        (match field "ok" with
         | Some (`Bool b) -> Some b
         | _ -> None);
      match field "escaped_shell" with
      | Some (`List [ `Assoc entry ]) ->
        check (option string) "the shell that wore the costume"
          (Some "sh")
          (match List.assoc_opt "shell" entry with
           | Some (`String s) -> Some s
           | _ -> None);
        check (option string) "the construct the gate would have refused"
          (Some "cmd_subst")
          (match List.assoc_opt "finding" entry with
           | Some (`String s) -> Some s
           | _ -> None);
        (* Compared against the sentence the library renders, so the
           expectation cannot drift from it. *)
        check (option string) "what the call should have been"
          (Some
             (Keeper_tooling.Subset_rewrite.to_string
                (Keeper_tooling.Subset_rewrite.of_reason
                   (Masc_exec_command_gate.Shell_command_gate.Unsupported_construct
                      `Cmd_subst))))
          (match List.assoc_opt "should_have_been" entry with
           | Some (`String s) -> Some s
           | _ -> None)
      | Some other ->
        Alcotest.failf
          "escaped_shell was not one entry: %s"
          (Yojson.Safe.to_string other)
      | None ->
        Alcotest.fail
          "escaped_shell is absent from the payload the model reads")
;;

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

(* RFC spawn-a-process-that-outlives-the-call §1.0. The advice for [&] says
   the call waits for the backgrounded child anyway; if that stops being true
   the sentence becomes wrong, so it is pinned here. A lower bound, because
   the point is that the call does not return early. *)
let test_a_backgrounded_child_still_holds_the_call () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir "exec_background_holds_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
      let config = Workspace.default_config base in
      (match Keeper_approval_queue.install_persistence ~base_path:base with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_approval_queue.install_error_to_string error));
      install_always_allow_gate ~base;
      let meta = make_local_meta ~name:"background-holds" in
      let cwd = playground_dir ~base ~name:"background-holds" in
      let execution =
        run_execute ~config ~meta ~argv:[ "sh"; "-c"; "sleep 1 &" ] ~cwd
      in
      let elapsed =
        match payload_of execution with
        | `Assoc fields ->
          (match List.assoc_opt "execution_time_ms" fields with
           | Some (`Int ms) -> ms
           | _ -> Alcotest.fail "the payload has no execution_time_ms")
        | _ -> Alcotest.fail "payload was not an object"
      in
      if elapsed < 1000
      then
        Alcotest.failf
          "the call returned in %dms, so [&] now backgrounds and the advice \
           for it is wrong"
          elapsed)
;;

let () =
  run
    "keeper_tool_execute_exit_result"
    [ ( "exit-status-is-a-result"
      , [ test_case
            "nonzero exit is a completed result"
            `Quick
            test_nonzero_exit_is_a_completed_result
        ; test_case "zero exit stays ok" `Quick test_zero_exit_stays_ok
        ; test_case
            "a backgrounded child still holds the call"
            `Quick
            test_a_backgrounded_child_still_holds_the_call
        ; test_case
            "escaped-shell advice is in what the model reads"
            `Quick
            test_escaped_shell_advice_is_in_what_the_model_reads
        ] )
    ]
