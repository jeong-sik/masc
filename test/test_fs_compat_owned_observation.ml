open Alcotest
module Fs = Fs_compat

let with_root f =
  let root = Filename.temp_dir "owned-observation-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs.remove_tree root) (fun () -> f root)
;;

let write path bytes =
  Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
;;

let present = function
  | Ok (Some snapshot) -> snapshot
  | Ok None -> fail "existing file was reported absent"
  | Error error -> fail (Fs.owned_regular_file_read_error_to_string error)
;;

let with_fs fs f =
  let previous = Fs.get_fs_opt () in
  let set = function None -> Fs.clear_fs () | Some fs -> Fs.set_fs fs in
  set fs;
  Fun.protect ~finally:(fun () -> set previous) f
;;

let test_snapshot_and_absence ~fs () =
  List.iter (fun filesystem -> with_fs filesystem (fun () -> with_root (fun root ->
    let path = Filename.concat root "record" in
    let observe path = Fs.observe_owned_regular_file ~owner_uid:(Unix.geteuid ())
        ~ownership_root:root path in
    List.iter (fun path -> match observe path with
      | Ok None -> ()
      | Ok (Some _) -> fail "missing path was present"
      | Error error -> fail (Fs.owned_regular_file_read_error_to_string error))
      [path; Filename.concat root "missing/record"];
    List.iter (fun (content, permissions) ->
      write path content;
      Unix.chmod path permissions;
      let metadata = observe path |> present in
      let full = Fs.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
          ~ownership_root:root path |> present in
      check bool "same descriptor snapshot as the full owned read" true
        (Fs.equal_owned_regular_file_snapshot metadata full.snapshot);
      check int "exact leaf permissions remain available to caller" permissions metadata.permissions;
      check int "empty and binary files retain their exact size" (String.length content) metadata.file_size;
      check string "observation leaves content unchanged" content full.content)
      ["", 0o600; "binary\000record\255", 0o644];
    check bool "observation creates no transaction lock" false
      (Sys.file_exists (Fs.private_jsonl_lock_path path))))) [None; Some fs]
;;

let test_parent_policy_at_each_boundary () =
  List.iter (fun (boundary, fault) -> with_root (fun root ->
    let parent = Filename.concat root "parent" in
    Unix.mkdir parent 0o700;
    let path = Filename.concat parent "record" in
    write path "retained";
    let uid = Unix.geteuid () in
    let foreign = if uid = 0 then 1 else 0 in
    List.iter (fun watched ->
      let visits = ref 0 in
      let parent_lstat directory =
        let stat = Unix.lstat directory in
        if String.equal directory watched then (
          incr visits;
          if !visits >= boundary then match fault with
            | `Owner -> {stat with Unix.st_uid = foreign}
            | `Permission -> {stat with Unix.st_perm = 0o777}
          else stat)
        else stat in
      let result = Fs.Owned_read_for_testing.observe ~parent_lstat ~owner_uid:uid
          ~ownership_root:root path in
      (match result, fault with
       | Error {failure = Fs.Owned_path_owner_mismatch {path; expected_uid; actual_uid}; _}, `Owner ->
         check string "changed owner path" watched path;
         check int "required UID" uid expected_uid;
         check int "observed foreign UID" foreign actual_uid
       | Error {failure = Fs.Owned_path_writable_by_others {path; permissions}; _}, `Permission ->
         check string "unsafe parent path" watched path;
         check int "unsafe mode retained in error" 0o777 permissions
       | Error error, (`Owner | `Permission) ->
         fail (Fs.owned_regular_file_read_error_to_string error)
       | Ok (None | Some _), (`Owner | `Permission) -> fail "unsafe parent was accepted");
      check int "policy checked at the injected boundary" boundary !visits)
      [root; parent]))
    [1, `Owner; 2, `Owner; 3, `Owner; 1, `Permission; 2, `Permission; 3, `Permission]
;;

let test_leaf_owner () = with_root (fun root ->
  let path = Filename.concat root "record" in
  write path "retained";
  let uid = Unix.geteuid () in
  let foreign = if uid = 0 then 1 else 0 in
  match Fs.Owned_read_for_testing.observe
    ~parent_lstat:(fun path -> {(Unix.lstat path) with Unix.st_uid = foreign})
    ~owner_uid:foreign ~ownership_root:root path with
  | Error {failure = Fs.Owned_path_owner_mismatch {path = rejected; expected_uid; actual_uid}; _} ->
    check string "descriptor, independently of parents" path rejected;
    check int "required foreign UID" foreign expected_uid;
    check int "actual descriptor UID" uid actual_uid
  | Error error -> fail (Fs.owned_regular_file_read_error_to_string error)
  | Ok (None | Some _) -> fail "foreign descriptor was accepted")
;;

let test_aliases_and_nonregular_files () = with_root (fun root ->
  let parent = Filename.concat root "parent" in
  Unix.mkdir parent 0o700;
  let path = Filename.concat parent "record" in
  write path "retained";
  let alias = Filename.concat root "alias" in
  let parent_alias = Filename.concat root "parent-alias" in
  let fifo = Filename.concat root "fifo" in
  Unix.symlink path alias;
  Unix.symlink parent parent_alias;
  Unix.mkfifo fifo 0o600;
  List.iter (fun path -> match Fs.observe_owned_regular_file ~owner_uid:(Unix.geteuid ())
      ~ownership_root:root path with
    | Error _ -> ()
    | Ok (None | Some _) -> fail "nonregular or aliased path was accepted")
    [alias; Filename.concat parent_alias "record"; fifo; parent];
  Unix.unlink path;
  match Fs.observe_owned_regular_file ~owner_uid:(Unix.geteuid ()) ~ownership_root:root alias with
  | Error {failure = Fs.Path_is_not_regular_file {kind = Unix.S_LNK; _}; _} -> ()
  | Error error -> fail (Fs.owned_regular_file_read_error_to_string error)
  | Ok (None | Some _) -> fail "dangling alias became initial absence")
;;

let test_replacement_and_lost_binding () =
  List.iter (fun (boundary, action) -> with_root (fun root ->
    let ancestor = Filename.concat root "ancestor" in
    let parent = Filename.concat ancestor "parent" in
    Unix.mkdir ancestor 0o700; Unix.mkdir parent 0o700;
    let path = Filename.concat parent "record" in
    write path "retained";
    let visits = ref 0 in
    let injected = ref false in
    let parent_lstat directory =
      if String.equal directory root then (
        incr visits;
        if !visits = boundary then (
          injected := true;
          match action with
          | `Unlink -> Unix.unlink path
          | `Replace -> Unix.rename path (path ^ ".held"); write path "replacement"
          | `Ancestor ->
            Unix.rename ancestor (ancestor ^ ".held");
            Unix.mkdir ancestor 0o700;
            Unix.rename (Filename.concat (ancestor ^ ".held") "parent") parent));
      Unix.lstat directory in
    let result = Fs.Owned_read_for_testing.observe ~parent_lstat
        ~owner_uid:(Unix.geteuid ()) ~ownership_root:root path in
    check bool "actual filesystem race was injected" true !injected;
    match result with
    | Error {failure = Fs.Filesystem_identity_changed _; _} -> ()
    | Error error -> fail (Fs.owned_regular_file_read_error_to_string error)
    | Ok None -> fail "lost observed binding became initial absence"
    | Ok (Some _) -> fail "replaced file or ancestor was accepted"))
    [2, `Unlink; 3, `Unlink; 2, `Replace; 3, `Replace; 2, `Ancestor; 3, `Ancestor]
;;

let () = Eio_main.run (fun env ->
  Alcotest.run "Owned file metadata observation"
    ["owned descriptor", [
      test_case "snapshot and absence in fallback and Eio" `Quick
        (test_snapshot_and_absence ~fs:(Eio.Stdenv.fs env));
      test_case "parent policy before/open/after observation" `Quick test_parent_policy_at_each_boundary;
      test_case "descriptor UID checked independently" `Quick test_leaf_owner;
      test_case "aliases and nonregular files remain refused" `Quick test_aliases_and_nonregular_files;
      test_case "lost and replaced bindings never become absence" `Quick test_replacement_and_lost_binding]])
