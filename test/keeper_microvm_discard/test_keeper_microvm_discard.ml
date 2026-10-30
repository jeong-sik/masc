open Alcotest
module M = Masc.Keeper_sandbox_microvm
module V = Masc.Keeper_volume_filesystem
module Backend = Masc.Keeper_microvm_backend

let keeper = "discard-fixture"
let volume = "masc-keeper-work-" ^ keeper
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let read path = In_channel.with_open_bin path In_channel.input_all

let image_bytes ?(magic = 0xEF53) options =
  let bytes = Bytes.make (V.superblock_offset + V.superblock_size) '\000' in
  Bytes.set_uint16_le bytes (V.superblock_offset + 0x38) magic;
  Bytes.set_int32_le bytes (V.superblock_offset + 0x100) (Int32.of_int options);
  Bytes.to_string bytes

let test_real_superblock_files () =
  let directory = Filename.temp_dir "masc-discard-superblock-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
    let image = Filename.concat directory "volume.img" in
    List.iter (fun (options, expected) ->
      write image (image_bytes options);
      check bool "actual regular image uses the discard bit" true
        (V.read_discard_default_image ~path:image = Ok expected))
      [0, V.Discard_default_absent; 0x0400, V.Discard_default_set;
       0x4401, V.Discard_default_set; 0x4001, V.Discard_default_absent];
    write image (image_bytes ~magic:0 0x0400);
    check bool "foreign magic refuses" true
      (V.read_discard_default_image ~path:image = Error (V.Not_ext4 {magic=0}));
    write image "short";
    check bool "short image is unreadable" true
      (V.read_discard_default_image ~path:image = Error (V.Truncated {bytes=0}));
    let fifo = Filename.concat directory "not-image" in
    Unix.mkfifo fifo 0o600;
    check bool "FIFO never waits for a writer" true
      (V.read_discard_default_image ~path:fifo = Error (V.Not_regular_file {kind=Unix.S_FIFO})))

let test_actual_tune_payload_uses_only_the_discovered_device () =
  let directory = Filename.temp_dir "masc-discard-payload-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
    let findmnt = Filename.concat directory "find mount" in
    let tune2fs = Filename.concat directory "tune filesystem" in
    let log = Filename.concat directory "calls" in
    let status = Filename.concat directory "find-status" in
    write status "0";
    write findmnt (Printf.sprintf "#!/bin/sh\nprintf 'find:%%s\\n' \"$@\" >> %s\nprintf '/dev/fixture-work\\n'\nexit \"$(/bin/cat %s)\"\n"
      (Filename.quote log) (Filename.quote status));
    write tune2fs (Printf.sprintf "#!/bin/sh\nprintf 'tune:%%s\\n' \"$@\" >> %s\n" (Filename.quote log));
    Unix.chmod findmnt 0o700; Unix.chmod tune2fs 0o700;
    let run () =
      let script = M.discard_configuration_script_with ~findmnt ~tune2fs ~guest_root:"/fixture mounted work" in
      let input = Unix.open_process_args_in "/bin/sh" [|"/bin/sh"; "-eu"; "-c"; script|] in
      ignore (In_channel.input_all input); Unix.close_process_in input in
    check bool "actual payload exits successfully" true (run () = Unix.WEXITED 0);
    check string "only discovered device reaches tuning"
      "find:--noheadings\nfind:--output\nfind:SOURCE\nfind:--target\nfind:/fixture mounted work\ntune:-o\ntune:discard\ntune:/dev/fixture-work\n"
      (read log);
    write log ""; write status "9";
    check bool "failed device discovery stops the payload" true (run () = Unix.WEXITED 9);
    check string "failed discovery never calls tuning"
      "find:--noheadings\nfind:--output\nfind:SOURCE\nfind:--target\nfind:/fixture mounted work\n" (read log))

type fixture =
  { image : string; inspect : string; calls : string; helper_status : string
  ; update : string; pre_listing : string; post_listing : string
  ; post_listing_status : string; block : string }

let with_fixture use =
  let directory = Filename.temp_dir "masc-discard-cli-" "" in
  let bin = Filename.concat directory "bin" in
  Unix.mkdir bin 0o700;
  let file name = Filename.concat directory name in
  let f = {image=file "volume.img"; inspect=file "inspect.json"; calls=file "calls";
           helper_status=file "helper-status"; update=file "update";
           pre_listing=file "pre-listing"; post_listing=file "post-listing";
           post_listing_status=file "post-listing-status"; block=file "block"} in
  write f.image (image_bytes 0);
  write f.inspect (Yojson.Safe.to_string (`List [`Assoc ["configuration", `Assoc
    ["name", `String volume; "format", `String "ext4"; "source", `String f.image]] ]));
  write f.calls ""; write f.helper_status "0"; write f.update "yes";
  write f.pre_listing "[]"; write f.post_listing "[]";
  write f.post_listing_status "0"; write f.block "no";
  let cli = Filename.concat bin "container" in
  let quote = Filename.quote in
  write cli (Printf.sprintf {|#!/bin/sh
printf '%%s:%%s\n' "$1" "${2-}" >> %s
case "$1:$2" in
  volume:inspect) /bin/cat %s ;;
  delete:--force) exit 0 ;;
  list:--all) if [ -e %s ]; then /bin/cat %s; exit "$(/bin/cat %s)"; else /bin/cat %s; fi ;;
  run:--rm)
    : > %s
    if [ "$(/bin/cat %s)" = yes ]; then
      printf '\000\004\000\000' | dd of=%s bs=1 seek=1280 conv=notrunc 2>/dev/null || exit 12
    fi
    printf 'actual helper stdout\n'
    if [ "$(/bin/cat %s)" = yes ]; then exec /bin/sleep 60; fi
    exit "$(/bin/cat %s)" ;;
  *) exit 71 ;;
esac
|} (quote f.calls) (quote f.inspect) (quote (file "helper-seen")) (quote f.post_listing)
      (quote f.post_listing_status) (quote f.pre_listing) (quote (file "helper-seen")) (quote f.update) (quote f.image) (quote f.block) (quote f.helper_status));
  Unix.chmod cli 0o700;
  let previous_path = Sys.getenv_opt "PATH" in
  Fun.protect ~finally:(fun () ->
    (match previous_path with Some path -> Unix.putenv "PATH" path | None -> Unix.unsetenv "PATH");
    Fs_compat.remove_tree directory)
    (fun () ->
      Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"/usr/bin:/bin" previous_path);
      Eio_main.run (fun env ->
        let previous_fs = Fs_compat.get_fs_opt () in
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Process_eio.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / directory)
          ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
        Fun.protect ~finally:(fun () ->
          Process_eio.reset_for_testing ();
          match previous_fs with None -> Fs_compat.clear_fs () | Some fs -> Fs_compat.set_fs fs)
          (fun () -> use f)))

let reclaim ?(on_cleanup_error = ignore) ?run _f =
  let run = match run with Some run -> run | None -> (fun ~timeout_sec argv -> Process_eio.run_argv_with_status_split ~timeout_sec argv) in
  M.reclaim_apple_work_volume ~run ~on_cleanup_error ~timeout_sec:5. ~remove_timeout_sec:5.
    ~keeper_name:keeper ~volume_name:volume ~image:"fixture-image"

let count command f = read f.calls |> String.split_on_char '\n'
  |> List.filter (String.equal command) |> List.length

let test_set_and_unreadable_start_no_helper () =
  List.iter (fun bytes -> with_fixture (fun f ->
    write f.image bytes;
    (match reclaim f with
     | Ok M.Discard_already_set when bytes = image_bytes 0x0400 -> ()
     | Ok (M.Discard_unreadable _) when bytes <> image_bytes 0x0400 -> ()
     | Ok _ | Error _ -> fail "wrong current superblock result");
    check int "no one-shot helper" 0 (count "run:--rm" f);
    check int "no helper cleanup" 0 (count "delete:--force" f);
    check int "one current source inspect" 1 (count "volume:inspect" f)))
    [image_bytes 0x0400; image_bytes ~magic:0 0; "short"]

let test_absent_runs_one_helper_and_reads_back () = with_fixture @@ fun f ->
  (match reclaim f with
   | Ok (M.Discard_helper_finished {status=Unix.WEXITED 0; after=M.Discard_default_set; _}) -> ()
   | Ok _ | Error _ -> fail "actual helper and new superblock were not observed");
  check int "one helper only" 1 (count "run:--rm" f);
  check int "both cleanup calls" 2 (count "delete:--force" f);
  check int "both complete cleanup inventories" 2 (count "list:--all" f);
  check int "readback re-inspects actual source" 2 (count "volume:inspect" f)

let test_helper_failure_and_zero_without_effect_never_guess_set () =
  List.iter (fun status -> with_fixture (fun f ->
    write f.update "no"; write f.helper_status (string_of_int status);
    match reclaim f with
    | Ok (M.Discard_helper_finished {status=actual; after=M.Discard_default_absent; _}) ->
      check bool "actual helper exit retained" true (actual = Unix.WEXITED status);
      check int "failed or ineffective helper is not retried" 1 (count "run:--rm" f)
    | Ok _ | Error _ -> fail "helper result replaced by inferred set")) [0; 7]

let test_failed_helper_retains_failure_even_when_readback_is_set () = with_fixture @@ fun f ->
  write f.helper_status "7";
  match reclaim f with
  | Ok (M.Discard_helper_finished {status=Unix.WEXITED 7; after=M.Discard_default_set; _}) -> ()
  | Ok _ | Error _ -> fail "fresh set observation erased the actual failed helper status"

let test_failed_cleanup_refuses_guest_mount () = with_fixture @@ fun f ->
  write f.post_listing "[{}]";
  let reports = ref [] in
  (match reclaim ~on_cleanup_error:(fun detail -> reports := detail :: !reports) f with
   | Error _ -> () | Ok _ -> fail "unknown cleanup inventory accepted");
  check bool "cleanup failure surfaced" true (!reports <> []);
  check int "no replay" 1 (count "run:--rm" f);
  check int "no mounted-image readback before proven cleanup" 1 (count "volume:inspect" f)

let test_complete_cleanup_inventory_cannot_hide_the_helper () = with_fixture @@ fun f ->
  let padding = String.make (Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes) 'x' in
  let name = M.work_volume_trim_name ~keeper_name:keeper in
  write f.post_listing (Yojson.Safe.to_string (`List
    [`Assoc ["id", `String "first"; "padding", `String padding];
     `Assoc ["id", `String name];
     `Assoc ["id", `String "last"; "padding", `String padding]]));
  match reclaim f with
  | Error _ -> check int "hidden existing helper was not followed by image readback" 1 (count "volume:inspect" f)
  | Ok _ -> fail "bounded listing preview hid a still-present helper"

let test_fallback_and_other_backend_never_authorize_helper () = with_fixture @@ fun f ->
  check bool "unsupported backend is explicit" true
    (M.read_work_volume_discard_default ~backend:Backend.Nerdctl_kata ~keeper_name:keeper ~timeout_sec:5.
     = M.Superblock_unreadable (M.Discard_backend_unsupported Backend.Nerdctl_kata));
  check string "unsupported backend executes no CLI" "" (read f.calls);
  Process_eio.reset_for_testing ();
  (match reclaim f with
   | Ok (M.Discard_unreadable (M.Discard_inspect_unavailable _)) -> ()
   | Ok _ | Error _ -> fail "fallback preview was treated as a superblock authority");
  check int "fallback starts no helper" 0 (count "run:--rm" f)

let test_actual_inspect_binding_and_complete_capture () = with_fixture @@ fun f ->
  let padding = String.make (Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes) 'x' in
  write f.image (image_bytes 0x0400);
  write f.inspect (Yojson.Safe.to_string (`List [`Assoc ["padding", `String padding;
    "configuration", `Assoc ["name", `String volume; "format", `String "ext4"; "source", `String f.image];
    "tail", `String padding]]));
  check bool "source hidden beyond previews is read" true
    (M.read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name:keeper ~timeout_sec:5.
     = M.Discard_default_set);
  write f.inspect (Yojson.Safe.to_string (`List [`Assoc ["configuration", `Assoc
    ["name", `String "another-volume"; "format", `String "ext4"; "source", `String f.image]] ]));
  (match reclaim f with
   | Ok (M.Discard_unreadable (M.Discard_volume_mismatch _)) -> ()
   | Ok _ | Error _ -> fail "another keeper's image authorized a helper");
  check int "foreign source starts no helper" 0 (count "run:--rm" f);
  write f.inspect (Printf.sprintf {|[{"configuration":{"name":%S,"format":"ext4","source":%S,"source":%S}}]|}
    volume f.image f.image);
  (match reclaim f with
   | Ok (M.Discard_unreadable (M.Discard_inspect_invalid V.Duplicate_inspect_fields)) -> ()
   | Ok _ | Error _ -> fail "ambiguous inspect source accepted")

let actual_run ~timeout_sec argv = Process_eio.run_argv_with_status_split ~timeout_sec argv

let test_common_cleanup_uses_actual_complete_inventory () =
  List.iter (fun (remove, name) ->
    List.iter (fun (listing, absent) -> with_fixture (fun f ->
      write f.pre_listing listing;
      let run ~timeout_sec argv =
        check (float 0.) "delete retains removal budget" 7. timeout_sec;
        check (list string) "runner only deletes; it cannot supply inventory"
          (M.delete_force_argv_for Backend.Apple_container ~container_name:(name ~keeper_name:keeper)) argv;
        (* Deliberately return a fake absent preview. Actual inventory wins. *)
        Unix.WEXITED 1, "[]", "already absent or failed" in
      let result = remove ~run ~timeout_sec:5. ~remove_timeout_sec:7. ~keeper_name:keeper in
      (match result, absent with
       | Ok (), true | Error _, false -> ()
       | Ok (), false -> fail "unproven actual absence accepted"
       | Error detail, true -> fail detail);
      check int "one actual canonical inventory" 1 (count "list:--all" f)))
      ["[]", true; "[{}]", false; "[1]", false; "{}", false; "not JSON", false;
       {|[{"id":""}]|}, false; {|[{"configuration":{"id":"   "}}}]|}, false;
       Yojson.Safe.to_string (`List [`Assoc ["configuration", `Assoc ["id", `String (name ~keeper_name:keeper)]]]), false;
       {|[{"id":"a","configuration":{"id":"b"}}]|}, false;
       {|[{"id":"a","id":"b"}]|}, false])
    [M.remove_apple_work_volume_trim, M.work_volume_trim_name;
     M.remove_apple_volume_repair, M.volume_repair_name]

let test_repair_uses_common_complete_cleanup_and_retains_effect_result () =
  List.iter (fun after -> with_fixture (fun f ->
    write f.post_listing (if after = `Invalid then "[{}]" else "[]");
    if after = `Nonzero then write f.post_listing_status "7";
    let events = ref [] in
    let run_helper argv =
      check (list string) "actual repair command" (M.apple_volume_repair_argv
        ~keeper_name:keeper ~volume_name:volume ~image:"fixture-image") argv;
      events := "helper" :: !events;
      actual_run ~timeout_sec:5. argv in
    let result = M.repair_apple_volume ~run:actual_run ~run_helper
      ~on_start:(fun () -> events := "started" :: !events) ~on_cleanup_error:ignore
      ~timeout_sec:5. ~remove_timeout_sec:5. ~keeper_name:keeper ~volume_name:volume ~image:"fixture-image" in
    (match result with
     | Ok {M.status=Unix.WEXITED 0; stdout="actual helper stdout\n"; cleanup; _} ->
       check bool "actual post-effect cleanup is retained beside result" (after = `Absent) (cleanup = Ok ())
     | Ok _ | Error _ -> fail "actual repair result was lost");
    check (list string) "announce only after proven initial absence" ["started"; "helper"] (List.rev !events);
    check int "one repair helper" 1 (count "run:--rm" f);
    check int "both protected cleanup observations" 2 (count "list:--all" f)))
    [`Absent; `Invalid; `Nonzero];
  with_fixture (fun f ->
    write f.pre_listing "[{}]";
    let started = ref false in
    let result = M.repair_apple_volume ~run:actual_run
      ~run_helper:(fun _ -> fail "unknown initial absence allowed helper")
      ~on_start:(fun () -> started := true) ~on_cleanup_error:ignore
      ~timeout_sec:5. ~remove_timeout_sec:5. ~keeper_name:keeper ~volume_name:volume ~image:"fixture-image" in
    (match result with Error _ -> () | Ok _ -> fail "unknown initial absence accepted");
    check bool "unknown inventory never announces repair" false !started;
    check int "no helper effect" 0 (count "run:--rm" f))

let test_cancellation_still_confirms_helper_cleanup () =
  List.iter (fun cleanup_fails -> with_fixture (fun f ->
    write f.block "yes";
    if cleanup_fails then write f.post_listing "[{}]";
    let reported = ref [] in
    let cancelled = try
      Eio.Cancel.sub (fun context ->
        let helper = M.apple_work_volume_trim_argv ~keeper_name:keeper ~volume_name:volume ~image:"fixture-image" in
        let run ~timeout_sec argv =
          Process_eio.run_argv_with_status_split_streaming ~timeout_sec
            ~on_stdout_chunk:(fun _ -> if argv = helper then Eio.Cancel.cancel context Exit)
            ~on_stderr_chunk:ignore argv in
        ignore (reclaim ~run ~on_cleanup_error:(fun detail -> reported := detail :: !reported) f));
      false
    with Eio.Cancel.Cancelled _ -> true in
    check bool "original cancellation propagated" true cancelled;
    check bool "failed cleanup is reported without replacing cancellation" cleanup_fails (!reported <> []);
    check int "actual helper was entered once" 1 (count "run:--rm" f);
    check int "protected post-cancel deletion ran" 2 (count "delete:--force" f);
    check int "protected post-cancel absence read ran" 2 (count "list:--all" f))) [false; true]

let test_pending_rename_precedes_deletion_and_preserves_new_build () =
  let root = Filename.temp_dir "masc-first-handoff-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let keeper_root = Filename.concat root "keeper" in
    Unix.mkdir keeper_root 0o700;
    let mkdir path = Unix.mkdir path 0o700 in
    List.iter (fun parent ->
      let parent = Filename.concat keeper_root parent in mkdir parent;
      let checkout = Filename.concat parent "repo" in mkdir checkout;
      write (Filename.concat checkout M.build_root_marker) "fixture";
      mkdir (Filename.concat checkout "_build");
      write (Filename.concat checkout "_build/old") "old build") ["a"; "b"];
    let pending = Filename.concat keeper_root ".masc-build-removing" in mkdir pending;
    mkdir (Filename.concat pending "interrupted"); write (Filename.concat pending "interrupted/old") "prior";
    let bin = Filename.concat root "bin" in mkdir bin;
    let marker = Filename.concat root "phase-observed" in
    let rm = Filename.concat bin "rm" in
    write rm (Printf.sprintf {|#!/bin/sh
[ ! -e ./a/repo/_build ] && [ ! -e ./b/repo/_build ] || exit 81
set -- "$@"
count=$(find ./.masc-build-removing -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$count" -eq 3 ] || exit 82
mkdir ./a/repo/_build || exit 83
printf 'new build' > ./a/repo/_build/new
printf 'observed' > %s
exec /bin/rm "$@"
|} (Filename.quote marker)); Unix.chmod rm 0o700;
    let script = "PATH=" ^ Filename.quote (bin ^ ":" ^ Option.value ~default:"/usr/bin:/bin" (Sys.getenv_opt "PATH"))
      ^ "; export PATH\n" ^ M.first_handoff_build_cleanup_script ~keeper_work_root:keeper_root in
    let input = Unix.open_process_args_in "/bin/sh" [|"/bin/sh"; "-eu"; "-c"; script|] in
    ignore (In_channel.input_all input);
    check bool "rename/delete payload completed" true (Unix.close_process_in input = Unix.WEXITED 0);
    check bool "both renames and interrupted tree preceded deletion" true (Sys.file_exists marker);
    check string "post-rename build survives pending deletion" "new build" (read (Filename.concat keeper_root "a/repo/_build/new"));
    check bool "pending directory removed" false (Sys.file_exists pending))

let run_cleanup root =
  let input = Unix.open_process_args_in "/bin/sh"
      [|"/bin/sh"; "-eu"; "-c"; M.first_handoff_build_cleanup_script ~keeper_work_root:root|] in
  ignore (In_channel.input_all input);
  Unix.close_process_in input

let test_pending_and_root_symlinks_never_authorize_cleanup () =
  let root = Filename.temp_dir "masc-handoff-links-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let outside = Filename.concat root "outside" in Unix.mkdir outside 0o700;
    write (Filename.concat outside "preserved") "outside bytes";
    let linked_root = Filename.concat root "linked-root" in Unix.symlink outside linked_root;
    check bool "linked root refuses" true (run_cleanup linked_root <> Unix.WEXITED 0);
    let keeper_root = Filename.concat root "keeper" in Unix.mkdir keeper_root 0o700;
    Unix.symlink outside (Filename.concat keeper_root ".masc-build-removing");
    check bool "linked pending directory refuses" true (run_cleanup keeper_root <> Unix.WEXITED 0);
    check string "outside link target is untouched" "outside bytes" (read (Filename.concat outside "preserved"));
    check bool "outside directory remains" true (Sys.is_directory outside))

let () = run "microvm discard and first handoff"
  ["actual boundary", [
    test_case "regular superblock file decodes authoritative flag" `Quick test_real_superblock_files;
    test_case "actual helper payload tunes only its discovered device" `Quick test_actual_tune_payload_uses_only_the_discovered_device;
    test_case "set or unreadable creates no helper or cleanup" `Quick test_set_and_unreadable_start_no_helper;
    test_case "absent runs one actual helper and reads back" `Quick test_absent_runs_one_helper_and_reads_back;
    test_case "failed and ineffective helper never guess set" `Quick test_helper_failure_and_zero_without_effect_never_guess_set;
    test_case "failed helper status survives fresh set readback" `Quick test_failed_helper_retains_failure_even_when_readback_is_set;
    test_case "unknown post-helper absence refuses mount" `Quick test_failed_cleanup_refuses_guest_mount;
    test_case "complete cleanup inventory retains hidden helper" `Quick test_complete_cleanup_inventory_cannot_hide_the_helper;
    test_case "fallback and other runtime cannot authorize helper" `Quick test_fallback_and_other_backend_never_authorize_helper;
    test_case "current volume binding uses complete CLI output" `Quick test_actual_inspect_binding_and_complete_capture;
    test_case "common trim and repair cleanup uses actual strict inventory" `Quick test_common_cleanup_uses_actual_complete_inventory;
    test_case "actual repair lifecycle retains post-effect cleanup" `Quick test_repair_uses_common_complete_cleanup_and_retains_effect_result;
    test_case "actual helper cancellation retains protected cleanup" `Quick test_cancellation_still_confirms_helper_cleanup;
    test_case "all renames precede deletion and fresh build survives" `Quick test_pending_rename_precedes_deletion_and_preserves_new_build;
    test_case "root and pending links do not authorize cleanup" `Quick test_pending_and_root_symlinks_never_authorize_cleanup]]
