(* Paste delivery to endpoint-owned keeper workspaces.

   The TUI stages a spilled paste under the keeper's host bookkeeping bundle,
   and at turn setup [Keeper_paste_delivery] writes each staged file to the
   endpoint's workspace root and removes the staged copy. Coverage:

   - selection and retention with an injected transport (no endpoint);
   - the production transport ([write_through_endpoint]) driven against a
     stub endpoint CLI, pinning that a staged paste lands at the endpoint's
     workspace root under its bare name -- the same place the keeper's Read
     of that name resolves to ([Keeper_remote_path] translation, pinned
     separately in test_keeper_remote_path) -- and that "delivered" is only
     claimed after the read-back through the same endpoint finds the same
     byte count (a mismatch or a failed read-back retains the paste);
   - [deliver_for_turn]'s profile gate: no-op for Shared_mount, typed
     retention when an endpoint cannot be acquired;
   - the writer/matcher naming contract across the bin/lib boundary;
   - the turn-message correction for retained pastes. *)

open Alcotest
module Delivery = Masc.Keeper_paste_delivery
module Naming = Keeper_paste_naming

(* ── Staging fixture ─────────────────────────────────────────────── *)

let with_staging_dir f =
  let dir = Filename.temp_dir "keeper-paste-delivery" "" in
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:(fun () -> (try rm dir with _ -> ())) (fun () -> f dir)
;;

let write_staged dir name content =
  let channel = open_out_bin (Filename.concat dir name) in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let paste_a = "pasted-20260903-1000-a1b2c3d4.txt"
let paste_b = "pasted-20260903-1100-e5f6a7b8.txt"

(* ── Selection and retention with an injected transport ─────────── *)

(* A turn with pastes, notes, and a stray directory in the bundle delivers
   the pastes — contents intact, staged copies gone — and touches nothing
   else. *)
let test_delivers_only_staged_pastes () =
  with_staging_dir (fun dir ->
    write_staged dir paste_a "first paste body";
    write_staged dir paste_b "second paste body";
    write_staged dir "notes.txt" "not a paste";
    write_staged dir "pasted-notes.md" "not the staged suffix";
    (* Same prefix and suffix but not the naming contract's shape: a file
       the operator dropped, not a spill. *)
    write_staged dir "pasted-notes.txt" "not a spill";
    (* A directory whose name fits the contract is still not a staged file. *)
    Unix.mkdir (Filename.concat dir "pasted-20260903-1200-b1b2c3d4.txt") 0o755;
    let delivered = ref [] in
    let write ~file_name ~content =
      delivered := (file_name, content) :: !delivered;
      Ok ()
    in
    let outcomes = Delivery.deliver_staged_pastes ~write ~staging_dir:dir in
    let expected =
      [ paste_a, "first paste body"; paste_b, "second paste body" ]
    in
    let delivered_names =
      List.filter_map
        (fun outcome ->
           match outcome with
           | Delivery.Delivered { file_name; bytes } ->
             check int "byte count is the staged content's"
               (String.length (List.assoc file_name expected))
               bytes;
             Some file_name
           | Delivery.Retained { file_name; _ } ->
             failf "%s stayed staged though the write succeeded" file_name)
        outcomes
    in
    check
      (list string)
      "exactly the two staged pastes delivered"
      (List.map fst expected)
      delivered_names;
    check
      (list (pair string string))
      "the transport saw the same two, with their contents"
      expected
      (List.sort compare !delivered);
    List.iter
      (fun file_name ->
        if Sys.file_exists (Filename.concat dir file_name)
        then failf "%s still staged after a successful delivery" file_name)
      delivered_names;
    check bool "unrelated file untouched" true
      (String.equal (read_file (Filename.concat dir "notes.txt")) "not a paste");
    check bool "wrong-suffix file untouched" true
      (Sys.file_exists (Filename.concat dir "pasted-notes.md"));
    check bool "non-contract name untouched" true
      (Sys.file_exists (Filename.concat dir "pasted-notes.txt"));
    check bool "same-shaped directory untouched" true
      (Sys.is_directory (Filename.concat dir "pasted-20260903-1200-b1b2c3d4.txt")))
;;

(* failure_keeps_evidence: a refused endpoint write leaves the staged file
   for the next turn, and the outcome carries the reason and the text. *)
let test_failed_write_retains_the_staged_paste () =
  with_staging_dir (fun dir ->
    write_staged dir paste_a "paste body";
    let write ~file_name:_ ~content:_ =
      Error (Delivery.Remote_write_failed "endpoint unreachable")
    in
    match Delivery.deliver_staged_pastes ~write ~staging_dir:dir with
    | [ Delivery.Retained { file_name; reason; content } ] ->
      check string "the retained file is the staged paste" paste_a file_name;
      (match reason with
       | Delivery.Remote_write_failed detail ->
         check string "the endpoint's answer is the retained evidence"
           "endpoint unreachable" detail
       | Delivery.Endpoint_unavailable _ | Delivery.Staging_read_failed _
       | Delivery.Readback_mismatch _ ->
         fail "the staged file was readable; the endpoint refused the write");
      check (option string) "the text rides along for the fallback"
        (Some "paste body") content;
      check bool "staged copy kept for the next turn" true
        (String.equal
           (read_file (Filename.concat dir file_name))
           "paste body")
    | outcomes ->
      failf "one refused write must retain one paste, got %d outcome(s)"
        (List.length outcomes))
;;

(* ── Writer/matcher naming contract across the bin/lib boundary ──── *)

let test_writer_names_are_recognised_by_the_matcher () =
  (* Larger than either inline threshold, so the spill path runs. *)
  let text = String.make (9 * 1024) 'x' in
  match Masc_tui_paste_spill.of_paste ~now_iso:"20260903-1042" ~nonce:"a1b2c3d4" text with
  | None -> fail "a paste past the inline thresholds spills"
  | Some spill ->
    (match Naming.parse spill.Masc_tui_paste_spill.file_name with
     | Some { now_iso; nonce } ->
       check string "timestamp round-trips" "20260903-1042" now_iso;
       check string "nonce round-trips" "a1b2c3d4" nonce
     | None ->
       failf "delivery matcher rejects the writer's name %S"
         spill.Masc_tui_paste_spill.file_name)
;;

(* ── deliver_for_turn's profile gate ─────────────────────────────── *)

let make_meta sandbox_profile name =
  match
    Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String name ])
  with
  | Ok meta ->
    { meta with Masc.Keeper_meta_contract.sandbox_profile = sandbox_profile }
  | Error error -> fail error
;;

(* Docker keepers read the staged file through the bind mount themselves:
   delivery is a no-op and nothing is reported retained. *)
let test_shared_mount_is_a_noop () =
  with_staging_dir (fun dir ->
    write_staged dir paste_a "paste body";
    let config = Masc.Workspace.default_config dir in
    let meta = make_meta Keeper_types_profile_sandbox.Docker "keeper-docker" in
    (* host_root_abs_of_meta for Docker is [dir]/.masc/playground/docker/<name>,
       not [dir] itself -- stage the file where the profile actually reads. *)
    let staging_dir = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
    Fs_compat.mkdir_p staging_dir;
    write_staged staging_dir paste_a "paste body";
    let retained =
      Delivery.deliver_for_turn ~config ~meta ~turn_sandbox_factory:None
    in
    check int "nothing retained, nothing delivered" 0 (List.length retained);
    check bool "staged file left for the keeper to read" true
      (Sys.file_exists (Filename.concat staging_dir paste_a)))
;;

(* A microvm keeper with no turn sandbox factory cannot have its guest
   started; the paste is retained with the typed reason and stays staged. *)
let test_endpoint_owned_without_factory_retains () =
  with_staging_dir (fun dir ->
    let config = Masc.Workspace.default_config dir in
    let meta = make_meta Keeper_types_profile_sandbox.Micro_vm "keeper-vm" in
    let staging_dir = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
    Fs_compat.mkdir_p staging_dir;
    write_staged staging_dir paste_a "paste body";
    match
      Delivery.deliver_for_turn ~config ~meta ~turn_sandbox_factory:None
    with
    | [ { Delivery.file_name; reason; content } ] ->
      check string "the retained file is the staged paste" paste_a file_name;
      (match reason with
       | Delivery.Endpoint_unavailable _ -> ()
       | Delivery.Staging_read_failed _ | Delivery.Remote_write_failed _
       | Delivery.Readback_mismatch _ ->
         fail "no endpoint was ever acquired, so no write was attempted");
      check (option string) "the text rides along for the fallback"
        (Some "paste body") content;
      check bool "staged copy kept for the next turn" true
        (Sys.file_exists (Filename.concat staging_dir paste_a))
    | retained ->
      failf "one unreachable endpoint must retain one paste, got %d"
        (List.length retained))
;;

(* ── The production transport against a stub endpoint ─────────────── *)

(* Same stub contract as test_keeper_tool_filesystem_remote_write: the stub
   decodes the framed request, records it beside itself, and answers with
   the trailer for the payload's exit code. Here the stub is also the fake
   endpoint's filesystem: a write payload's stdin is stored by basename, and
   a read-back request answers the stored byte count — so the delivery's
   read-back verification is exercised end to end. [mode] scripts the
   failure classes: ["truncate"] stores one byte short (the write reports
   success while the endpoint holds fewer bytes), ["fail-readback"] answers
   the read-back with exit 1. *)

let write_all fd content =
  let bytes = Bytes.unsafe_of_string content in
  let rec loop offset =
    if offset < Bytes.length bytes
    then
      let wrote = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + wrote)
  in
  loop 0
;;

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then
      let got = Unix.read fd bytes offset (length - offset) in
      if got = 0 then failwith "paste delivery stub: truncated frame" else loop (offset + got)
  in
  loop 0;
  Bytes.unsafe_to_string bytes
;;

let save path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let stub_main () =
  let frame_path = Sys.argv.(2) in
  let mode = if Array.length Sys.argv > 3 then Sys.argv.(3) else "ok" in
  let header = read_exact Unix.stdin 8 in
  let body_len = Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int in
  let frame = header ^ read_exact Unix.stdin body_len in
  let trailer exit_code =
    Exec_ssh_protocol.render_trailer
      { v = Exec_ssh_protocol.protocol_version; exit = Some exit_code; signal = None
      ; timed_out = false; shim_error = None }
  in
  match Exec_ssh_protocol.decode_request frame with
  | Error error ->
    write_all Unix.stderr
      (Exec_ssh_protocol.render_trailer
         { v = Exec_ssh_protocol.protocol_version; exit = None; signal = None
         ; timed_out = false; shim_error = Some error });
    exit 1
  | Ok (request, stdin) ->
    let fs_dir = frame_path ^ ".fs" in
    let remote_path = List.nth request.argv (List.length request.argv - 1) in
    let stored = Filename.concat fs_dir (Filename.basename remote_path) in
    (match request.argv with
     | [ "sh"; "-c"; script; _; _ ]
       when String.equal script Delivery.readback_script ->
       save (frame_path ^ ".readback") frame;
       (match String.equal mode "fail-readback", Sys.file_exists stored with
        | true, _ | _, false ->
          (* wc(1) of a missing file exits 1; so does a read-back the lane
             cannot complete. *)
          write_all Unix.stderr (trailer 1);
          exit 0
        | false, true ->
          write_all Unix.stdout
            (Printf.sprintf "%d\n" (String.length (read_file stored)));
          write_all Unix.stderr (trailer 0);
          exit 0)
     | _ ->
       save (frame_path ^ ".write") frame;
       (try Unix.mkdir fs_dir 0o755
        with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
       let stored_bytes =
         if String.equal mode "truncate" && String.length stdin > 0
         then String.sub stdin 0 (String.length stdin - 1)
         else stdin
       in
       save stored stored_bytes;
       write_all Unix.stderr (trailer 0);
       exit 0)
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

(* One staged paste, one stub endpoint in [mode], delivered through the
   production transport; [f] gets the outcomes, the staging dir and the
   stub's recording path. *)
let deliver_with_stub ~mode ~content f =
  with_eio @@ fun () ->
  with_staging_dir (fun dir ->
    let config = Masc.Workspace.default_config dir in
    let meta = make_meta Keeper_types_profile_sandbox.Remote_ssh "keeper-a" in
    let staging_dir = Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
    Fs_compat.mkdir_p staging_dir;
    write_staged staging_dir paste_a content;
    let frame_path = Filename.concat dir "frame" in
    let cli = Filename.concat dir "cli-stub" in
    save cli
      (Printf.sprintf "#!/bin/sh\nexec %s --paste-delivery-stub %s %s \"$@\"\n"
         (shell_quote Sys.executable_name)
         (shell_quote frame_path)
         (shell_quote mode));
    Unix.chmod cli 0o755;
    let endpoint =
      Masc.Keeper_sandbox_remote.of_container_exec ~base_path:dir
        ~keeper_name:"keeper-a" ~remote_root:"/masc-work"
        ~gh_config_dir:"/identity/gh" ~injected_env:[] ~env_allowlist:[]
        ~connect_timeout_sec:1 ~max_concurrent_sessions:2
        { Masc.Keeper_sandbox_remote.prefix =
            [ cli; "exec"; "-i"; "--user"; "501:20"; "-w"; "/masc-work"
            ; "--env"
            ; "MASC_EXEC_SHIM_CONFIG=/opt/masc-exec-shim/masc-exec-shim.conf"
            ; "masc-keeper-vm-keeper-a"
            ]
        ; container_name = "masc-keeper-vm-keeper-a"
        ; shim_path = "/opt/masc-exec-shim/masc-exec-shim"
        }
    in
    let outcomes =
      Delivery.deliver_staged_pastes
        ~write:(Delivery.write_through_endpoint ~endpoint ~config ~meta)
        ~staging_dir
    in
    f ~staging_dir ~frame_path outcomes)
;;

(* A staged paste delivered through the production transport lands at the
   endpoint's workspace root under its bare name — the same path the
   keeper's Read of that name resolves to — and is only called delivered
   after the read-back finds the same byte count at that path. *)
let test_delivery_lands_at_the_endpoint_workspace_root () =
  let content = "pasted body over the wire" in
  deliver_with_stub ~mode:"ok" ~content @@ fun ~staging_dir ~frame_path outcomes ->
  (match outcomes with
   | [ Delivery.Delivered { file_name; bytes } ] ->
     check string "the staged paste delivered" paste_a file_name;
     check int "byte count" (String.length content) bytes
   | outcomes ->
     failf "one staged paste must deliver, got %d outcome(s)"
       (List.length outcomes));
  check bool "staged copy removed" false
    (Sys.file_exists (Filename.concat staging_dir paste_a));
  let remote_path = "/masc-work/keeper-a/" ^ paste_a in
  (match Exec_ssh_protocol.decode_request (read_file (frame_path ^ ".write")) with
   | Error error -> fail error
   | Ok (request, stdin) ->
     check (list string) "atomic replace payload at the translated bare name"
       (Masc.Keeper_tool_filesystem_remote_write.write_argv
          ~mode:Masc.Keeper_tool_filesystem_remote_write.Replace_whole
          ~remote_path)
       request.argv;
     check string "the paste text travels on stdin" content stdin;
     check string "runs from the keeper's workspace root"
       "/masc-work/keeper-a" request.cwd);
  match Exec_ssh_protocol.decode_request (read_file (frame_path ^ ".readback")) with
  | Error error -> fail error
  | Ok (request, _stdin) ->
    check (list string) "read-back counts bytes at the same translated path"
      (Delivery.readback_argv ~remote_path)
      request.argv
;;

(* The incident class from #33010: the write reports success, but what the
   endpoint holds is not what it was handed. The paste is retained with the
   read-back reason — the staged copy stays, so the inlined-correction
   fallback carries the text to the keeper. *)
let test_readback_count_mismatch_retains_the_staged_paste () =
  let content = "pasted body over the wire" in
  deliver_with_stub ~mode:"truncate" ~content @@ fun ~staging_dir ~frame_path:_ outcomes ->
  match outcomes with
  | [ Delivery.Retained { file_name; reason; content = retained } ] ->
    check string "the retained file is the staged paste" paste_a file_name;
    (match reason with
     | Delivery.Readback_mismatch detail ->
       check bool "names the byte counts" true
         (Astring.String.is_infix
            ~affix:(Printf.sprintf "%d bytes" (String.length content - 1))
            detail)
     | Delivery.Endpoint_unavailable _ | Delivery.Staging_read_failed _
     | Delivery.Remote_write_failed _ ->
       fail "the write succeeded; the read-back disagreed")
    ;
    check (option string) "the text rides along for the fallback"
      (Some content) retained;
    check bool "staged copy kept for the next turn" true
      (String.equal (read_file (Filename.concat staging_dir paste_a)) content)
  | outcomes ->
    failf "a disagreeing read-back must retain one paste, got %d outcome(s)"
      (List.length outcomes)
;;

(* A read-back that cannot complete — the lane answers non-zero — is the
   same retention: "delivered" is never claimed on an unverified write. *)
let test_readback_failure_retains_the_staged_paste () =
  let content = "pasted body over the wire" in
  deliver_with_stub ~mode:"fail-readback" ~content
  @@ fun ~staging_dir ~frame_path:_ outcomes ->
  match outcomes with
  | [ Delivery.Retained { file_name; reason; content = retained } ] ->
    check string "the retained file is the staged paste" paste_a file_name;
    (match reason with
     | Delivery.Readback_mismatch detail ->
       check bool "says the read-back failed" true
         (Astring.String.is_infix ~affix:"read-back" detail)
     | Delivery.Endpoint_unavailable _ | Delivery.Staging_read_failed _
     | Delivery.Remote_write_failed _ ->
       fail "the write succeeded; the read-back could not complete");
    check (option string) "the text rides along for the fallback"
      (Some content) retained;
    check bool "staged copy kept for the next turn" true
      (String.equal (read_file (Filename.concat staging_dir paste_a)) content)
  | outcomes ->
    failf "a failed read-back must retain one paste, got %d outcome(s)"
      (List.length outcomes)
;;

(* ── The turn-message correction for retained pastes ──────────────── *)

let test_correction_inlines_the_retained_text () =
  match
    Delivery.inlined_correction
      [ { Delivery.file_name = paste_a
        ; reason = Delivery.Remote_write_failed "endpoint unreachable"
        ; content = Some "paste body"
        }
      ]
  with
  | None -> fail "a retained paste produces a correction"
  | Some correction ->
    check bool "names the file" true
      (Astring.String.is_infix ~affix:paste_a correction);
    check bool "says the file is not in the workspace" true
      (Astring.String.is_infix ~affix:"It is not" correction);
    check bool "carries the text" true
      (Astring.String.is_infix ~affix:"paste body" correction)
;;

let test_no_retention_no_correction () =
  check (option string) "empty retained set" None
    (Delivery.inlined_correction [])
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--paste-delivery-stub"
  then stub_main ()
  else
    run
      "keeper_paste_delivery"
      [ ( "staging"
        , [ test_case "delivers only staged pastes" `Quick test_delivers_only_staged_pastes
          ; test_case "failed write retains the staged paste" `Quick
              test_failed_write_retains_the_staged_paste
          ] )
      ; ( "naming contract"
        , [ test_case "writer names are recognised by the matcher" `Quick
              test_writer_names_are_recognised_by_the_matcher
          ] )
      ; ( "turn wiring"
        , [ test_case "shared mount is a no-op" `Quick test_shared_mount_is_a_noop
          ; test_case "endpoint-owned without factory retains" `Quick
              test_endpoint_owned_without_factory_retains
          ; test_case "delivery lands at the endpoint workspace root" `Quick
              test_delivery_lands_at_the_endpoint_workspace_root
          ; test_case "read-back count mismatch retains the staged paste" `Quick
              test_readback_count_mismatch_retains_the_staged_paste
          ; test_case "read-back failure retains the staged paste" `Quick
              test_readback_failure_retains_the_staged_paste
          ] )
      ; ( "correction"
        , [ test_case "correction inlines the retained text" `Quick
              test_correction_inlines_the_retained_text
          ; test_case "no retention no correction" `Quick test_no_retention_no_correction
          ] )
      ]
;;
