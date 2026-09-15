open Alcotest
module Package = Builtin_skill_package

let get = function Ok value -> value | Error error -> fail (Package.error_message error)
let package files = match Package.make ~name:"browser-fixture" ~files with
  | Ok value -> value | Error reason -> fail reason
let first = package [ "SKILL.md", "old instruction"; "references/old.md", "old resource" ]
let second = package [ "SKILL.md", "short instruction"; "references/lazy.md", "new resource" ]
let root base = Filename.concat base ".masc/skills/browser-fixture"
let file base rel = Filename.concat (root base) rel
let receipt base = Filename.concat base ".masc/skill-packages/browser-fixture.sha256"
let read path = Fs_compat.load_file path
let reconcile_all base values = get (Package.reconcile ~base_path:base values)
let reconcile base value = match reconcile_all base [ value ] with
  | [ Package.Bundled { result = Ok verdict; _ } ] -> verdict
  | [ Package.Bundled { result = Error error; _ } ] -> fail (Package.error_message error)
  | reports -> fail (String.concat "; " (List.map Package.report_to_string reports))
let inspect base value = get (Package.inspect ~base_path:base value)
let revision = function Package.Present { revision; _ } -> revision | Package.Missing -> fail "missing package"
let replace base reviewed value = match reviewed with
  | Package.Present { revision; bundled_revision; _ } ->
    Package.replace_reviewed ~base_path:base ~installed_revision:revision ~bundled_revision value
  | Package.Missing -> fail "cannot review a missing installation"
let installed base value = match reconcile base value with
  | Package.Install_missing -> ()
  | _ -> fail "expected a fresh installation"
let with_base test =
  let base = Filename.temp_dir "masc-skill-package-test-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () -> test base)

let assert_second base =
  check string "new instruction" "short instruction" (read (file base "SKILL.md"));
  check string "lazy resource published with instruction" "new resource" (read (file base "references/lazy.md"));
  check bool "retired distribution resource removed" false (Sys.file_exists (file base "references/old.md"))

let test_update_complete_package () = with_base (fun base ->
  installed base first;
  let backup = match reconcile base second with
    | Package.Replace_recorded { backup } -> backup | _ -> fail "expected updated package" in
  assert_second base;
  check string "old body retained" "old instruction" (read (Filename.concat backup "SKILL.md"));
  check string "old resource retained" "old resource" (read (Filename.concat backup "references/old.md"));
  (match inspect base second with
   | Package.Present { revision; bundled_revision; ownership = Package.Recorded } ->
     check string "receipt describes complete new tree" bundled_revision revision
   | _ -> fail "new package must be recorded");
  match reconcile base second with Package.Up_to_date -> () | _ -> fail "same release must be a no-op")

let test_preserve_operator_changes () =
  let edits =
    [ "body", (fun base -> Fs_compat.save_file (file base "SKILL.md") "operator instructions")
    ; "resource deletion", (fun base -> Unix.unlink (file base "references/old.md"))
    ; "resource addition", (fun base -> Fs_compat.save_file (file base "operator.txt") "my resource")
    ; "empty directory", (fun base -> Unix.mkdir (file base "operator") 0o700)
    ; "permissions", (fun base -> Unix.chmod (file base "SKILL.md") 0o600)
    ] in
  List.iter (fun (label, edit) -> with_base (fun base ->
    installed base first;
    edit base;
    let before = revision (inspect base second) in
    (match reconcile base second with
     | Package.Keep_modified { revision } -> check string (label ^ " revision reported") before revision
     | _ -> fail (label ^ " must be preserved"));
    check string label before (revision (inspect base second));
    check bool "new resource was not backfilled" false (Sys.file_exists (file base "references/lazy.md")))) edits

let test_created_directory_parent_sync () = with_base (fun base ->
  let directory = Filename.concat base "new-state" in
  let synced = ref [] in
  let sync_parent path =
    check bool "entry exists before parent sync" true (Sys.is_directory directory);
    synced := path :: !synced in
  get (Package.For_testing.ensure_directory ~sync_parent directory);
  check (list string) "new entry syncs containing directory" [base] !synced;
  get (Package.For_testing.ensure_directory ~sync_parent directory);
  check (list string) "existing entry also syncs containing directory" [base;base] !synced;
  let unsynced = Filename.concat base "unsynced-state" in
  (match Package.For_testing.ensure_directory
     ~sync_parent:(fun path -> raise (Unix.Unix_error (Unix.EIO,"fsync",path))) unsynced with
   | Error (Package.Io_error _) -> ()
   | _ -> fail "parent sync failure must not report success");
  check bool "failed sync leaves real created entry visible" true (Sys.is_directory unsynced);
  let retries = ref 0 in
  (match Package.For_testing.ensure_directory ~sync_parent:(fun path ->
       incr retries; raise (Unix.Unix_error (Unix.EIO,"fsync",path))) unsynced with
   | Error (Package.Io_error _) -> ()
   | _ -> fail "retry must not bypass parent sync for an existing entry");
  check int "failed retry attempted sync" 1 !retries;
  get (Package.For_testing.ensure_directory ~sync_parent:(fun path ->
    check string "retry syncs containing parent" base path; incr retries) unsynced);
  check int "successful retry confirms parent sync" 2 !retries)

let test_hard_link_preserved () = with_base (fun base ->
  installed base first;
  let reviewed = inspect base second in
  let original_receipt = read (receipt base) in
  let resource = file base "references/old.md" in
  let linked_target = Filename.concat base "operator-linked-resource" in
  Fs_compat.save_file linked_target (read resource);
  Unix.chmod linked_target (Unix.stat resource).st_perm;
  Unix.unlink resource;
  Unix.link linked_target resource;
  (match Package.inspect ~base_path:base second with
   | Error (Package.Invalid_path path) -> check string "linked resource rejected" resource path
   | _ -> fail "inspection must not assign a normal revision to linked resource");
  (match reconcile base second with
   | Package.Keep_uninspectable _ -> ()
   | _ -> fail "automatic refresh must preserve hard links");
  (match replace base reviewed second with
   | Error (Package.Invalid_path _) -> ()
   | _ -> fail "reviewed replacement must reject new linking semantics");
  check int "operator link retained" (Unix.stat linked_target).st_ino (Unix.stat resource).st_ino;
  check string "old instruction retained" "old instruction" (read (file base "SKILL.md"));
  check string "receipt unchanged" original_receipt (read (receipt base)))

let test_untracked_reviewed_update () = with_base (fun base ->
  installed base first;
  Unix.unlink (receipt base);
  let reviewed = inspect base second in
  (match reconcile base second with
   | Package.Keep_untracked_different { revision = kept } ->
     check string "kept revision is the installed tree" (revision reviewed) kept
   | _ -> fail "untracked installation must wait for review");
  check bool "no receipt is invented for a different tree" false (Sys.file_exists (receipt base));
  let exported = Filename.concat base "review-bundle" in
  get (Package.export ~destination:exported second);
  check string "release bytes available for diff" "short instruction" (read (Filename.concat exported "SKILL.md"));
  (match Package.export ~destination:exported first with
   | Error _ -> () | Ok () -> fail "export overwrote review directory");
  check string "reviewed bytes unchanged" "short instruction" (read (Filename.concat exported "SKILL.md"));
  let occupied = Filename.concat base "empty-operator-directory" in
  Unix.mkdir occupied 0o700;
  (match Package.export ~destination:occupied second with
   | Error _ -> () | Ok () -> fail "export overwrote an empty operator directory");
  check int "operator directory remains empty" 0 (Array.length (Sys.readdir occupied));
  (match replace base reviewed second with
   | Ok (Package.Replaced _) -> ()
   | Ok Package.Already_current -> fail "a different untracked tree is not current"
   | Error error -> fail (Package.error_message error));
  assert_second base)

let test_streamed_resource_revision () = with_base (fun base ->
  installed base first;
  let resource = file base "references/large.bin" in
  let chunk = Bytes.make 65536 '\000' in
  let chunks = 512 in
  let fd = Unix.openfile resource [Unix.O_CREAT;Unix.O_EXCL;Unix.O_WRONLY] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    ignore (Unix.lseek fd (Bytes.length chunk * chunks - 1) Unix.SEEK_SET);
    ignore (Unix.write fd chunk 0 1));
  let expected = ref Digestif.SHA256.empty in
  for _ = 1 to chunks do expected := Digestif.SHA256.feed_bytes !expected chunk done;
  let before = Gc.allocated_bytes () in
  let digest = Fs_compat.sha256_owned_regular_file ~ownership_root:base resource in
  let allocated = Gc.allocated_bytes () -. before in
  (match digest with
   | Ok (Some digest) -> check string "sparse resource streams exact SHA256"
       Digestif.SHA256.(to_hex (get !expected)) digest
   | _ -> fail "owned sparse resource digest unavailable");
  check bool "hashing does not allocate a file-sized string" true
    (allocated < float_of_int (Bytes.length chunk * chunks));
  (match inspect base first with
   | Package.Present {ownership=Package.Modified;_} -> ()
   | _ -> fail "large operator resource participates in revision");
  (match reconcile base second with
   | Package.Keep_modified _ -> ()
   | _ -> fail "large operator resource must prevent automatic replacement");
  check int "sparse operator resource survives" (Bytes.length chunk * chunks) (Unix.stat resource).Unix.st_size)

let test_export_parent_sync_failure_retains_published_package () = with_base (fun base ->
  let destination = Filename.concat (Unix.realpath base) "exported-despite-sync-error" in
  let sync_parent path = raise (Unix.Unix_error (Unix.EIO, "fsync", path)) in
  (match Package.For_testing.export ~sync_parent ~destination second with
   | Error (Package.Exported_but_unsynced {destination=actual;_}) ->
     check string "post-publication error identifies the exported directory" destination actual
   | Error error -> fail ("wrong export failure phase: " ^ Package.error_message error)
   | Ok () -> fail "injected parent sync failure must be reported");
  check string "published instruction remains available" "short instruction"
    (read (Filename.concat destination "SKILL.md"));
  check string "published reference remains available" "new resource"
    (read (Filename.concat destination "references/lazy.md"));
  check (list string) "complete package root survives cleanup" ["SKILL.md";"references"]
    (Sys.readdir destination |> Array.to_list |> List.sort String.compare))

let test_stale_resource_revision () = with_base (fun base ->
  installed base first;
  let reviewed = inspect base second in
  Fs_compat.save_file (file base "references/old.md") "edited after preview";
  (match replace base reviewed second with
   | Error (Package.Revision_conflict _) -> ()
   | _ -> fail "body-only revision must not authorize resource overwrite");
  check string "resource edit survives rejection" "edited after preview" (read (file base "references/old.md")))

let test_bundle_changed_after_review () = with_base (fun base ->
  installed base first;
  let reviewed = inspect base second in
  let original = revision reviewed in
  let third = package [ "SKILL.md", "unreviewed third instruction"; "third.md", "new bytes" ] in
  let third_revision = match inspect base third with
    | Package.Present {bundled_revision;_} -> bundled_revision
    | Package.Missing -> fail "installed package missing" in
  (match replace base reviewed third with
   | Error (Package.Bundled_revision_conflict {actual_revision}) ->
     check string "conflict identifies the unreviewed distribution" third_revision actual_revision
   | _ -> fail "same installed revision must not authorize a different bundled package");
  check string "active tree unchanged after distribution mismatch" original (revision (inspect base first));
  check string "active instruction retained" "old instruction" (read (file base "SKILL.md"));
  check bool "unreviewed resource never published" false (Sys.file_exists (file base "third.md")))

let test_unreadable_operator_directory () = with_base (fun base ->
  installed base first;
  let directory = file base "references" in
  let previous_mode = (Unix.stat directory).Unix.st_perm in
  let original_receipt = read (receipt base) in
  Fun.protect ~finally:(fun () -> Unix.chmod directory previous_mode) (fun () ->
    Unix.chmod directory 0;
    (* Root and some privileged environments can still inspect chmod(000).
       Check the actual capability rather than claiming an EACCES test ran. *)
    let unreadable =
      try ignore (Sys.readdir directory); false with
      | Sys_error _ -> true
      | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) -> true in
    let outcome = reconcile base second in
    (match unreadable, outcome with
     | true, Package.Keep_uninspectable {reason} ->
       check bool "preservation exposes the inspection failure" true (reason <> "")
     | false, Package.Keep_modified _ ->
       Printf.printf "permission denial unavailable; verified privileged chmod-edit preservation instead\n%!"
     | _ -> fail "uninspectable or chmod-edited operator directory must be preserved");
    check string "instruction remains active" "old instruction" (read (file base "SKILL.md"));
    check string "receipt was not advanced" original_receipt (read (receipt base)));
  check string "old resource remains after restoring access" "old resource" (read (file base "references/old.md"));
  check bool "new distribution resource absent" false (Sys.file_exists (file base "references/lazy.md")))

let test_symlink_is_not_a_package () = with_base (fun base ->
  installed base first;
  let outside = Filename.concat base "outside.txt" in
  Fs_compat.save_file outside "outside bytes";
  Unix.unlink (file base "references/old.md");
  Unix.symlink outside (file base "references/old.md");
  (match reconcile base second with
   | Package.Keep_uninspectable _ -> () | _ -> fail "symlink must not be followed");
  check string "outside file untouched" "outside bytes" (read outside);
  check string "instruction untouched" "old instruction" (read (file base "SKILL.md")))

let test_adopt_identical_untracked () = with_base (fun base ->
  installed base second;
  Unix.unlink (receipt base);
  let before = revision (inspect base second) in
  (match reconcile base second with
   | Package.Adopt_identical -> ()
   | _ -> fail "an untracked tree equal to the release must be recorded");
  check string "receipt records the unchanged tree" (before ^ "\n") (read (receipt base));
  assert_second base;
  (match reconcile base first with
   | Package.Replace_recorded _ -> ()
   | _ -> fail "an adopted package must follow the next release"))

let test_adopt_identical_over_stale_receipt () = with_base (fun base ->
  installed base second;
  Fs_compat.save_file (receipt base) (Package.bundled_revision first ^ "\n");
  (match inspect base second with
   | Package.Present { ownership = Package.Modified; _ } -> ()
   | _ -> fail "a receipt describing another tree must read as modified");
  (match reconcile base second with
   | Package.Adopt_identical -> ()
   | _ -> fail "a stale receipt over the release's exact tree must be rewritten");
  match inspect base second with
  | Package.Present { ownership = Package.Recorded; _ } -> ()
  | _ -> fail "the rewritten receipt must match the tree")

let other = match Package.make ~name:"other-fixture" ~files:[ "SKILL.md", "other instruction" ] with
  | Ok value -> value | Error reason -> fail reason

(* The fixture is no longer shipped when the reconciled set holds only [other]. *)
let retired_reports base = reconcile_all base [ other ]
  |> List.filter_map (function
    | Package.Retired { name; result } -> Some (name, result)
    | Package.Bundled _ -> None)

let test_retire_recorded () = with_base (fun base ->
  installed base first;
  let backup = match retired_reports base with
    | [ "browser-fixture", Ok (Package.Retire_recorded { backup = Some backup }) ] -> backup
    | _ -> fail "a recorded package the release no longer ships must be retired" in
  check bool "retired package left the Skill source" false (Sys.file_exists (root base));
  check bool "retired receipt removed" false (Sys.file_exists (receipt base));
  check string "complete retired package kept" "old instruction" (read (Filename.concat backup "SKILL.md"));
  check string "retired resource kept" "old resource" (read (Filename.concat backup "references/old.md"));
  check bool "backup sits with the receipts, outside the Skill source" true
    (String.starts_with ~prefix:(Unix.realpath (Filename.dirname (receipt base)) ^ "/") backup);
  check int "a second reconcile has nothing left to retire" 0 (List.length (retired_reports base)))

let test_retire_receipt_without_tree () = with_base (fun base ->
  installed base first;
  Fs_compat.remove_tree (root base);
  (match retired_reports base with
   | [ "browser-fixture", Ok (Package.Retire_recorded { backup = None }) ] -> ()
   | _ -> fail "a receipt whose tree is gone must be removed");
  check bool "receipt removed" false (Sys.file_exists (receipt base)))

let test_retire_keeps_modified () = with_base (fun base ->
  installed base first;
  Fs_compat.save_file (file base "SKILL.md") "operator kept this";
  let before = revision (inspect base first) in
  (match retired_reports base with
   | [ "browser-fixture", Ok (Package.Keep_retired_modified { revision }) ] ->
     check string "kept revision reported" before revision
   | _ -> fail "an edited package must survive retirement");
  check string "edited instruction stays active" "operator kept this" (read (file base "SKILL.md"));
  check bool "receipt kept for the operator's decision" true (Sys.file_exists (receipt base)))

let test_retire_never_touches_untracked () = with_base (fun base ->
  installed base first;
  Unix.unlink (receipt base);
  let operator = Filename.concat base ".masc/skills/operator-skill" in
  Fs_compat.mkdir_p operator;
  Fs_compat.save_file (Filename.concat operator "SKILL.md") "operator skill";
  check int "untracked packages have no retirement report" 0 (List.length (retired_reports base));
  check string "former builtin without receipt stays" "old instruction" (read (file base "SKILL.md"));
  check string "operator skill stays" "operator skill" (read (Filename.concat operator "SKILL.md")))

let test_symlinked_deployment_root () = with_base (fun base ->
  let mounted = Filename.concat base "mounted-volume" in
  Unix.mkdir mounted 0o700;
  Unix.symlink mounted (Filename.concat base ".masc");
  installed base first;
  let backup = match reconcile base second with
    | Package.Replace_recorded {backup} -> backup | _ -> fail "mounted deployment must update" in
  assert_second base;
  let physical = Unix.realpath mounted in
  check bool "backup pinned beneath physical deployment root" true
    (String.starts_with ~prefix:(physical ^ "/skill-packages/") backup);
  check string "mounted receipt records current tree" (revision (inspect base second) ^ "\n")
    (read (Filename.concat physical "skill-packages/browser-fixture.sha256"));
  Fs_compat.save_file (file base "SKILL.md") "operator edit";
  (match replace base (inspect base first) first with
   | Ok (Package.Replaced _) -> ()
   | Ok Package.Already_current | Error _ -> fail "reviewed replacement through deployment link must publish");
  check string "reviewed replacement through deployment link succeeds" "old instruction" (read (file base "SKILL.md"));
  let outside = Filename.concat base "outside-resource" in
  Fs_compat.save_file outside "outside";
  Unix.unlink (file base "references/old.md");
  Unix.symlink outside (file base "references/old.md");
  (match reconcile base second with
   | Package.Keep_uninspectable _ -> ()
   | _ -> fail "deployment link support must not permit resource links");
  check string "outside resource remains untouched" "outside" (read outside))

let test_invalid_deployment_roots () =
  List.iter (fun kind -> with_base (fun base ->
    let deployment = Filename.concat base ".masc" in
    (match kind with
     | "dangling" -> Unix.symlink (Filename.concat base "missing-volume") deployment
     | "file-link" ->
       let file = Filename.concat base "not-directory" in
       Fs_compat.save_file file "operator file"; Unix.symlink file deployment
     | _ -> Fs_compat.save_file deployment "operator file");
    List.iter (fun result -> match result with
      | Error (Package.Invalid_path _) -> ()
      | _ -> fail (kind ^ " deployment root must reject explicitly"))
      [Package.inspect ~base_path:base second |> Result.map (fun _ -> ());
       Package.reconcile ~base_path:base [ second ] |> Result.map (fun _ -> ())]))
    ["dangling";"file-link";"file"]

let test_missing_package_with_occupied_receipt () =
  let large_receipt_bytes = 32 * 1024 * 1024 in
  List.iter (fun kind -> with_base (fun base ->
    let state = Filename.dirname (receipt base) in
    Fs_compat.mkdir_p state;
    let outside = Filename.concat base "operator-receipt" in
    Fs_compat.save_file outside "operator bytes";
    if kind = "directory" then begin
      Unix.mkdir (receipt base) 0o700;
      Fs_compat.save_file (Filename.concat (receipt base) "keep") "operator bytes"
    end else if kind = "large-file" then begin
      let fd = Unix.openfile (receipt base) [Unix.O_CREAT;Unix.O_EXCL;Unix.O_WRONLY] 0o600 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.ftruncate fd large_receipt_bytes)
    end else Unix.symlink outside (receipt base);
    let allocated_before = Gc.allocated_bytes () in
    (match reconcile base second with
     | Package.Keep_uninspectable {reason} ->
       check bool "invalid receipt is reported before publication" true (reason <> "")
     | _ -> fail "occupied invalid receipt must preserve the absent package state");
    check bool "receipt inspection does not allocate its logical file size" true
      (Gc.allocated_bytes () -. allocated_before < float_of_int large_receipt_bytes);
    check bool "no active package was published" false (Sys.file_exists (root base));
    (match kind, (Unix.lstat (receipt base)).Unix.st_kind with
     | "directory", Unix.S_DIR ->
       check string "receipt directory contents remain" "operator bytes"
         (read (Filename.concat (receipt base) "keep"))
     | "symlink", Unix.S_LNK ->
       check string "receipt symlink retained" outside (Unix.readlink (receipt base))
     | "large-file", Unix.S_REG ->
       check int "oversized receipt remains untouched" large_receipt_bytes (Unix.stat (receipt base)).Unix.st_size
     | _ -> fail "occupied receipt was replaced");
    check string "external receipt target untouched" "operator bytes" (read outside)))
    ["directory";"symlink";"large-file"]

let test_parallel_installers () = with_base (fun base ->
  installed base first;
  let third = package [ "SKILL.md", "third instruction"; "third.md", "third resource" ] in
  let left = ref None and right = ref None in
  let run slot value = Thread.create (fun () ->
    slot := Some (Package.reconcile ~base_path:base [ value ])) () in
  let a = run left second and b = run right third in
  Thread.join a; Thread.join b;
  List.iter (fun result -> match !result with
    | Some (Ok [ Package.Bundled { result = Ok (Package.Replace_recorded { backup }); _ } ]) ->
      check bool "each publication retains a complete previous package" true
        (Sys.file_exists (Filename.concat backup "SKILL.md"))
    | Some (Error error) -> fail (Package.error_message error)
    | None | Some (Ok _) -> fail "both different distributions should publish serially") [ left; right ];
  match inspect base second with
  | Package.Present { ownership = Package.Recorded; _ } -> ()
  | _ -> fail "receipt must describe the final complete package")

let () = run "Builtin Skill package updates"
  [ "installation", [ test_case "created directory parent sync" `Quick test_created_directory_parent_sync; test_case "hard link preservation" `Quick test_hard_link_preserved; test_case "whole package update and backup" `Quick test_update_complete_package
                    ; test_case "operator edits remain active" `Quick test_preserve_operator_changes
                    ; test_case "untracked package review and explicit update" `Quick test_untracked_reviewed_update
                    ; test_case "streamed large operator resource" `Quick test_streamed_resource_revision
                    ; test_case "export sync failure retains complete published package" `Quick test_export_parent_sync_failure_retains_published_package
                    ; test_case "stale resource revision rejects replacement" `Quick test_stale_resource_revision
                    ; test_case "changed bundled revision rejects replacement" `Quick test_bundle_changed_after_review
                    ; test_case "unreadable operator directory is preserved" `Quick test_unreadable_operator_directory
                    ; test_case "symlink resource rejected" `Quick test_symlink_is_not_a_package
                    ; test_case "untracked tree equal to the release is recorded" `Quick test_adopt_identical_untracked
                    ; test_case "stale receipt over the release tree is rewritten" `Quick test_adopt_identical_over_stale_receipt
                    ; test_case "symlinked deployment volume" `Quick test_symlinked_deployment_root
                    ; test_case "invalid deployment roots reject" `Quick test_invalid_deployment_roots
                    ; test_case "missing package preserves occupied invalid receipt" `Quick test_missing_package_with_occupied_receipt
                    ; test_case "same-process installers serialize" `Quick test_parallel_installers ]
  ; "retirement", [ test_case "recorded package no longer shipped moves aside" `Quick test_retire_recorded
                  ; test_case "receipt without a tree is removed" `Quick test_retire_receipt_without_tree
                  ; test_case "edited package survives retirement" `Quick test_retire_keeps_modified
                  ; test_case "packages without receipts are never retired" `Quick test_retire_never_touches_untracked ] ]
