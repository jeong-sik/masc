(* Real Execute owner -> framed OpenSSH transport -> model-visible output.
   The isolated ssh executable answers the shim protocol; it does not claim
   Linux sandbox enforcement or execute the requested payload. *)
open Alcotest
open Masc

let save path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)

let lines path =
  if not (Sys.file_exists path) then [] else
  let channel = open_in path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    let rec read acc = match input_line channel with
      | line -> read (line :: acc)
      | exception End_of_file -> List.rev acc in
    read [])

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec read offset =
    if offset < length then
      let count = Unix.read fd bytes offset (length - offset) in
      if count = 0 then failwith "truncated request frame" else read (offset + count) in
  read 0;
  Bytes.unsafe_to_string bytes

let stub_main () =
  let request_log = Sys.argv.(2) and response_kind = Sys.argv.(3) in
  let args = Array.to_list (Array.sub Sys.argv 4 (Array.length Sys.argv - 4)) in
  if List.mem "masc-exec-shim --probe" args then (
    print_string (Exec_ssh_protocol.render_probe
      { name = "masc-exec-shim"
      ; version = string_of_int Exec_ssh_protocol.protocol_version ^ ".0.0"
      ; capabilities = [Exec_ssh_protocol.observe_capability]
      ; release = None; boot_id = None });
    exit 0);
  let header = read_exact Unix.stdin 8 in
  let length = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin length in
  let request = match Exec_ssh_protocol.decode_request frame with
    | Ok (request, _) -> request
    | Error error -> failwith error in
  let previous = lines request_log in
  let ordinal = List.length previous + 1 in
  let exit_code = match request.argv with
    | ["echo"; "first"] -> 3
    | ["echo"; "second"] -> 7
    | ["git"; "status"] -> 0
    | _ -> failwith "unexpected fixture command" in
  let row = `Assoc
      ["mode", `String (Exec_ssh_protocol.mode_to_string request.mode)
      ; "argv", `List (List.map (fun arg -> `String arg) request.argv)] in
  save request_log (String.concat "\n" (previous @ [Yojson.Safe.to_string row]) ^ "\n");
  if String.equal response_kind "transport-lost" then (
    print_string (String.make 100_000 'x');
    flush stdout;
    exit 255);
  let shim_refused = List.mem response_kind
      ["shim-refused-missing"; "shim-refused-invalid"; "shim-refused-recorded"] in
  let trailer : Exec_ssh_protocol.trailer =
    { v = request.v; exit = (if shim_refused then None else Some exit_code); signal = None
    ; timed_out = false
    ; shim_error = (if shim_refused then Some "fixture shim refusal" else None)
    ; observed_syscalls = [] } in
  let serialized = match response_kind with
    | "recorded" ->
        Exec_ssh_protocol.render_trailer
          ~execution_receipt:{ mode = request.mode; boundary = Sandbox_applied } trailer
    | "missing" -> Exec_ssh_protocol.render_trailer trailer
    | "shim-refused-missing" -> Exec_ssh_protocol.render_trailer trailer
    | "shim-refused-recorded" ->
        Exec_ssh_protocol.render_trailer
          ~execution_receipt:{ mode = request.mode; boundary = Refused } trailer
    | "shim-refused-invalid" ->
        "\x1e" ^ Yojson.Safe.to_string (`Assoc ["masc_exec_result", `Assoc
          ["v", `Int (Exec_ssh_protocol.int_of_major request.v)
          ; "exit", `Null; "signal", `Null; "timed_out", `Bool false
          ; "shim_error", `String "fixture shim refusal"; "execution_receipt", `Null]]) ^ "\x1e"
    | "invalid" ->
        "\x1e" ^ Yojson.Safe.to_string (`Assoc ["masc_exec_result", `Assoc
          ["v", `Int (Exec_ssh_protocol.int_of_major request.v)
          ; "exit", `Int exit_code; "signal", `Null; "timed_out", `Bool false
          ; "shim_error", `Null; "execution_receipt", `Null]]) ^ "\x1e"
    | _ -> failwith "unknown response fixture" in
  Printf.printf "fixture-call-%d\n" ordinal;
  Printf.eprintf "fixture-stderr-%d\n%s" ordinal serialized;
  exit (if shim_refused then 1 else 0)

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:"")) f

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let with_workspace ~response_kind f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock ~sw env;
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let base_path = Filename.temp_file "execute-shim-owner-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Process_eio.reset_for_testing ();
    Keeper_approval_queue.For_testing.reset_runtime_state ();
    remove base_path);
  let config = Workspace.default_config base_path in
  let name = "receipt-owner" in
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String name; "trace_id", `String "receipt-owner-trace"]) with
    | Error error -> fail error
    | Ok meta -> { meta with sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh } in
  let cwd = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p cwd;
  save (Filename.concat base_path ".masc/config/keepers/receipt-owner.toml")
    "[keeper]\ninstructions = \"isolated receipt fixture\"\nsandbox_profile = \"remote_ssh\"\nremote_endpoint = \"fixture\"\nobservation_run = \"observe\"\n";
  save (Filename.concat base_path ".masc/config/runtime.toml")
    (Exec_ssh_endpoint.to_toml Exec_ssh_endpoint.
      { name = "fixture"; host = "fixture.invalid"; user = "masc"
      ; port = default_port
      ; identity_file = default_identity_file ~name:"fixture"
      ; known_hosts_file = default_known_hosts_file ~name:"fixture"
      ; remote_root = "/srv/masc/playground"; connect_timeout_sec = 1
      ; max_concurrent_sessions = 1; env_allowlist = []; capabilities = []
      ; private_home = false
      ; allowed_paths = [] });
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> () | Error error -> fail (Masc.Keeper_approval_queue_result.install_error_to_string error));
  (match Keeper_gate_mode.set config ~actor:"fixture" Keeper_gate_mode.Auto_judge with
   | Ok _ -> () | Error error -> fail error);
  let bin_dir = Filename.concat base_path "bin" in
  let request_log = Filename.concat base_path "requests.jsonl" in
  let executable = if Filename.is_relative Sys.executable_name
    then Filename.concat (Sys.getcwd ()) Sys.executable_name else Sys.executable_name in
  let ssh = Filename.concat bin_dir "ssh" in
  save ssh (Printf.sprintf "#!/bin/sh\nexec %s --ssh-receipt-stub %s %s \"$@\"\n"
    (Filename.quote executable) (Filename.quote request_log) (Filename.quote response_kind));
  Unix.chmod ssh 0o700;
  with_env "PATH" (bin_dir ^ ":" ^ Option.value (Sys.getenv_opt "PATH") ~default:"") @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" @@ fun () ->
  let run ?(rewrite = Keeper_shell_tool_command.refuse_reserved_command) ~always_allow argv =
    Keeper_tool_execute_runtime.handle_tool_execute_with_outcome ~result_projection:Tool_output.default_model_projection
      ~shell_ir_rewrite:rewrite
      ~turn_sandbox_factory:None ~config ~meta:{ meta with always_allow = Some always_allow }
      ~args:(`Assoc ["argv", `List (List.map (fun arg -> `String arg) argv)
                   ; "cwd", `String cwd]) () in
  let execute ~always_allow argv =
    let execution = run ~always_allow argv in
    (match execution.disposition with
     | Tool_result.Completed () -> ()
     | Failed _ | Deferred _ -> fail ("Execute did not complete: " ^ execution.raw_output));
    let evidence =
      match Keeper_tool_call_log.execution_evidence_of_metadata execution.metadata with
      | Some evidence -> evidence
      | None -> fail ("completed Execute carried no execution evidence: " ^ execution.raw_output)
    in
    (Yojson.Safe.from_string execution.raw_output, evidence) in
  f execute (fun () -> List.map Yojson.Safe.from_string (lines request_log)) run base_path

let field name value = Yojson.Safe.Util.member name value
let text name value = field name value |> Yojson.Safe.Util.to_string
let integer name value = field name value |> Yojson.Safe.Util.to_int

let single_receipt evidence =
  let shim = field "shim_execution_evidence" evidence in
  check string "the ledger evidence records receipt observations" "recorded" (text "status" shim);
  match field "receipts" shim with
  | `List [receipt] -> receipt
  | other -> fail ("expected exactly one per-call receipt: " ^ Yojson.Safe.to_string other)

let assert_payload ~ordinal ~exit_code (payload, evidence) =
  check bool "payload success follows process exit" (exit_code = 0)
    (field "ok" payload |> Yojson.Safe.Util.to_bool);
  check int "actual remote process outcome survives" exit_code
    (field "status" payload |> integer "code");
  check string "exit outcome kind survives" "exit" (field "status" payload |> text "kind");
  check string "both streams belong to this call"
    (Printf.sprintf "fixture-call-%d\nfixture-stderr-%d\n" ordinal ordinal)
    (text "output" payload);
  check string "remote preview does not claim full capture" "capture_only"
    (text "output_completeness" evidence);
  check int "ledger sees the bytes compared at Execute's inline boundary"
    (String.length (text "output" payload))
    (integer "compared_output_bytes" evidence);
  check bool "this small Execute was not stored by its handler" false
    (field "handler_stored" evidence |> Yojson.Safe.Util.to_bool);
  check bool "the model sees neither measurement" true
    (field "compared_output_bytes" payload = `Null
     && field "handler_stored" payload = `Null);
  check bool "the model is not told the usual capture marker" true
    (field "output_completeness" payload = `Null);
  check bool "the model still reads its location observation" true
    (match field "execution_location" payload |> field "scope" with
     | `String _ -> true
     | _ -> false);
  List.iter (fun name ->
    check string (name ^ " is recorded as evidence") "remote_ssh" (text name evidence);
    check bool (name ^ " is not sent to the model") true (field name payload = `Null))
    ["requested_sandbox"; "via"; "sandbox_profile"]

let test_each_owner_call_retains_only_its_own_receipt () =
  with_workspace ~response_kind:"recorded" @@ fun execute requests _run _base_path ->
  let first = execute ~always_allow:true ["echo"; "first"] in
  let second = execute ~always_allow:true ["echo"; "second"] in
  List.iter (fun (ordinal, exit_code, ((payload, evidence) as result)) ->
    assert_payload ~ordinal ~exit_code result;
    let receipt = single_receipt evidence in
    check string "receipt is observed" "observed" (text "status" receipt);
    check string "unboxed effect receipt is preserved" "effect" (field "receipt" receipt |> text "mode");
    check string "effect receipt retains its reported plan" "unrestricted" (field "receipt" receipt |> text "plan");
    check int "each receipt has its own exit" exit_code (field "outcome" receipt |> integer "exit");
    check bool "one usual effect receipt is not sent to the model" true
      (field "shim_execution_evidence" payload = `Null))
    [1, 3, first; 2, 7, second];
  check (list string) "two separate owner calls reached transport" ["effect"; "effect"]
    (List.map (text "mode") (requests ()))

let test_observe_result_is_reused_by_actual_owner () =
  with_workspace ~response_kind:"recorded" @@ fun execute requests _run _base_path ->
  let (payload, evidence) as result = execute ~always_allow:false ["git"; "status"] in
  assert_payload ~ordinal:1 ~exit_code:0 result;
  let receipt = single_receipt evidence |> field "receipt" in
  check string "actual observation mode survives owner settlement" "observe" (text "mode" receipt);
  check string "reported box boundary survives" "sandbox_applied" (text "boundary" receipt);
  check bool "an Observe receipt still reaches the model" true
    (Yojson.Safe.equal
       (field "shim_execution_evidence" evidence)
       (field "shim_execution_evidence" payload));
  check (list string) "completed Observe was not dispatched again as Effect" ["observe"]
    (List.map (text "mode") (requests ()))

let test_unavailable_receipt_does_not_erase_process_result () =
  List.iter (fun (response_kind, reason) ->
    with_workspace ~response_kind @@ fun execute requests _run _base_path ->
    let (payload, evidence) as result = execute ~always_allow:true ["echo"; "first"] in
    assert_payload ~ordinal:1 ~exit_code:3 result;
    let receipt = single_receipt evidence in
    check bool "an unavailable receipt still reaches the model" true
      (Yojson.Safe.equal
         (field "shim_execution_evidence" evidence)
         (field "shim_execution_evidence" payload));
    check string "receipt availability is explicit" "unavailable" (text "status" receipt);
    check string "exact receipt failure survives" reason (text "reason" receipt);
    check bool "no receipt was invented from the requested mode" true (field "receipt" receipt = `Null);
    check int "receipt absence never causes another dispatch" 1 (List.length (requests ())))
    ["missing", "peer_receipt_missing"; "invalid", "invalid_receipt"]

let with_stream_end f =
  let recorded = ref [] in
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~status -> recorded := status :: !recorded);
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive_signal.register_record_execute_stream_end
        (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~status:_ -> ()))
    (fun () -> f recorded)

let test_box_observation_stream_hides_unapproved_content () =
  with_workspace ~response_kind:"recorded" @@ fun execute _requests _run _base_path ->
  let events = ref [] in
  Keeper_keepalive_signal.register_record_execute_stream_start
    (fun ~keeper_name:_ ~stream_id ~task_id:_ ~command ->
      events := `Opened (stream_id, command) :: !events);
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name:_ ~stream_id ~task_id:_ ~status ->
      events := `Closed (stream_id, status) :: !events);
  Keeper_keepalive_signal.register_record_execute_stream_chunk
    (fun ~keeper_name:_ ~stream_id ~stream:_ chunk ->
      events := `Chunk (stream_id, chunk) :: !events);
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive_signal.register_record_execute_stream_start
        (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~command:_ -> ());
      Keeper_keepalive_signal.register_record_execute_stream_end
        (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~status:_ -> ());
      Keeper_keepalive_signal.register_record_execute_stream_chunk
        (fun ~keeper_name:_ ~stream_id:_ ~stream:_ _ -> ()))
    (fun () ->
      ignore (execute ~always_allow:false ["git"; "status"]);
      match List.rev !events with
      | `Opened (gate_id, "[gate observation]") :: `Closed (closed_id, status)
        :: `Opened (effect_id, command) :: rest ->
        check int "the observation stream closes its own id" gate_id closed_id;
        check bool "the authorized stream has its own identity" true (gate_id <> effect_id);
        check bool "the authorized command is visible only after the gate" true
          (String_util.contains_substring command "git");
        check string "only the observation phase ended" "gate_observation" (text "phase" status);
        check string "the close does not claim effect completion" "observation_ended" (text "outcome" status);
        check bool "the observation stream did not publish output" false
          (List.exists (function `Chunk (id, _) -> id = gate_id | `Opened _ | `Closed _ -> false) rest);
        check bool "authorized output is eventually visible" true
          (List.exists (function `Chunk (id, _) -> id = effect_id | `Opened _ | `Closed _ -> false) rest)
      | _ -> fail "observation did not open and close separately before authorization")

let test_cancelled_box_observation_closes_unknown () =
  with_workspace ~response_kind:"recorded" @@ fun _execute _requests run _base_path ->
  with_stream_end @@ fun recorded ->
  let command = ref None in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive_signal.register_record_execute_stream_start
        (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~command:_ -> ()))
    (fun () ->
      let cancelled =
        try
          Eio.Cancel.sub (fun context ->
            Keeper_keepalive_signal.register_record_execute_stream_start
              (fun ~keeper_name:_ ~stream_id:_ ~task_id:_ ~command:label ->
                command := Some label;
                Eio.Cancel.cancel context Exit;
                Eio.Fiber.check ());
            ignore (run ~always_allow:false ["git"; "status"]));
          false
        with Eio.Cancel.Cancelled _ -> true
      in
      check bool "cancellation propagates" true cancelled;
      check (option string) "only a fixed label was published" (Some "[gate observation]") !command;
      check (list string) "cancellation closes the observation as unknown" ["unknown"]
        (List.map (text "outcome") !recorded);
      check (list string) "the closed phase is explicit" ["gate_observation"]
        (List.map (text "phase") !recorded))

let test_non_eio_rejection_closes_stream () =
  with_workspace ~response_kind:"recorded" @@ fun _execute _requests run _base_path ->
  with_stream_end @@ fun recorded ->
  Keeper_tool_execute_runtime.For_testing.dispatch_override := Some (fun () ->
    Error (Keeper_tooling.Execute_shell_ir.Gate_reject "fixture rejection"));
  Fun.protect
    ~finally:(fun () -> Keeper_tool_execute_runtime.For_testing.dispatch_override := None)
    (fun () ->
      let result = Eio_unix.run_in_systhread (fun () ->
        check bool "the handler is outside an Eio fiber" true
          (Fs_compat.execution_context () = Fs_compat.Non_eio);
        run ~always_allow:true ["echo"; "first"]) in
      check bool "the original rejection remains visible" true
        (match result.disposition with
         | Tool_result.Failed Tool_result.Runtime_failure -> true
         | Completed _ | Deferred _ | Failed _ -> false);
      check (list string) "the rejected stream closes exactly once" ["gate_reject"]
        (List.map (text "rejected") !recorded))

let test_unsent_request_is_proven_pre_effect () =
  with_workspace ~response_kind:"recorded" @@ fun _execute requests run _base_path ->
  with_stream_end @@ fun recorded ->
  let rewrite = function
    | Masc_exec.Shell_ir.Simple stage ->
      let literal = Masc_exec.Shell_ir.Lit ("value", Masc_exec.Shell_ir.default_meta) in
      Ok (Masc_exec.Shell_ir.Simple { stage with env = ["NOT_ALLOWLISTED", literal] })
    | Masc_exec.Shell_ir.Pipeline _ | Masc_exec.Shell_ir.Sequence _ ->
      Error "fixture expected a single stage"
  in
  let result = run ~rewrite ~always_allow:true ["echo"; "first"] in
  check bool "unsent request has a pre-effect failure" true
    (match result.disposition, result.failure_effect_disposition with
     | Tool_result.Failed Tool_result.Dependency_unavailable, Tool_result.Proven_pre_effect -> true
     | (Tool_result.Completed _ | Deferred _ | Failed _), _ -> false);
  check int "no request was dispatched" 0 (List.length (requests ()));
  let payload = match result.data with Some data -> data | None -> fail "missing typed data" in
  check string "result does not invent a child exit" "request_not_sent"
    (field "status" payload |> text "outcome");
  check (list string) "stream reports the same observation" ["request_not_sent"]
    (List.map (text "outcome") !recorded)

let test_unknown_effect_survives_output_persistence_failure () =
  with_workspace ~response_kind:"transport-lost" @@ fun _execute requests run base_path ->
  with_stream_end @@ fun recorded ->
  let store = Tool_blob_store.create ~base_path in
  save (Tool_blob_store.root_dir store) "not a directory";
  let result = run ~always_allow:true ["echo"; "first"] in
  check int "one request reached the transport" 1 (List.length (requests ()));
  check bool "failed persistence cannot prove the remote effect" true
    (match result.disposition, result.failure_effect_disposition with
     | Tool_result.Failed Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown -> true
     | (Tool_result.Completed _ | Deferred _ | Failed _), _ -> false);
  let payload = Yojson.Safe.from_string result.raw_output in
  check string "output persistence failed" "execute_output_externalization_failed" (text "code" payload);
  check string "synthetic exit is not a process outcome" "unknown" (field "status" payload |> text "outcome");
  check bool "the error names the uncertainty" true
    (String_util.contains_substring (text "error" payload) "unconfirmed");
  check (list string) "stream reports the same observation" ["unknown"]
    (List.map (text "outcome") !recorded)

let test_transport_loss_is_unknown_without_replay () =
  with_workspace ~response_kind:"transport-lost" @@ fun _execute requests run _base_path ->
  with_stream_end @@ fun recorded ->
  let result = run ~always_allow:true ["echo"; "first"] in
  check int "one request reached the transport" 1 (List.length (requests ()));
  check bool "transport loss is not a process exit" true
    (match result.disposition, result.failure_effect_disposition with
     | Tool_result.Failed Tool_result.Dependency_unavailable, Tool_result.Effect_outcome_unknown -> true
     | (Tool_result.Completed _ | Deferred _ | Failed _), _ -> false);
  let payload = match result.data with Some data -> data | None -> fail "missing typed data" in
  check string "no exit status is invented" "unknown" (field "status" payload |> text "outcome");
  check bool "message warns the remote effect may have happened" true
    (String_util.contains_substring result.raw_output "may have happened");
  check (list string) "stream reports the same observation" ["unknown"]
    (List.map (text "outcome") !recorded)

let test_shim_refusal_is_not_a_child_exit () =
  List.iter (fun response_kind ->
    with_workspace ~response_kind @@ fun _execute requests run _base_path ->
    with_stream_end @@ fun recorded ->
    let result = run ~always_allow:true ["echo"; "first"] in
    check int "one request reached the shim" 1 (List.length (requests ()));
    check bool "shim refusal does not invent a child exit" true
      (match result.disposition, result.failure_effect_disposition with
       | Tool_result.Failed Tool_result.Dependency_unavailable, Tool_result.Effect_outcome_unknown -> true
       | (Tool_result.Completed _ | Deferred _ | Failed _), _ -> false);
    let payload = match result.data with Some data -> data | None -> fail "missing typed data" in
    check string "the result reports uncertainty" "unknown" (field "status" payload |> text "outcome");
    check (list string) "the stream reports the same observation" ["unknown"]
      (List.map (text "outcome") !recorded))
    ["shim-refused-missing"; "shim-refused-invalid"; "shim-refused-recorded"]

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--ssh-receipt-stub"
  then stub_main ()
  else Alcotest.run "keeper_execute_shim_evidence"
    ["actual-owner", [
      test_case "each call keeps its own receipt and nonzero exit" `Quick test_each_owner_call_retains_only_its_own_receipt;
      test_case "Observe result is reused without Effect redispatch" `Quick test_observe_result_is_reused_by_actual_owner;
      test_case "missing and malformed receipts preserve exit and streams" `Quick test_unavailable_receipt_does_not_erase_process_result;
      test_case "boxed observation publishes no unapproved content" `Quick test_box_observation_stream_hides_unapproved_content;
      test_case "cancelled boxed observation closes unknown" `Quick test_cancelled_box_observation_closes_unknown;
      test_case "non-Eio rejection closes stream" `Quick test_non_eio_rejection_closes_stream;
      test_case "unsent request is pre-effect" `Quick test_unsent_request_is_proven_pre_effect;
      test_case "transport loss remains unknown without replay" `Quick test_transport_loss_is_unknown_without_replay;
      test_case "shim refusal never becomes a child exit" `Quick test_shim_refusal_is_not_a_child_exit;
      test_case "lost transport and output persistence retain uncertainty" `Quick test_unknown_effect_survives_output_persistence_failure]]
