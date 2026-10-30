module A = Masc.Published_artifact
module Publications = Masc.Published_artifact_store
module C = Masc.Published_artifact_check
module S = Masc.Published_artifact_check_store

let with_base f =
  let base = Filename.temp_file "artifact_checks" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)

let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored result = Result.map_error S.error_message result |> ok
let published result = Result.map_error Publications.error_message result |> ok

let publish ?id ?expected_revision ~base_path content =
  let update = match id, expected_revision with
    | None, None -> []
    | Some id, Some n -> ["id", `String id; "expected_revision", `Int n]
    | None, Some _ | Some _, None -> Alcotest.fail "incomplete publication fixture" in
  let request = A.request_of_json (`Assoc (update @
    ["title", `String "report"; "summary", `String "check fixture";
     "format", `String "markdown"; "content", `String content])) |> ok in
  Publications.publish ~base_path ~author:"producer" request |> published

let change_json ?(expected = None) ~checked id (revision : A.revision) =
  `Assoc ["id", `String id; "revision", `Int revision.revision;
    "body_sha256", `String revision.body.sha256; "checked", `Bool checked;
    "expected_change_id", Option.fold ~none:`Null ~some:(fun id -> `String id) expected]

let change ?expected ~checked id revision =
  C.request_of_json (change_json ?expected ~checked id revision) |> ok

let set ~base_path ~actor request = S.set ~base_path ~actor request |> stored

let test_revision_and_shared_state () = with_base (fun base_path ->
  let artifact, first = publish ~base_path "# original\r\n" in
  ignore (Publications.read ~base_path ~id:artifact.id ~revision:None |> published);
  Alcotest.(check int) "reading does not check the report" 0
    (List.length (S.list ~base_path |> stored).checks);
  let checked = set ~base_path ~actor:"dashboard-human"
    (change ~checked:true artifact.id first) in
  Alcotest.(check bool) "explicit change checked" true (checked.state = C.Checked);
  Masc.Keeper_fs.clear_dir_cache ();
  let recovered = S.list ~base_path |> stored in
  Alcotest.(check int) "a new client sees one durable check" 1 (List.length recovered.checks);
  let reread = List.hd recovered.checks in
  Alcotest.(check string) "authenticated actor retained" "dashboard-human" reread.changed_by;
  Alcotest.(check string) "opaque CAS identity survives reread" checked.change_id reread.change_id;
  let _, second = publish ~id:artifact.id ~expected_revision:1 ~base_path "# original\r\n" in
  Alcotest.(check string) "same bytes in next revision" first.body.sha256 second.body.sha256;
  let second_change = change ~checked:true artifact.id second in
  Alcotest.(check bool) "new revision cannot inherit the old check" false
    (C.same_target checked.target second_change.target);
  let unchecked = set ~base_path ~actor:"tui-human"
    (change ~expected:(Some checked.change_id) ~checked:false artifact.id first) in
  Alcotest.(check bool) "uncheck persists an explicit new state" true (unchecked.state = C.Unchecked);
  Alcotest.(check bool) "uncheck changes CAS identity" false
    (String.equal checked.change_id unchecked.change_id);
  (match S.set ~base_path ~actor:"stale-dashboard"
      (change ~expected:(Some checked.change_id) ~checked:true artifact.id first) with
   | Error (S.Conflict (Some current)) ->
     Alcotest.(check string) "stale write returns actual durable state" unchecked.change_id current.change_id
   | Error error -> Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "stale check overwrote explicit uncheck");
  ignore (set ~base_path ~actor:"tui-human" second_change);
  let listing = S.list ~base_path |> stored in
  Alcotest.(check int) "both revision states retained" 2 (List.length listing.checks);
  let _, latest, body = Publications.read ~base_path ~id:artifact.id ~revision:None |> published in
  Alcotest.(check int) "checks do not publish report revisions" 2 latest.revision;
  Alcotest.(check string) "checks do not modify source" "# original\r\n" body)

let test_concurrent_cas () = with_base (fun base_path ->
  let artifact, revision = publish ~base_path "report" in
  let request = change ~checked:true artifact.id revision in
  let left, right = Eio.Fiber.pair
    (fun () -> Eio_unix.run_in_systhread (fun () -> S.set ~base_path ~actor:"first-client" request))
    (fun () -> Eio_unix.run_in_systhread (fun () -> S.set ~base_path ~actor:"second-client" request)) in
  let success, conflict = match left, right with
    | Ok success, Error (S.Conflict (Some conflict))
    | Error (S.Conflict (Some conflict)), Ok success -> success, conflict
    | Error error, _ | _, Error error -> Alcotest.fail (S.error_message error)
    | Ok _, Ok _ -> Alcotest.fail "both stale writers committed" in
  Alcotest.(check string) "losing client sees committed winner" success.change_id conflict.change_id;
  Alcotest.(check int) "exactly one durable revision check" 1
    (List.length (S.list ~base_path |> stored).checks))

let test_strict_request_and_digest () = with_base (fun base_path ->
  let artifact, revision = publish ~base_path "report" in
  let fields = match change_json ~checked:true artifact.id revision with
    | `Assoc fields -> fields | _ -> Alcotest.fail "fixture must be object" in
  let replace key value = `Assoc ((key,value) :: List.remove_assoc key fields) in
  List.iter (fun json -> match C.request_of_json json with
    | Error _ -> () | Ok _ -> Alcotest.fail "untrusted check request accepted")
    [`Assoc (("changed_by", `String "spoofed") :: fields);
     `Assoc (("checked", `Bool false) :: fields);
     `Assoc (List.remove_assoc "expected_change_id" fields);
     replace "revision" (`Int 0); replace "id" (`String "../report");
     replace "body_sha256" (`String "bad"); replace "checked" (`String "true");
     replace "expected_change_id" (`String "bad")];
  let wrong_digest = C.request_of_json
    (replace "body_sha256" (`String (String.make 64 '0'))) |> ok in
  (match S.set ~base_path ~actor:"human" wrong_digest with
   | Error (S.Invalid _) -> ()
   | Error error -> Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "wrong revision digest was confirmed");
  let missing = C.request_of_json (replace "revision" (`Int 2)) |> ok in
  (match S.set ~base_path ~actor:"human" missing with
   | Error (S.Artifact_error Publications.Missing) -> ()
   | Error error -> Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "unpublished revision was confirmed");
  Alcotest.(check int) "invalid writes leave no checked state" 0
    (List.length (S.list ~base_path |> stored).checks))

let test_corrupt_or_unsafe_storage () = with_base (fun base_path ->
  let artifact, revision = publish ~base_path "report" in
  let checked = set ~base_path ~actor:"human" (change ~checked:true artifact.id revision) in
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifact_checks" in
  let file = Filename.concat dir (artifact.id ^ "-r1.json") in
  let check_unavailable = function
    | Error (S.Unavailable _) -> ()
    | Error error -> Alcotest.fail (S.error_message error)
    | Ok _ -> Alcotest.fail "unsafe check storage was treated as available" in
  Fs_compat.save_file file "{corrupt";
  let partial = S.list ~base_path |> stored in
  Alcotest.(check int) "corruption is not an authoritative unchecked result" 1
    (List.length partial.diagnostics);
  check_unavailable (S.set ~base_path ~actor:"human"
    (change ~expected:(Some checked.change_id) ~checked:false artifact.id revision));
  Fs_compat.save_file file (Yojson.Safe.to_string (C.to_json checked) ^ "\n");
  let held = Filename.concat base_path "held-check.json" in
  Unix.rename file held; Unix.symlink held file;
  Alcotest.(check int) "symlink read is a diagnostic" 1
    (List.length (S.list ~base_path |> stored).diagnostics);
  check_unavailable (S.set ~base_path ~actor:"human"
    (change ~expected:(Some checked.change_id) ~checked:false artifact.id revision));
  Unix.unlink file; Unix.rename held file;
  Unix.chmod dir 0o777;
  Fun.protect ~finally:(fun () -> Unix.chmod dir 0o700) (fun () ->
    check_unavailable (S.list ~base_path);
    check_unavailable (S.set ~base_path ~actor:"human"
      (change ~expected:(Some checked.change_id) ~checked:false artifact.id revision))))

let test_lock_symlink () = with_base (fun outside -> with_base (fun base_path ->
  let artifact, revision = publish ~base_path "report" in
  let checked = set ~base_path ~actor:"human" (change ~checked:true artifact.id revision) in
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifact_checks" in
  let file = Filename.concat dir (artifact.id ^ "-r1.json") in
  let lock = Fs_compat.private_jsonl_lock_path file in
  let held = lock ^ "-held" in
  let target = Filename.concat outside "must-not-create-or-modify" in
  let original = Fs_compat.load_file file in
  Unix.rename lock held;
  Fun.protect ~finally:(fun () -> Unix.unlink lock; Unix.rename held lock) (fun () ->
    Unix.symlink target lock;
    let refuse () = match S.set ~base_path ~actor:"human"
      (change ~expected:(Some checked.change_id) ~checked:false artifact.id revision) with
      | Error (S.Unavailable _) -> ()
      | Error error -> Alcotest.fail (S.error_message error)
      | Ok _ -> Alcotest.fail "unsafe lock admitted" in
    refuse ();
    Alcotest.(check bool) "dangling lock does not create an external file" false (Sys.file_exists target);
    Fs_compat.save_file target "external bytes";
    refuse ();
    Alcotest.(check string) "existing external target is unchanged" "external bytes" (Fs_compat.load_file target);
    Alcotest.(check string) "prior check bytes remain unchanged" original (Fs_compat.load_file file));
  let listing = S.list ~base_path |> stored in
  Alcotest.(check string) "prior check survives refused lock requests" checked.change_id
    (List.hd listing.checks).change_id))

let test_precondition_settlement () = with_base (fun base_path ->
  let artifact, revision = publish ~base_path "report" in
  let checked = set ~base_path ~actor:"human" (change ~checked:true artifact.id revision) in
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifact_checks" in
  let file = Filename.concat dir (artifact.id ^ "-r1.json") in
  let before = Fs_compat.load_file file in
  let identity = Unix.stat file in
  let injected = Atomic.make false in
  let close_fd fd =
    let stat = Unix.fstat fd in
    Unix.close fd;
    if stat.Unix.st_dev = identity.Unix.st_dev && stat.Unix.st_ino = identity.Unix.st_ino
       && Atomic.compare_and_set injected false true
    then raise (Unix.Unix_error (Unix.EIO, "close", "injected precondition settlement")) in
  let io = Fs_compat.{before_sync_parent=(fun _ -> ());close_fd} in
  (match S.For_testing.set_with_rewrite_io ~io ~base_path ~actor:"human"
    (change ~expected:(Some checked.change_id) ~checked:false artifact.id revision) with
   | Error (S.Unavailable _) -> ()
   | Error error -> Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "failed precondition was treated as a saved check");
  Alcotest.(check bool) "real precondition descriptor close failed" true (Atomic.get injected);
  Alcotest.(check string) "precondition failure changed no record bytes" before (Fs_compat.load_file file);
  Alcotest.(check string) "original check remains authoritative" checked.change_id
    (List.hd (S.list ~base_path |> stored).checks).change_id)

let () = Eio_main.run (fun _ ->
  Alcotest.run "shared artifact revision checks"
    ["durable explicit confirmation",[
      Alcotest.test_case "shared recovery, exact revision and stale uncheck" `Quick test_revision_and_shared_state;
      Alcotest.test_case "two clients compete through durable CAS" `Quick test_concurrent_cas;
      Alcotest.test_case "strict request, actor spoof and immutable digest" `Quick test_strict_request_and_digest;
      Alcotest.test_case "lock links cannot create or alter external files" `Quick test_lock_symlink;
      Alcotest.test_case "precondition close failure is not a possible commit" `Quick test_precondition_settlement;
      Alcotest.test_case "corrupt and unsafe storage remain unknown" `Quick test_corrupt_or_unsafe_storage]])
