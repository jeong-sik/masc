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
let install base request value = get (Package.install ~base_path:base ~request value)
let inspect base value = get (Package.inspect ~base_path:base value)
let revision = function Package.Present { revision; _ } -> revision | Package.Missing -> fail "missing package"
let reviewed_request = function
  | Package.Present { revision; bundled_revision; _ } ->
    Package.Replace_if_revisions { installed_revision=revision; bundled_revision }
  | Package.Missing -> fail "cannot review a missing installation"
let with_base test =
  let base = Filename.temp_dir "masc-skill-package-test-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () -> test base)

let assert_second base =
  check string "new instruction" "short instruction" (read (file base "SKILL.md"));
  check string "lazy resource published with instruction" "new resource" (read (file base "references/lazy.md"));
  check bool "retired distribution resource removed" false (Sys.file_exists (file base "references/old.md"))

let test_update_complete_package () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  let backup = match install base Package.Automatic second with
    | Package.Updated { backup } -> backup | _ -> fail "expected updated package" in
  assert_second base;
  check string "old body retained" "old instruction" (read (Filename.concat backup "SKILL.md"));
  check string "old resource retained" "old resource" (read (Filename.concat backup "references/old.md"));
  (match inspect base second with
   | Package.Present { revision; bundled_revision; ownership = Package.Recorded } ->
     check string "receipt describes complete new tree" bundled_revision revision
   | _ -> fail "new package must be recorded");
  match install base Package.Automatic second with Package.Current -> () | _ -> fail "same release must be a no-op")

let test_preserve_operator_changes () =
  let edits =
    [ "body", (fun base -> Fs_compat.save_file (file base "SKILL.md") "operator instructions")
    ; "resource deletion", (fun base -> Unix.unlink (file base "references/old.md"))
    ; "resource addition", (fun base -> Fs_compat.save_file (file base "operator.txt") "my resource")
    ; "empty directory", (fun base -> Unix.mkdir (file base "operator") 0o700)
    ; "permissions", (fun base -> Unix.chmod (file base "SKILL.md") 0o600)
    ] in
  List.iter (fun (label, edit) -> with_base (fun base ->
    ignore (install base Package.Automatic first);
    edit base;
    let before = revision (inspect base second) in
    (match install base Package.Automatic second with
     | Package.Preserved (Package.Present { ownership = Package.Modified; _ }) -> ()
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
  ignore (install base Package.Automatic first);
  let request = reviewed_request (inspect base second) in
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
  (match install base Package.Automatic second with
   | Package.Preserved_uninspectable _ -> ()
   | _ -> fail "automatic refresh must preserve hard links");
  (match Package.install ~base_path:base ~request second with
   | Error (Package.Invalid_path _) -> ()
   | _ -> fail "reviewed replacement must reject new linking semantics");
  check int "operator link retained" (Unix.stat linked_target).st_ino (Unix.stat resource).st_ino;
  check string "old instruction retained" "old instruction" (read (file base "SKILL.md"));
  check string "receipt unchanged" original_receipt (read (receipt base)))

let test_untracked_reviewed_update () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  Unix.unlink (receipt base);
  let request = reviewed_request (inspect base second) in
  (match install base Package.Automatic second with
   | Package.Preserved (Package.Present { ownership = Package.Untracked; _ }) -> ()
   | _ -> fail "untracked installation must wait for review");
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
  ignore (install base request second);
  assert_second base)

let test_streamed_resource_revision () = with_base (fun base ->
  ignore (install base Package.Automatic first);
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
  (match install base Package.Automatic second with
   | Package.Preserved (Package.Present {ownership=Package.Modified;_}) -> ()
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
  ignore (install base Package.Automatic first);
  let request = reviewed_request (inspect base second) in
  Fs_compat.save_file (file base "references/old.md") "edited after preview";
  (match Package.install ~base_path:base ~request second with
   | Error (Package.Revision_conflict _) -> ()
   | _ -> fail "body-only revision must not authorize resource overwrite");
  check string "resource edit survives rejection" "edited after preview" (read (file base "references/old.md")))

let test_bundle_changed_after_review () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  let reviewed = inspect base second in
  let request = reviewed_request reviewed in
  let original = revision reviewed in
  let third = package [ "SKILL.md", "unreviewed third instruction"; "third.md", "new bytes" ] in
  let third_revision = match inspect base third with
    | Package.Present {bundled_revision;_} -> bundled_revision
    | Package.Missing -> fail "installed package missing" in
  (match Package.install ~base_path:base ~request third with
   | Error (Package.Bundled_revision_conflict {actual_revision}) ->
     check string "conflict identifies the unreviewed distribution" third_revision actual_revision
   | _ -> fail "same installed revision must not authorize a different bundled package");
  check string "active tree unchanged after distribution mismatch" original (revision (inspect base first));
  check string "active instruction retained" "old instruction" (read (file base "SKILL.md"));
  check bool "unreviewed resource never published" false (Sys.file_exists (file base "third.md")))

let test_unreadable_operator_directory () = with_base (fun base ->
  ignore (install base Package.Automatic first);
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
    let outcome = install base Package.Automatic second in
    (match unreadable, outcome with
     | true, Package.Preserved_uninspectable {reason} ->
       check bool "preservation exposes the inspection failure" true (reason <> "")
     | false, Package.Preserved (Package.Present {ownership=Package.Modified;_}) ->
       Printf.printf "permission denial unavailable; verified privileged chmod-edit preservation instead\n%!"
     | _ -> fail "uninspectable or chmod-edited operator directory must be preserved");
    check string "instruction remains active" "old instruction" (read (file base "SKILL.md"));
    check string "receipt was not advanced" original_receipt (read (receipt base)));
  check string "old resource remains after restoring access" "old resource" (read (file base "references/old.md"));
  check bool "new distribution resource absent" false (Sys.file_exists (file base "references/lazy.md")))

let test_symlink_is_not_a_package () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  let outside = Filename.concat base "outside.txt" in
  Fs_compat.save_file outside "outside bytes";
  Unix.unlink (file base "references/old.md");
  Unix.symlink outside (file base "references/old.md");
  (match install base Package.Automatic second with
   | Package.Preserved_uninspectable _ -> () | _ -> fail "symlink must not be followed");
  (match install base Package.Seed_missing second with
   | Package.Already_present -> () | _ -> fail "startup must not inspect operator resources");
  check string "outside file untouched" "outside bytes" (read outside);
  check string "instruction untouched" "old instruction" (read (file base "SKILL.md")))

let test_startup_does_not_upgrade () = with_base (fun base ->
  ignore (install base Package.Seed_missing first);
  (match install base Package.Seed_missing second with Package.Already_present -> () | _ -> fail "startup only seeds");
  check string "startup retains complete recorded package" "old instruction" (read (file base "SKILL.md")))

let test_symlinked_deployment_root () = with_base (fun base ->
  let mounted = Filename.concat base "mounted-volume" in
  Unix.mkdir mounted 0o700;
  Unix.symlink mounted (Filename.concat base ".masc");
  ignore (install base Package.Automatic first);
  let backup = match install base Package.Automatic second with
    | Package.Updated {backup} -> backup | _ -> fail "mounted deployment must update" in
  assert_second base;
  let physical = Unix.realpath mounted in
  check bool "backup pinned beneath physical deployment root" true
    (String.starts_with ~prefix:(physical ^ "/skill-packages/") backup);
  check string "mounted receipt records current tree" (revision (inspect base second) ^ "\n")
    (read (Filename.concat physical "skill-packages/browser-fixture.sha256"));
  Fs_compat.save_file (file base "SKILL.md") "operator edit";
  let request = reviewed_request (inspect base first) in
  ignore (install base request first);
  check string "reviewed replacement through deployment link succeeds" "old instruction" (read (file base "SKILL.md"));
  let outside = Filename.concat base "outside-resource" in
  Fs_compat.save_file outside "outside";
  Unix.unlink (file base "references/old.md");
  Unix.symlink outside (file base "references/old.md");
  (match install base Package.Automatic second with
   | Package.Preserved_uninspectable _ -> ()
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
       Package.install ~base_path:base ~request:Package.Automatic second |> Result.map (fun _ -> ())]))
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
    (match install base Package.Automatic second with
     | Package.Preserved_uninspectable {reason} ->
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
  ignore (install base Package.Automatic first);
  let third = package [ "SKILL.md", "third instruction"; "third.md", "third resource" ] in
  let left = ref None and right = ref None in
  let run slot value = Thread.create (fun () ->
    slot := Some (Package.install ~base_path:base ~request:Package.Automatic value)) () in
  let a = run left second and b = run right third in
  Thread.join a; Thread.join b;
  List.iter (fun result -> match !result with
    | Some (Ok (Package.Updated { backup })) ->
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
                    ; test_case "startup does not upgrade" `Quick test_startup_does_not_upgrade
                    ; test_case "symlinked deployment volume" `Quick test_symlinked_deployment_root
                    ; test_case "invalid deployment roots reject" `Quick test_invalid_deployment_roots
                    ; test_case "missing package preserves occupied invalid receipt" `Quick test_missing_package_with_occupied_receipt
                    ; test_case "same-process installers serialize" `Quick test_parallel_installers ] ]
