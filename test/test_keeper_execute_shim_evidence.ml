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
      ; release = None });
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
  let trailer : Exec_ssh_protocol.trailer =
    { v = request.v; exit = Some exit_code; signal = None
    ; timed_out = false; shim_error = None } in
  let serialized = match response_kind with
    | "recorded" ->
        Exec_ssh_protocol.render_trailer
          ~execution_receipt:{ mode = request.mode; boundary = Sandbox_applied } trailer
    | "missing" -> Exec_ssh_protocol.render_trailer trailer
    | "invalid" ->
        "\x1e" ^ Yojson.Safe.to_string (`Assoc ["masc_exec_result", `Assoc
          ["v", `Int (Exec_ssh_protocol.int_of_major request.v)
          ; "exit", `Int exit_code; "signal", `Null; "timed_out", `Bool false
          ; "shim_error", `Null; "execution_receipt", `Null]]) ^ "\x1e"
    | _ -> failwith "unknown response fixture" in
  Printf.printf "fixture-call-%d\n" ordinal;
  Printf.eprintf "fixture-stderr-%d\n%s" ordinal serialized;
  exit 0

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
      ; private_home = false });
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> () | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
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
  let execute ~always_allow argv =
    let execution = Keeper_tool_execute_runtime.handle_tool_execute_with_outcome
      ~shell_ir_rewrite:Keeper_shell_tool_command.refuse_reserved_command
      ~turn_sandbox_factory:None ~config ~meta:{ meta with always_allow = Some always_allow }
      ~args:(`Assoc ["argv", `List (List.map (fun arg -> `String arg) argv)
                   ; "cwd", `String cwd]) () in
    (match execution.disposition with
     | Tool_result.Completed () -> ()
     | Failed _ | Deferred _ -> fail ("Execute did not complete: " ^ execution.raw_output));
    Yojson.Safe.from_string execution.raw_output in
  f execute (fun () -> List.map Yojson.Safe.from_string (lines request_log))

let field name value = Yojson.Safe.Util.member name value
let text name value = field name value |> Yojson.Safe.Util.to_string
let integer name value = field name value |> Yojson.Safe.Util.to_int

let single_receipt payload =
  let evidence = field "shim_execution_evidence" payload in
  check string "the model-visible result records receipt observations" "recorded" (text "status" evidence);
  match field "receipts" evidence with
  | `List [receipt] -> receipt
  | other -> fail ("expected exactly one per-call receipt: " ^ Yojson.Safe.to_string other)

let assert_payload ~ordinal ~exit_code payload =
  check bool "payload success follows process exit" (exit_code = 0)
    (field "ok" payload |> Yojson.Safe.Util.to_bool);
  check int "actual remote process outcome survives" exit_code
    (field "status" payload |> integer "code");
  check string "exit outcome kind survives" "exit" (field "status" payload |> text "kind");
  check string "both streams belong to this call"
    (Printf.sprintf "fixture-call-%d\nfixture-stderr-%d\n" ordinal ordinal)
    (text "output" payload);
  check string "remote preview does not claim full capture" "capture_only"
    (text "output_completeness" payload)

let test_each_owner_call_retains_only_its_own_receipt () =
  with_workspace ~response_kind:"recorded" @@ fun execute requests ->
  let first = execute ~always_allow:true ["echo"; "first"] in
  let second = execute ~always_allow:true ["echo"; "second"] in
  List.iter (fun (ordinal, exit_code, payload) ->
    assert_payload ~ordinal ~exit_code payload;
    let evidence = single_receipt payload in
    check string "receipt is observed" "observed" (text "status" evidence);
    check string "unboxed effect receipt is preserved" "effect" (field "receipt" evidence |> text "mode");
    check string "effect receipt retains its reported plan" "unrestricted" (field "receipt" evidence |> text "plan");
    check int "each receipt has its own exit" exit_code (field "outcome" evidence |> integer "exit"))
    [1, 3, first; 2, 7, second];
  check (list string) "two separate owner calls reached transport" ["effect"; "effect"]
    (List.map (text "mode") (requests ()))

let test_observe_result_is_reused_by_actual_owner () =
  with_workspace ~response_kind:"recorded" @@ fun execute requests ->
  let payload = execute ~always_allow:false ["git"; "status"] in
  assert_payload ~ordinal:1 ~exit_code:0 payload;
  let receipt = single_receipt payload |> field "receipt" in
  check string "actual observation mode survives owner settlement" "observe" (text "mode" receipt);
  check string "reported box boundary survives" "sandbox_applied" (text "boundary" receipt);
  check (list string) "completed Observe was not dispatched again as Effect" ["observe"]
    (List.map (text "mode") (requests ()))

let test_unavailable_receipt_does_not_erase_process_result () =
  List.iter (fun (response_kind, reason) ->
    with_workspace ~response_kind @@ fun execute requests ->
    let payload = execute ~always_allow:true ["echo"; "first"] in
    assert_payload ~ordinal:1 ~exit_code:3 payload;
    let receipt = single_receipt payload in
    check string "receipt availability is explicit" "unavailable" (text "status" receipt);
    check string "exact receipt failure survives" reason (text "reason" receipt);
    check bool "no receipt was invented from the requested mode" true (field "receipt" receipt = `Null);
    check int "receipt absence never causes another dispatch" 1 (List.length (requests ())))
    ["missing", "peer_receipt_missing"; "invalid", "invalid_receipt"]

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--ssh-receipt-stub"
  then stub_main ()
  else Alcotest.run "keeper_execute_shim_evidence"
    ["actual-owner", [
      test_case "each call keeps its own receipt and nonzero exit" `Quick test_each_owner_call_retains_only_its_own_receipt;
      test_case "Observe result is reused without Effect redispatch" `Quick test_observe_result_is_reused_by_actual_owner;
      test_case "missing and malformed receipts preserve exit and streams" `Quick test_unavailable_receipt_does_not_erase_process_result]]
