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

let count command f = read f.calls |> String.split_on_char '\n'
  |> List.filter (String.equal command) |> List.length

let test_fallback_and_other_backend_leave_the_default_unreadable () = with_fixture @@ fun f ->
  check bool "unsupported backend is explicit" true
    (M.read_work_volume_discard_default ~backend:Backend.Nerdctl_kata ~keeper_name:keeper ~timeout_sec:5.
     = M.Superblock_unreadable (M.Discard_backend_unsupported Backend.Nerdctl_kata));
  check string "unsupported backend executes no CLI" "" (read f.calls);
  Process_eio.reset_for_testing ();
  match M.read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name:keeper ~timeout_sec:5. with
  | M.Superblock_unreadable (M.Discard_inspect_unavailable _) -> ()
  | M.Discard_default_set | M.Discard_default_absent | M.Superblock_unreadable _ ->
    fail "fallback preview was treated as a superblock authority"

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
  let read_default () =
    M.read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name:keeper ~timeout_sec:5. in
  (match read_default () with
   | M.Superblock_unreadable (M.Discard_volume_mismatch _) -> ()
   | M.Discard_default_set | M.Discard_default_absent | M.Superblock_unreadable _ ->
     fail "another keeper's image was read as this volume's");
  write f.inspect (Printf.sprintf {|[{"configuration":{"name":%S,"format":"ext4","source":%S,"source":%S}}]|}
    volume f.image f.image);
  match read_default () with
  | M.Superblock_unreadable (M.Discard_inspect_invalid V.Duplicate_inspect_fields) -> ()
  | M.Discard_default_set | M.Discard_default_absent | M.Superblock_unreadable _ ->
    fail "ambiguous inspect source accepted"

let test_inspected_image_reads_absent_and_refuses_foreign_or_short () = with_fixture @@ fun f ->
  let read_default () =
    M.read_work_volume_discard_default ~backend:Backend.Apple_container ~keeper_name:keeper ~timeout_sec:5. in
  (match read_default () with
   | M.Discard_default_absent -> ()
   | M.Discard_default_set | M.Superblock_unreadable _ ->
     fail "an ext4 image without the discard bit was not read as absent");
  write f.image (image_bytes ~magic:0 0x0400);
  (match read_default () with
   | M.Superblock_unreadable (M.Discard_image_unreadable (V.Not_ext4 {magic=0})) -> ()
   | M.Discard_default_set | M.Discard_default_absent | M.Superblock_unreadable _ ->
     fail "a foreign image was read as a discard default");
  write f.image "short";
  match read_default () with
  | M.Superblock_unreadable (M.Discard_image_unreadable (V.Truncated _)) -> ()
  | M.Discard_default_set | M.Discard_default_absent | M.Superblock_unreadable _ ->
    fail "a short image was read as a discard default"

let actual_run ~timeout_sec argv = Process_eio.run_argv_with_status_split ~timeout_sec argv

let test_common_cleanup_uses_actual_complete_inventory () =
  let padding = String.make (Common.max_process_capture_head_bytes + Common.max_process_capture_tail_bytes) 'x' in
  (* Rows past the capture previews on both sides: the helper row sits where
     neither the head nor the tail preview reaches. *)
  let padded rows = Yojson.Safe.to_string (`List
    ([`Assoc ["id", `String "first"; "padding", `String padding]] @ rows
     @ [`Assoc ["id", `String "last"; "padding", `String padding]])) in
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
       {|[{"id":"a","id":"b"}]|}, false;
       padded [], true;
       padded [`Assoc ["id", `String (name ~keeper_name:keeper)]], false])
    [M.remove_apple_volume_repair, M.volume_repair_name]

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
    test_case "fallback and other runtime leave the discard default unreadable" `Quick test_fallback_and_other_backend_leave_the_default_unreadable;
    test_case "current volume binding uses complete CLI output" `Quick test_actual_inspect_binding_and_complete_capture;
    test_case "inspected image reads absent and refuses foreign or short bytes" `Quick test_inspected_image_reads_absent_and_refuses_foreign_or_short;
    test_case "repair helper cleanup uses actual strict inventory" `Quick test_common_cleanup_uses_actual_complete_inventory;
    test_case "actual repair lifecycle retains post-effect cleanup" `Quick test_repair_uses_common_complete_cleanup_and_retains_effect_result;
    test_case "all renames precede deletion and fresh build survives" `Quick test_pending_rename_precedes_deletion_and_preserves_new_build;
    test_case "root and pending links do not authorize cleanup" `Quick test_pending_and_root_symlinks_never_authorize_cleanup]]
