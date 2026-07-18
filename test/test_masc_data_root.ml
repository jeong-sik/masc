(** Unit tests for [Masc_data_root]
    (RFC-checkpoint-pinned-root-containment PR-1, #25151).

    The pin is the process-wide trust anchor for checkpoint path
    containment (armed in PR-2): resolved once at boot, physical,
    set-once. These tests pin the module contract — physical
    resolution through symlinks, idempotent same-root repin, refusal
    of a differing repin, typed failures for unresolvable and
    non-directory roots. *)

open Alcotest

let temp_dir prefix =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o755;
  root

let rec rm path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path

let with_fresh_pin f =
  Masc_data_root.clear_for_tests ();
  Fun.protect ~finally:Masc_data_root.clear_for_tests f

let test_pin_resolves_physical () =
  with_fresh_pin @@ fun () ->
  let dir = temp_dir "data_root_phys_" in
  Fun.protect ~finally:(fun () -> rm dir) @@ fun () ->
  match Masc_data_root.pin dir with
  | Error e -> fail (Masc_data_root.pin_error_to_string e)
  | Ok physical ->
    check string "pin returns the physical root" (Unix.realpath dir) physical;
    check (option string) "pinned () exposes the same root" (Some physical)
      (Masc_data_root.pinned ())

let test_pin_resolves_symlinked_root () =
  with_fresh_pin @@ fun () ->
  let dir = temp_dir "data_root_link_" in
  let target = Filename.concat dir "target" in
  let link = Filename.concat dir "link" in
  Fun.protect ~finally:(fun () -> rm dir) @@ fun () ->
  Unix.mkdir target 0o755;
  Unix.symlink target link;
  match Masc_data_root.pin link with
  | Error e -> fail (Masc_data_root.pin_error_to_string e)
  | Ok physical ->
    (* The deployment-symlink case from the RFC: the link is resolved once
       at boot and the physical tree becomes the invariant. *)
    check string "symlinked root pins its physical target"
      (Unix.realpath target) physical

let test_same_root_repin_is_idempotent () =
  with_fresh_pin @@ fun () ->
  let dir = temp_dir "data_root_idem_" in
  let link = Filename.concat (Filename.dirname dir) (Filename.basename dir ^ "-alias") in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      rm dir)
  @@ fun () ->
  Unix.symlink dir link;
  (match Masc_data_root.pin dir with
   | Error e -> fail (Masc_data_root.pin_error_to_string e)
   | Ok _ -> ());
  (* A second pin through a different spelling of the same physical root
     (here: via a symlink alias) is an idempotent Ok, not a refusal. *)
  match Masc_data_root.pin link with
  | Ok physical ->
    check string "alias repin resolves to the pinned physical root"
      (Unix.realpath dir) physical
  | Error e ->
    fail ("same-root repin refused: " ^ Masc_data_root.pin_error_to_string e)

let test_differing_repin_refused () =
  with_fresh_pin @@ fun () ->
  let first = temp_dir "data_root_first_" in
  let second = temp_dir "data_root_second_" in
  Fun.protect ~finally:(fun () -> rm first; rm second) @@ fun () ->
  (match Masc_data_root.pin first with
   | Error e -> fail (Masc_data_root.pin_error_to_string e)
   | Ok _ -> ());
  match Masc_data_root.pin second with
  | Ok _ -> fail "differing repin was accepted"
  | Error (Masc_data_root.Repin_differs { pinned; requested_physical; _ }) ->
    check string "refusal names the pinned root" (Unix.realpath first) pinned;
    check string "refusal names the requested root" (Unix.realpath second)
      requested_physical;
    check (option string) "pin is unchanged after refusal"
      (Some (Unix.realpath first)) (Masc_data_root.pinned ())
  | Error e ->
    fail ("differing repin failed with the wrong error: "
          ^ Masc_data_root.pin_error_to_string e)

let test_unresolvable_root_is_typed () =
  with_fresh_pin @@ fun () ->
  let missing = Filename.concat (temp_dir "data_root_gone_") "does-not-exist" in
  Fun.protect ~finally:(fun () -> rm (Filename.dirname missing)) @@ fun () ->
  match Masc_data_root.pin missing with
  | Ok _ -> fail "missing root pinned"
  | Error (Masc_data_root.Root_unresolvable { path; _ }) ->
    check string "error names the requested path" missing path;
    check (option string) "no pin is installed on failure" None
      (Masc_data_root.pinned ())
  | Error e ->
    fail ("missing root failed with the wrong error: "
          ^ Masc_data_root.pin_error_to_string e)

let test_file_root_is_typed () =
  with_fresh_pin @@ fun () ->
  let dir = temp_dir "data_root_file_" in
  let file = Filename.concat dir "regular" in
  Fun.protect ~finally:(fun () -> rm dir) @@ fun () ->
  let oc = open_out file in
  output_string oc "not a directory";
  close_out oc;
  match Masc_data_root.pin file with
  | Ok _ -> fail "regular file pinned as data root"
  | Error (Masc_data_root.Root_not_directory { physical }) ->
    check string "error names the physical file" (Unix.realpath file) physical
  | Error e ->
    fail ("file root failed with the wrong error: "
          ^ Masc_data_root.pin_error_to_string e)

let test_clear_resets_posture () =
  with_fresh_pin @@ fun () ->
  let dir = temp_dir "data_root_clear_" in
  Fun.protect ~finally:(fun () -> rm dir) @@ fun () ->
  (match Masc_data_root.pin dir with
   | Error e -> fail (Masc_data_root.pin_error_to_string e)
   | Ok _ -> ());
  Masc_data_root.clear_for_tests ();
  check (option string) "clear returns to the unpinned posture" None
    (Masc_data_root.pinned ())

let () =
  run "Masc_data_root"
    [
      ( "pin",
        [
          test_case "resolves to the physical root" `Quick
            test_pin_resolves_physical;
          test_case "resolves a symlinked deployment root" `Quick
            test_pin_resolves_symlinked_root;
          test_case "same-root repin is idempotent" `Quick
            test_same_root_repin_is_idempotent;
          test_case "differing repin is refused" `Quick
            test_differing_repin_refused;
          test_case "unresolvable root is a typed failure" `Quick
            test_unresolvable_root_is_typed;
          test_case "non-directory root is a typed failure" `Quick
            test_file_root_is_typed;
          test_case "clear_for_tests resets the posture" `Quick
            test_clear_resets_posture;
        ] );
    ]
