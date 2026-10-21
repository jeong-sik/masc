(* Whether a microVM guest is there when its runtime's inspect did not say.

   Measured 2026-10-21 on container 1.3.1: inspect exits 1 for a name with no
   guest, and exits 1 again when the apiserver stalls before it can look
   ("failed to list containers ... XPC timeout"). Reading every non-zero
   inspect as absent let a start delete a running guest and boot another
   beside it, and let a teardown release the credential snapshot that guest
   still mounts (#44676). The runtime's listing tells the two apart. A
   listing that cannot be read leaves the state unknown, and no caller may
   act on unknown as absence. *)

module M = Masc.Keeper_sandbox_microvm
module Backend = Masc.Keeper_microvm_backend
module Turn = Masc.Keeper_turn_sandbox_runtime
module Runtime = Masc.Keeper_sandbox_runtime
module Profile = Keeper_types_profile_sandbox

let guest = "masc-keeper-vm-probe-none-0123abcd"
let other_guest = "masc-keeper-vm-someone-else-none-0123abcd"

let state_label = function
  | Ok Runtime.Docker_container_running -> "running"
  | Ok Runtime.Docker_container_stopped -> "stopped"
  | Ok Runtime.Docker_container_absent -> "absent"
  | Error _ -> "unknown"
;;

let classify backend ~inspect ~listing =
  state_label (M.classify_guest_probe_for backend ~container_name:guest ~inspect ~listing)
;;

let all_backends = Backend.all

(* What each runtime answers, in the shapes masc parses. *)
let running_inspect = function
  | Backend.Apple_container -> {|[{"status":{"state":"running"}}]|}
  | Backend.Microsandbox -> {|{"name":"g","status":"Running"}|}
  | Backend.Nerdctl_kata -> "true"
;;

let stopped_inspect = function
  | Backend.Apple_container -> {|[{"status":{"state":"stopped"}}]|}
  | Backend.Microsandbox -> {|{"name":"g","status":"Stopped"}|}
  | Backend.Nerdctl_kata -> "false"
;;

let nerdctl_row ~id ~name =
  Printf.sprintf
    {|{"id":"%s","name":"%s","image":"img","status":"Up 5 minutes","created_at":"2026-10-21","runtime":"%s","labels":null}|}
    id
    name
    Backend.kata_containerd_shim
;;

let listing_of_names backend names =
  match backend with
  | Backend.Apple_container ->
    "["
    ^ String.concat
        ","
        (List.map
           (fun name ->
              Printf.sprintf
                {|{"id":"%s","configuration":{"id":"%s"},"status":{"state":"running"}}|}
                name
                name)
           names)
    ^ "]"
  | Backend.Microsandbox ->
    "["
    ^ String.concat
        ","
        (List.map
           (fun name ->
              Printf.sprintf
                {|{"created_at":"2026-10-21","image":"alpine","name":"%s","status":"Running"}|}
                name)
           names)
    ^ "]"
  | Backend.Nerdctl_kata ->
    String.concat
      "\n"
      (List.mapi
         (fun index name -> nerdctl_row ~id:(Printf.sprintf "%064x" (index + 1)) ~name)
         names)
;;

let not_found = Unix.WEXITED 1, "Error: container not found"

let stalled =
  ( Unix.WEXITED 1
  , {|Error: failed to list containers (cause: "internalError: XPC timeout for request to com.apple.container.apiserver/containerList")|}
  )
;;

let listed backend names = Some (Unix.WEXITED 0, listing_of_names backend names, "")

let check_each label expected f =
  List.iter
    (fun backend ->
       Alcotest.(check string)
         (Printf.sprintf "%s (%s)" label (Backend.to_string backend))
         expected
         (f backend))
    all_backends
;;

(* ── the classifier ─────────────────────────────────────────────────── *)

let test_an_inspect_that_answers_is_the_whole_answer () =
  check_each "inspect running" "running" (fun backend ->
    classify backend ~inspect:(Unix.WEXITED 0, running_inspect backend) ~listing:None);
  check_each "inspect stopped" "stopped" (fun backend ->
    classify backend ~inspect:(Unix.WEXITED 0, stopped_inspect backend) ~listing:None);
  (* A listing handed in beside an answering inspect is not read. *)
  check_each "listing beside an answer" "running" (fun backend ->
    classify backend ~inspect:(Unix.WEXITED 0, running_inspect backend)
      ~listing:(listed backend []))
;;

let test_a_listing_without_the_name_is_absent () =
  check_each "empty listing" "absent" (fun backend ->
    classify backend ~inspect:not_found ~listing:(listed backend []));
  check_each "listing of other guests" "absent" (fun backend ->
    classify backend ~inspect:not_found ~listing:(listed backend [ other_guest ]));
  (* A timed-out inspect ends on a signal; the listing still settles it. *)
  check_each "signalled inspect, empty listing" "absent" (fun backend ->
    classify backend ~inspect:(Unix.WSIGNALED Sys.sigkill, "") ~listing:(listed backend []))
;;

let test_a_listing_that_cannot_be_read_is_unknown () =
  check_each "stalled inspect, stalled listing" "unknown" (fun backend ->
    let status, stderr = stalled in
    classify backend ~inspect:stalled ~listing:(Some (status, "", stderr)));
  check_each "signalled listing" "unknown" (fun backend ->
    classify backend ~inspect:(Unix.WSIGNALED Sys.sigkill, "")
      ~listing:(Some (Unix.WSIGNALED Sys.sigkill, "", "")));
  check_each "no listing taken" "unknown" (fun backend ->
    classify backend ~inspect:not_found ~listing:None);
  check_each "listing that is not JSON" "unknown" (fun backend ->
    classify backend ~inspect:not_found ~listing:(Some (Unix.WEXITED 0, "not json", "")));
  (* A row that names no guest could be the guest asked about. *)
  Alcotest.(check string) "container row without an id" "unknown"
    (classify Backend.Apple_container ~inspect:not_found
       ~listing:(Some (Unix.WEXITED 0, {|[{"status":{"state":"running"}}]|}, "")));
  Alcotest.(check string) "msb row without a name" "unknown"
    (classify Backend.Microsandbox ~inspect:not_found
       ~listing:(Some (Unix.WEXITED 0, {|[{"status":"Running"}]|}, "")));
  Alcotest.(check string) "nerdctl row without a full id" "unknown"
    (classify Backend.Nerdctl_kata ~inspect:not_found
       ~listing:(Some (Unix.WEXITED 0, nerdctl_row ~id:"abc" ~name:other_guest, "")))
;;

let test_a_listed_guest_takes_the_listed_state () =
  Alcotest.(check string) "container lists it running" "running"
    (classify Backend.Apple_container ~inspect:not_found
       ~listing:(listed Backend.Apple_container [ guest ]));
  Alcotest.(check string) "container lists it stopped" "stopped"
    (classify Backend.Apple_container ~inspect:not_found
       ~listing:
         (Some
            ( Unix.WEXITED 0
            , Printf.sprintf {|[{"id":"%s","status":{"state":"stopped"}}]|} guest
            , "" )));
  Alcotest.(check string) "container lists it without a state" "unknown"
    (classify Backend.Apple_container ~inspect:not_found
       ~listing:(Some (Unix.WEXITED 0, Printf.sprintf {|[{"id":"%s"}]|} guest, "")));
  Alcotest.(check string) "msb lists it running" "running"
    (classify Backend.Microsandbox ~inspect:not_found
       ~listing:(listed Backend.Microsandbox [ guest ]));
  Alcotest.(check string) "msb lists it stopped" "stopped"
    (classify Backend.Microsandbox ~inspect:not_found
       ~listing:
         (Some
            ( Unix.WEXITED 0
            , Printf.sprintf {|[{"name":"%s","status":"Stopped"}]|} guest
            , "" )));
  (* ps Status is display text, so a listed nerdctl guest has no state. *)
  Alcotest.(check string) "nerdctl lists it" "unknown"
    (classify Backend.Nerdctl_kata ~inspect:not_found
       ~listing:(listed Backend.Nerdctl_kata [ guest ]));
  check_each "listed twice" "unknown" (fun backend ->
    classify backend ~inspect:not_found ~listing:(listed backend [ guest; guest ]))
;;

let test_the_listing_asked_per_backend () =
  let labelled backend =
    match M.container_listing_for backend with
    | M.Labelled_json_array argv | M.Nerdctl_labelled_json_lines argv -> Some argv
    | M.Listing_not_established _ -> None
  in
  List.iter
    (fun backend ->
       let expected =
         match backend, labelled backend with
         | (Backend.Apple_container | Backend.Nerdctl_kata), Some argv -> argv
         | Backend.Microsandbox, None -> [ "msb"; "list"; "--format"; "json" ]
         | (Backend.Apple_container | Backend.Nerdctl_kata), None
         | Backend.Microsandbox, Some _ ->
           Alcotest.failf "unexpected labelled listing for %s" (Backend.to_string backend)
       in
       Alcotest.(check (list string))
         (Backend.to_string backend)
         expected
         (M.guest_listing_argv_for backend))
    all_backends
;;

(* ── the callers, against a fake runtime CLI ────────────────────────── *)

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let with_eio_fs f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

let microvm_meta ~name ~backend : Masc.Keeper_meta_contract.keeper_meta =
  let json = `Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta ->
    { meta with
      sandbox_profile = Profile.Micro_vm
    ; microvm_backend = Some backend
    ; network_mode = Profile.Network_none
    }
  | Error e -> Alcotest.fail e
;;

type runtime_mode =
  | Guest_absent
  | Apiserver_stalled
  | Guest_running
  | Inspect_stalled_listing of string
      (** Inspect stalls; the listing answers with this text. *)

let mode_word = function
  | Guest_absent -> "absent"
  | Apiserver_stalled -> "stalled"
  | Guest_running -> "running"
  | Inspect_stalled_listing _ -> "listed"
;;

let mode_listing = function
  | Inspect_stalled_listing listing -> listing
  | Guest_absent | Apiserver_stalled | Guest_running -> ""
;;

(* The listing an empty host answers: nerdctl's is a JSON line per guest, so
   an empty one prints nothing. *)
let empty_listing = function
  | Backend.Apple_container | Backend.Microsandbox -> "[]"
  | Backend.Nerdctl_kata -> ""
;;

(* A runtime CLI on PATH that logs each call's argv and answers inspect and
   the listing from the mode file, so one test can move it between modes.
   [after_boot] names the mode the runtime moves to once a guest's
   [run -d] exits 0. The image, volume and exec calls a boot makes succeed,
   and the shim a boot mounts is installed under the base path. *)
let with_fake_cli backend f =
  with_eio_fs
  @@ fun () ->
  let context = Eio_context.snapshot_state () in
  let dir = temp_dir "microvm-guest-probe-" in
  let bin = Filename.concat dir "bin" in
  let base = Filename.concat dir "base" in
  List.iter (fun path -> Unix.mkdir path 0o755) [ bin; base ];
  let log = Filename.concat dir "calls" in
  let write path text =
    Out_channel.with_open_bin path (fun channel -> output_string channel text)
  in
  let mode_file = Filename.concat dir "mode" in
  let listed_file = Filename.concat dir "listed" in
  let after_mode_file = Filename.concat dir "after-mode" in
  let after_listed_file = Filename.concat dir "after-listed" in
  let set_mode mode =
    write mode_file (mode_word mode);
    write listed_file (mode_listing mode)
  in
  let after_boot mode =
    write after_mode_file (mode_word mode);
    write after_listed_file (mode_listing mode)
  in
  set_mode Guest_absent;
  let shim_dir = List.fold_left Filename.concat base [ ".masc"; "microvm"; "shim" ] in
  List.iter
    (fun path -> Unix.mkdir path 0o755)
    [ Filename.concat base ".masc"
    ; List.fold_left Filename.concat base [ ".masc"; "microvm" ]
    ; shim_dir
    ];
  let shim_contents = "#!/bin/sh\nexit 0\n" in
  let shim = Filename.concat shim_dir M.shim_binary_name in
  write shim shim_contents;
  Unix.chmod shim 0o755;
  write
    (Filename.concat shim_dir M.shim_sidecar_name)
    (Digestif.SHA256.(to_hex (digest_string shim_contents)) ^ "  masc-exec-shim\n");
  let cli = Filename.concat bin (Backend.cli_name backend) in
  Out_channel.with_open_bin cli (fun channel ->
    Printf.fprintf
      channel
      {|#!/bin/sh
printf '%%s\n' "$*" >> %s
mode=$(cat %s)
case "$1" in
  stop|delete|rm|remove|exec) exit 0 ;;
  image) printf '[]\n' ;;
  volume) case "$2" in inspect|delete) exit 0 ;; *) exit 99 ;; esac ;;
  run)
    if [ "$2" = -d ] && [ -e %s ]; then cp %s %s; cp %s %s; fi ;;
  inspect|list|ps)
    case "$mode" in
      stalled)
        echo 'Error: failed to list containers (cause: "internalError: XPC timeout for request to com.apple.container.apiserver/containerList")' >&2
        exit 1 ;;
      absent)
        case "$1" in
          inspect) echo "Error: container not found" >&2; exit 1 ;;
          *) printf '%%s\n' %s ;;
        esac ;;
      running)
        case "$1" in
          inspect) printf '%%s\n' %s ;;
          *) printf '%%s\n' %s ;;
        esac ;;
      listed)
        case "$1" in
          inspect) echo 'Error: XPC timeout' >&2; exit 1 ;;
          *) cat %s ;;
        esac ;;
    esac ;;
  *) exit 99 ;;
esac
|}
      (Filename.quote log)
      (Filename.quote mode_file)
      (Filename.quote after_mode_file)
      (Filename.quote after_mode_file)
      (Filename.quote mode_file)
      (Filename.quote after_listed_file)
      (Filename.quote listed_file)
      (Filename.quote (empty_listing backend))
      (Filename.quote (running_inspect backend))
      (Filename.quote (empty_listing backend))
      (Filename.quote listed_file));
  Unix.chmod cli 0o755;
  let previous_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (bin ^ ":" ^ previous_path);
  Fun.protect
    ~finally:(fun () ->
      Eio_context.restore_state context;
      Unix.putenv "PATH" previous_path;
      Fs_compat.remove_tree dir)
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.set_switch sw;
  let calls () =
    if Sys.file_exists log
    then
      In_channel.with_open_bin log In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun line -> not (String.equal line ""))
    else []
  in
  let forget_calls () = if Sys.file_exists log then Unix.unlink log in
  f ~config:(Masc.Workspace.default_config base) ~set_mode ~after_boot ~calls ~forget_calls
;;

let guest_name ~config ~(meta : Masc.Keeper_meta_contract.keeper_meta) =
  Turn.For_testing_microvm.microvm_container_name
    ~config
    ~keeper_name:meta.name
    ~network_mode:meta.network_mode
;;

let is_listing_call line =
  String.starts_with ~prefix:"list " line || String.starts_with ~prefix:"ps " line
;;

(* The calls after the guest's own [run -d], or [None] when it never ran. *)
let calls_after_boot ~guest calls =
  let boot = "run -d --name " ^ guest ^ " " in
  let rec after = function
    | [] -> None
    | line :: rest -> if String.starts_with ~prefix:boot line then Some rest else after rest
  in
  after calls
;;

(* The start reads the guest's state before anything else touches it. On
   [Docker_container_absent] it clears the name with [delete --force] and
   boots; that is what a stalled apiserver must not reach. *)
let test_a_start_during_a_stall_neither_deletes_nor_boots () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot:_ ~calls ~forget_calls:_ ->
  set_mode Apiserver_stalled;
  let meta = microvm_meta ~name:"probe-stalled-start" ~backend:Backend.Apple_container in
  let runtime =
    Turn.create ~config ~meta ~image:(Ok "probe-fixture") ~network_mode:meta.network_mode ()
  in
  let guest = guest_name ~config ~meta in
  (match Turn.microvm_remote_endpoint ~timeout_sec:5. runtime with
   | Ok _ -> Alcotest.fail "a start that could not read its guest returned an endpoint"
   | Error _ -> ());
  let calls = calls () in
  Alcotest.(check bool) "the guest's name is not deleted" false
    (List.mem ("delete --force " ^ guest) calls);
  Alcotest.(check bool) "no guest is booted" false
    (List.exists (String.starts_with ~prefix:"run ") calls);
  Alcotest.(check bool) "the guest was inspected" true (List.mem ("inspect " ^ guest) calls);
  Alcotest.(check bool) "the listing was asked" true (List.exists is_listing_call calls)
;;

(* The other side of the same start: a listing that answers without the name
   is a real absence, so the name is cleared and a guest is booted. *)
let test_a_start_with_a_confirmed_absence_boots () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot ~calls ~forget_calls:_ ->
  set_mode Guest_absent;
  after_boot Guest_running;
  let meta = microvm_meta ~name:"probe-absent-start" ~backend:Backend.Apple_container in
  let runtime =
    Turn.create ~config ~meta ~image:(Ok "probe-fixture") ~network_mode:meta.network_mode ()
  in
  let guest = guest_name ~config ~meta in
  (match Turn.microvm_remote_endpoint ~timeout_sec:5. runtime with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "a confirmed absence must boot a guest: %s" detail);
  let calls = calls () in
  Alcotest.(check bool) "the name is cleared for the boot" true
    (List.mem ("delete --force " ^ guest) calls);
  Alcotest.(check bool) "the guest is booted" true (Option.is_some (calls_after_boot ~guest calls))
;;

let start_after_boot ~name ~after ~config ~set_mode ~after_boot =
  let meta = microvm_meta ~name ~backend:Backend.Apple_container in
  let guest = guest_name ~config ~meta in
  set_mode Guest_absent;
  after_boot (after guest);
  let runtime =
    Turn.create ~config ~meta ~image:(Ok "probe-fixture") ~network_mode:meta.network_mode ()
  in
  guest, Turn.microvm_remote_endpoint ~timeout_sec:5. runtime
;;

let removal_of ~guest line =
  String.equal line ("stop " ^ guest) || String.equal line ("delete --force " ^ guest)
;;

let booted_calls ~guest calls =
  match calls_after_boot ~guest calls with
  | Some after -> after
  | None -> Alcotest.fail "the start never ran the guest's boot"
;;

(* [run -d] exited 0 and the runtime then stalled. The guest may be up and
   may already mount its snapshot, so it is neither stopped nor deleted, the
   snapshot stays registered, and this start fails for the next one to
   probe again. *)
let test_a_stall_right_after_a_boot_keeps_the_guest () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot ~calls ~forget_calls:_ ->
  let guest, result =
    start_after_boot ~name:"probe-stall-after-boot" ~config ~set_mode ~after_boot
      ~after:(fun _ -> Apiserver_stalled)
  in
  (match result with
   | Ok _ -> Alcotest.fail "a guest nobody could ask about was handed out"
   | Error _ -> ());
  Alcotest.(check bool) "no stop or delete after the boot" false
    (List.exists (removal_of ~guest) (booted_calls ~guest (calls ())));
  Alcotest.(check bool) "the snapshot stays registered" true
    (Turn.For_testing_microvm.microvm_identity_snapshot_registered ~container_name:guest)
;;

(* Inspect failed after the boot, and the listing shows the guest: it is the
   guest this start booted, and the start goes on with it. *)
let test_a_listed_guest_after_a_boot_is_booted () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot ~calls ~forget_calls:_ ->
  let guest, result =
    start_after_boot ~name:"probe-listed-after-boot" ~config ~set_mode ~after_boot
      ~after:(fun guest ->
        Inspect_stalled_listing (listing_of_names Backend.Apple_container [ guest ]))
  in
  (match result with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "a listed guest must be used: %s" detail);
  Alcotest.(check bool) "no stop or delete after the boot" false
    (List.exists (removal_of ~guest) (booted_calls ~guest (calls ())))
;;

(* A listing without the guest after its boot: taken down, as a guest that
   came up unusable always was, and the snapshot it never mounted released. *)
let test_a_guest_missing_after_its_boot_is_taken_down () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot ~calls ~forget_calls:_ ->
  let guest, result =
    start_after_boot ~name:"probe-missing-after-boot" ~config ~set_mode ~after_boot
      ~after:(fun _ -> Guest_absent)
  in
  (match result with
   | Ok _ -> Alcotest.fail "a guest the runtime does not list was handed out"
   | Error _ -> ());
  Alcotest.(check bool) "the guest is stopped and deleted" true
    (List.exists (removal_of ~guest) (booted_calls ~guest (calls ())));
  Alcotest.(check bool) "the snapshot is released" false
    (Turn.For_testing_microvm.microvm_identity_snapshot_registered ~container_name:guest)
;;

(* Teardown releases a guest's records only when the guest is gone. A guest
   the runtime could not be asked about keeps them, and the teardown says it
   failed, so the next teardown tries again. *)
let test_a_teardown_during_a_stall_keeps_the_guest_records () =
  with_fake_cli Backend.Apple_container
  @@ fun ~config ~set_mode ~after_boot:_ ~calls:_ ~forget_calls:_ ->
  let meta = microvm_meta ~name:"probe-stalled-teardown" ~backend:Backend.Apple_container in
  let teardown () =
    Turn.teardown_keeper_sandbox_by_name
      ~timeout_sec:5.
      ~config
      ~keeper_name:meta.name
      ~backend:Masc.Keeper_sandbox.Micro_vm
      ~microvm_backend:Backend.Apple_container
      ()
  in
  Turn.For_testing_microvm.mark_microvm_guest_booted ~config ~meta ();
  set_mode Apiserver_stalled;
  (match teardown () with
   | Ok () -> Alcotest.fail "a teardown that could not see the guest reported it removed"
   | Error _ -> ());
  Alcotest.(check bool) "the guest's record is kept" true
    (Turn.is_microvm_guest_booted ~config ~meta ());
  set_mode Guest_absent;
  (match teardown () with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "a confirmed absence must tear down: %s" detail);
  Alcotest.(check bool) "the record goes with the guest" false
    (Turn.is_microvm_guest_booted ~config ~meta ())
;;

(* The absence reason replaces a caller's own error only with a fact. *)
let test_the_absence_reason_is_a_fact_on_every_backend () =
  List.iter
    (fun backend ->
       with_fake_cli backend
       @@ fun ~config ~set_mode ~after_boot:_ ~calls ~forget_calls ->
       let label what = Printf.sprintf "%s (%s)" what (Backend.to_string backend) in
       let meta =
         microvm_meta ~name:("probe-reason-" ^ Backend.to_string backend) ~backend
       in
       let reason () = Turn.microvm_guest_absence_reason ~timeout_sec:5. ~config ~meta () in
       set_mode Apiserver_stalled;
       Alcotest.(check bool) (label "a stall names no absence") true (Option.is_none (reason ()));
       set_mode Guest_absent;
       Alcotest.(check bool) (label "a confirmed absence is named") true
         (Option.is_some (reason ()));
       set_mode Guest_running;
       forget_calls ();
       Alcotest.(check bool) (label "a running guest is not absent") true
         (Option.is_none (reason ()));
       Alcotest.(check int) (label "an answering inspect is the only call") 1
         (List.length (calls ())))
    all_backends
;;

let () =
  Alcotest.run
    "keeper_microvm_guest_probe"
    [ ( "classifier"
      , [ Alcotest.test_case "an inspect that answers is the whole answer" `Quick
            test_an_inspect_that_answers_is_the_whole_answer
        ; Alcotest.test_case "a listing without the name is absent" `Quick
            test_a_listing_without_the_name_is_absent
        ; Alcotest.test_case "a listing that cannot be read is unknown" `Quick
            test_a_listing_that_cannot_be_read_is_unknown
        ; Alcotest.test_case "a listed guest takes the listed state" `Quick
            test_a_listed_guest_takes_the_listed_state
        ; Alcotest.test_case "the listing asked per backend" `Quick
            test_the_listing_asked_per_backend
        ] )
    ; ( "callers"
      , [ Alcotest.test_case "a start during a stall neither deletes nor boots" `Quick
            test_a_start_during_a_stall_neither_deletes_nor_boots
        ; Alcotest.test_case "a start with a confirmed absence boots" `Quick
            test_a_start_with_a_confirmed_absence_boots
        ; Alcotest.test_case "a stall right after a boot keeps the guest" `Quick
            test_a_stall_right_after_a_boot_keeps_the_guest
        ; Alcotest.test_case "a listed guest after a boot is booted" `Quick
            test_a_listed_guest_after_a_boot_is_booted
        ; Alcotest.test_case "a guest missing after its boot is taken down" `Quick
            test_a_guest_missing_after_its_boot_is_taken_down
        ; Alcotest.test_case "a teardown during a stall keeps the guest records" `Quick
            test_a_teardown_during_a_stall_keeps_the_guest_records
        ; Alcotest.test_case "the absence reason is a fact on every backend" `Quick
            test_the_absence_reason_is_a_fact_on_every_backend
        ] )
    ]
;;
