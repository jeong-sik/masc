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

let test_untracked_reviewed_update () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  Unix.unlink (receipt base);
  let before = revision (inspect base second) in
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
  ignore (install base (Package.Replace_if_revision before) second);
  assert_second base)

let test_stale_resource_revision () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  let before = revision (inspect base second) in
  Fs_compat.save_file (file base "references/old.md") "edited after preview";
  (match Package.install ~base_path:base ~request:(Package.Replace_if_revision before) second with
   | Error (Package.Revision_conflict _) -> ()
   | _ -> fail "body-only revision must not authorize resource overwrite");
  check string "resource edit survives rejection" "edited after preview" (read (file base "references/old.md")))

let test_symlink_is_not_a_package () = with_base (fun base ->
  ignore (install base Package.Automatic first);
  let outside = Filename.concat base "outside.txt" in
  Fs_compat.save_file outside "outside bytes";
  Unix.unlink (file base "references/old.md");
  Unix.symlink outside (file base "references/old.md");
  (match install base Package.Automatic second with
   | Package.Preserved_invalid_path _ -> () | _ -> fail "symlink must not be followed");
  (match install base Package.Seed_missing second with
   | Package.Already_present -> () | _ -> fail "startup must not inspect operator resources");
  check string "outside file untouched" "outside bytes" (read outside);
  check string "instruction untouched" "old instruction" (read (file base "SKILL.md")))

let test_startup_does_not_upgrade () = with_base (fun base ->
  ignore (install base Package.Seed_missing first);
  (match install base Package.Seed_missing second with Package.Already_present -> () | _ -> fail "startup only seeds");
  check string "startup retains complete recorded package" "old instruction" (read (file base "SKILL.md")))

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
  [ "installation", [ test_case "whole package update and backup" `Quick test_update_complete_package
                    ; test_case "operator edits remain active" `Quick test_preserve_operator_changes
                    ; test_case "untracked package review and explicit update" `Quick test_untracked_reviewed_update
                    ; test_case "stale resource revision rejects replacement" `Quick test_stale_resource_revision
                    ; test_case "symlink resource rejected" `Quick test_symlink_is_not_a_package
                    ; test_case "startup does not upgrade" `Quick test_startup_does_not_upgrade
                    ; test_case "same-process installers serialize" `Quick test_parallel_installers ] ]
