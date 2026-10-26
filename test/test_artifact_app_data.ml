module Data = Masc.Artifact_app_data
module Store = Masc.Artifact_app_data_store
module Publications = Masc.Published_artifact_store
module Routes = Server_routes_http_routes_artifact_app_data
let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored value = Result.map_error Store.error_message value |> ok
let target = { Data.artifact_id = "artifact-" ^ String.make 32 'a'; revision = 1 }
let at = "2026-10-26T04:00:00+09:00"
let inputs value = `Assoc ["memo", `String value; "answers", `List [`Bool true; `Null; `Int 3]]
let request_json ?(id = Random_id.uuid_v7 ()) ?(version = 0) target data =
  `Assoc ["target", Data.target_to_json target; "id", `String id; "expected_version", `Int version; "data", data]
let request ?id ?version target data = Data.request_of_json (request_json ?id ?version target data) |> ok
let apply state request = Data.apply state ~at request |> Result.map_error (function
  | Data.Invalid message -> message | Conflict -> "unexpected conflict" | Request_collision -> "unexpected request collision") |> ok
let with_base f =
  let base = Filename.temp_file "artifact_app_data_" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
let publish ?(format = "html") ?previous ~base_path content =
  let update = match previous with None -> [] | Some id -> ["id", `String id; "expected_revision", `Int 1] in
  let request = Masc.Published_artifact.request_of_json (`Assoc (update @
    ["title", `String "Input fixture"; "summary", `String "personal form";
     "format", `String format; "content", `String content])) |> ok in
  let artifact, revision = Publications.publish ~base_path ~author:"publisher" request
    |> Result.map_error Publications.error_message |> ok in
  { Data.artifact_id = artifact.id; revision = revision.revision }
let file_for ~base_path =
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_app_data" in
  let name = Sys.readdir dir |> Array.to_list |> List.find (fun name -> Filename.check_suffix name ".json") in
  dir, Filename.concat dir name
let unavailable = function
  | Error (Store.Unavailable _) -> ()
  | Error error -> Alcotest.fail (Store.error_message error)
  | Ok _ -> Alcotest.fail "unsafe storage accepted"
let schema_tests = [
  "strict request and JSON ownership", `Quick, (fun () ->
    let fields = match request_json target (inputs "메모 🐱") with `Assoc fields -> fields | _ -> assert false in
    ignore (Data.request_of_json (`Assoc fields) |> ok);
    let replace key value = `Assoc ((key, value) :: List.remove_assoc key fields) in
    List.iter (fun json -> match Data.request_of_json json with
      | Error _ -> () | Ok _ -> Alcotest.fail "invalid application request accepted")
      [`Assoc (("actor", `String "someone else") :: fields);
       `Assoc (("id", `String (Random_id.uuid_v7 ())) :: fields);
       `Assoc (List.remove_assoc "expected_version" fields);
       replace "expected_version" (`Int (-1)); replace "expected_version" (`Int 9_007_199_254_740_992);
       replace "id" (`String "../owner"); replace "data" `Null;
       replace "data" (`Assoc ["a", `Assoc ["x", `Int 1; "x", `Int 2]]);
       replace "data" (`Assoc ["a", `Float Float.nan]);
       replace "data" (`Assoc ["a", `Int 9_007_199_254_740_992]);
       replace "data" (`Assoc ["a", `String "\255"]);
       replace "target" (Data.target_to_json { target with revision = 0 })]);
  "retry, collision, stale write and canonical data", `Quick, (fun () ->
    let empty = Data.empty ~target ~actor:"reader" |> ok in
    let first = request target (inputs "첫 메모") in let saved = apply empty first in
    Alcotest.(check int) "first save" 1 saved.version;
    let later = apply saved (request ~version:1 target (inputs "나중 메모")) in
    let retry = apply later first in
    Alcotest.(check int) "old retry preserves latest version" 2 retry.version;
    Alcotest.(check bool) "old retry preserves latest data" true (retry.data = later.data);
    (match Data.apply later ~at (request ~id:first.id target (inputs "changed")) with
     | Error Data.Request_collision -> () | _ -> Alcotest.fail "reused id accepted");
    (match Data.apply later ~at (request target (inputs "stale")) with
     | Error Data.Conflict -> () | _ -> Alcotest.fail "stale writer accepted");
    let reordered = match first.data with `Assoc fields -> `Assoc (List.rev fields) | _ -> assert false in
    Alcotest.(check int) "key order has no semantic effect" 2
      (apply later (request ~id:first.id target reordered)).version;
    Alcotest.(check bool) "strict durable round trip" true (Data.of_json (Data.to_json later) |> ok = later));
  "corrupt durable receipts are refused", `Quick, (fun () ->
    let state = apply (Data.empty ~target ~actor:"reader" |> ok) (request target (inputs "saved")) in
    let fields = match Data.to_json state with `Assoc fields -> fields | _ -> assert false in
    let replace key value = `Assoc ((key, value) :: List.remove_assoc key fields) in
    List.iter (fun json -> match Data.of_json json with Error _ -> () | Ok _ -> Alcotest.fail "corrupt state accepted")
      [replace "schema" (`String "unknown"); replace "data" (inputs "tampered");
       replace "version" (`Int 0); replace "receipts" (`List []);
       replace "receipts" (`List (List.map (fun receipt ->
         match receipt with `Assoc fields -> `Assoc (("expected_version", `Int 1) :: List.remove_assoc "expected_version" fields)
         | _ -> assert false) (match List.assoc "receipts" fields with `List values -> values | _ -> assert false)))]);
]
let storage_tests = [
  "request workspace must match before dispatch", `Quick, (fun () -> with_base (fun base_path ->
    ignore (publish ~base_path "<input>");
    let config = Masc.Workspace.default_config base_path in
    let fields = match request_json target (inputs "private") with `Assoc fields -> fields | _ -> assert false in
    let expected = `Assoc ["base_path", `String (Unix.realpath base_path);
      "masc_root", `String (Unix.realpath (Common.masc_dir_from_base_path ~base_path))] in
    let decode expected = Routes.decode_request ~config
      (Yojson.Safe.to_string (`Assoc (("expected_workspace", expected) :: fields))) in
    ignore (decode expected |> Result.map_error (fun _ -> "matching workspace refused") |> ok);
    (match decode (`Assoc ["base_path", `String "/another/workspace"; "masc_root", `String "/another/workspace/.masc"]) with
     | Error (_, `Conflict) -> () | _ -> Alcotest.fail "mismatched workspace dispatched");
    (match decode (`Assoc []) with Error (_, `Bad_request) -> () | _ -> Alcotest.fail "malformed workspace dispatched");
    (match Routes.decode_request ~config (Yojson.Safe.to_string (`Assoc (("actor", `String "spoof") :: fields))) with
     | Error (_, `Bad_request) -> () | _ -> Alcotest.fail "payload actor accepted")));
  "personal revision scope and immutable publication", `Quick, (fun () -> with_base (fun base_path ->
    let first = publish ~base_path "<textarea id='memo'></textarea>" in
    let read actor target = Store.read ~base_path ~actor target |> stored in
    Alcotest.(check int) "missing personal data is empty" 0 (read "human" first).version;
    ignore (Store.set ~base_path ~actor:"human" (request first (inputs "저장한 메모")) |> stored);
    Masc.Keeper_fs.clear_dir_cache ();
    Alcotest.(check int) "new client reads saved data" 1 (read "human" first).version;
    Alcotest.(check int) "another authenticated actor has separate inputs" 0 (read "keeper" first).version;
    let next = publish ~previous:first.artifact_id ~base_path "<input name='survey'>" in
    Alcotest.(check int) "new publication has separate inputs" 0 (read "human" next).version;
    let other = publish ~base_path "<textarea></textarea>" in
    Alcotest.(check int) "other document has separate inputs" 0 (read "human" other).version;
    let _, revision, content = Publications.read ~base_path ~id:first.artifact_id ~revision:(Some 1)
      |> Result.map_error Publications.error_message |> ok in
    Alcotest.(check int) "publication revision unchanged" 1 revision.revision;
    Alcotest.(check string) "publication body unchanged" "<textarea id='memo'></textarea>" content;
    let _, file = file_for ~base_path in
    Alcotest.(check int) "private input file" 0o600 ((Unix.stat file).Unix.st_perm land 0o777)));
  "simultaneous windows cannot overwrite one another", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    let left_request = request target (inputs "left") and right_request = request target (inputs "right") in
    let save request = Eio_unix.run_in_systhread (fun () -> Store.set ~base_path ~actor:"same human" request) in
    let left, right = Eio.Fiber.pair (fun () -> save left_request) (fun () -> save right_request) in
    let saved, refused = match left, right with
      | Ok saved, Error (Store.Conflict current) ->
        Alcotest.(check bool) "conflict identifies the winner" true (saved = current); saved, right_request
      | Error (Store.Conflict current), Ok saved ->
        Alcotest.(check bool) "conflict identifies the winner" true (saved = current); saved, left_request
      | Ok saved, Error (Store.Unavailable message) ->
        Format.eprintf "Concurrent owned read refused: %s@." message; saved, right_request
      | Error (Store.Unavailable message), Ok saved ->
        Format.eprintf "Concurrent owned read refused: %s@." message; saved, left_request
      | _ ->
        let describe = function Ok state -> "saved version " ^ string_of_int state.Data.version
          | Error error -> Store.error_message error in
        Alcotest.fail ("concurrent outcomes: " ^ describe left ^ " / " ^ describe right) in
    let recovered = Store.read ~base_path ~actor:"same human" target |> stored in
    Alcotest.(check bool) "durable state is exactly the winner" true (saved = recovered);
    Alcotest.(check int) "only one version committed" 1 recovered.version;
    Alcotest.(check int) "only one receipt committed" 1 (List.length recovered.receipts);
    (match Store.set ~base_path ~actor:"same human" refused with
     | Error (Store.Conflict current) -> Alcotest.(check bool) "manual rerequest cannot overwrite winner" true (current = recovered)
     | Error error -> Alcotest.fail (Store.error_message error) | Ok _ -> Alcotest.fail "loser overwrote winner after competition ended")));
  "duplicate retry cannot roll back later input", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    let first = request target (inputs "first") in
    ignore (Store.set ~base_path ~actor:"human" first |> stored);
    let latest = Store.set ~base_path ~actor:"human" (request ~version:1 target (inputs "latest")) |> stored in
    let retry = Store.set ~base_path ~actor:"human" first |> stored in
    Alcotest.(check bool) "latest input retained" true (latest = retry)));
  "missing publication and non HTML cannot create personal state", `Quick, (fun () -> with_base (fun base_path ->
    (match Store.read ~base_path ~actor:"reader" target with
     | Error (Store.Artifact_error Publications.Missing) -> () | _ -> Alcotest.fail "unpublished document accepted");
    let target = publish ~format:"markdown" ~base_path "# static" in
    (match Store.set ~base_path ~actor:"reader" (request target (inputs "secret")) with
     | Error (Store.Invalid _) -> () | _ -> Alcotest.fail "non HTML app accepted");
    Alcotest.(check bool) "invalid requests create no input directory" false
      (Sys.file_exists (Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_app_data"))));
  "corruption, ownership and symlinks cannot be replaced", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    let saved = Store.set ~base_path ~actor:"human" (request target (inputs "before")) |> stored in
    let dir, file = file_for ~base_path in let original = Fs_compat.load_file file in
    let save () = Store.set ~base_path ~actor:"human" (request ~version:1 target (inputs "after")) in
    Fs_compat.save_file file "{corrupt";
    unavailable (Store.read ~base_path ~actor:"human" target); unavailable (save ());
    Alcotest.(check string) "corrupt bytes retained" "{corrupt" (Fs_compat.load_file file);
    Fs_compat.save_file file original;
    let held = Filename.concat base_path "held-input.json" in Unix.rename file held; Unix.symlink held file;
    unavailable (save ()); Alcotest.(check string) "external bytes untouched" original (Fs_compat.load_file held);
    Unix.unlink file; Unix.rename held file;
    Unix.chmod dir 0o777;
    Fun.protect ~finally:(fun () -> Unix.chmod dir 0o700) (fun () -> unavailable (save ()));
    let spoofed = Data.to_json saved |> function `Assoc fields -> `Assoc (("actor", `String "another owner") :: List.remove_assoc "actor" fields) | _ -> assert false in
    Fs_compat.save_file file (Yojson.Safe.to_string spoofed);
    unavailable (Store.read ~base_path ~actor:"human" target); unavailable (save ())));
  "uncertain commit is observable and exact retry is idempotent", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    ignore (Store.set ~base_path ~actor:"human" (request target (inputs "first")) |> stored);
    let next = request ~version:1 target (inputs "second") in
    let _, file = file_for ~base_path in
    let identity = Unix.stat (Fs_compat.private_jsonl_lock_path file) in
    let injected = Atomic.make false in
    let close_fd fd =
      let actual = Unix.fstat fd in Unix.close fd;
      if actual.Unix.st_dev = identity.Unix.st_dev && actual.Unix.st_ino = identity.Unix.st_ino
        && Atomic.compare_and_set injected false true
      then raise (Unix.Unix_error (Unix.EIO, "close", "injected stable lock settlement failure")) in
    let io = Fs_compat.{before_sync_parent=(fun _ -> ());close_fd} in
    (match Store.For_testing.set_with_rewrite_io ~io ~base_path ~actor:"human" next with
     | Error (Store.Commit_uncertain attempted) -> Alcotest.(check int) "attempted version" 2 attempted.version
     | Error error -> Alcotest.fail (Store.error_message error) | Ok _ -> Alcotest.fail "uncertain commit claimed saved");
    Alcotest.(check bool) "real stable lock close failed" true (Atomic.get injected);
    let recovered = Store.read ~base_path ~actor:"human" target |> stored in
    Alcotest.(check int) "published write can be reread" 2 recovered.version;
    let retry = Store.set ~base_path ~actor:"human" next |> stored in
    Alcotest.(check bool) "manual exact retry adds no version" true (recovered = retry)));
  "lock symlinks never touch external files", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    ignore (Store.set ~base_path ~actor:"human" (request target (inputs "before")) |> stored);
    let _, file = file_for ~base_path in let original = Fs_compat.load_file file in
    let lock = Fs_compat.private_jsonl_lock_path file in Unix.unlink lock;
    let outside = Filename.concat base_path "outside-lock" in Unix.symlink outside lock;
    unavailable (Store.set ~base_path ~actor:"human" (request ~version:1 target (inputs "after")));
    Alcotest.(check bool) "dangling lock target not created" false (Sys.file_exists outside);
    Fs_compat.save_file outside "external";
    unavailable (Store.read ~base_path ~actor:"human" target);
    unavailable (Store.set ~base_path ~actor:"human" (request ~version:1 target (inputs "after")));
    Alcotest.(check string) "external lock target untouched" "external" (Fs_compat.load_file outside);
    Alcotest.(check string) "input state untouched" original (Fs_compat.load_file file)));
  "unsafe data file permissions refuse reads and writes without repair", `Quick, (fun () -> with_base (fun base_path ->
    let target = publish ~base_path "<input>" in
    ignore (Store.set ~base_path ~actor:"human" (request target (inputs "private")) |> stored);
    let _, file = file_for ~base_path in let original = Fs_compat.load_file file in
    Fun.protect ~finally:(fun () -> Unix.chmod file 0o600) (fun () ->
      List.iter (fun permissions ->
        Unix.chmod file permissions;
        unavailable (Store.read ~base_path ~actor:"human" target);
        unavailable (Store.set ~base_path ~actor:"human" (request ~version:1 target (inputs "overwrite")));
        Alcotest.(check int) "unsafe mode is not silently repaired" permissions ((Unix.stat file).Unix.st_perm land 0o7777);
        Alcotest.(check string) "unsafe state bytes stay untouched" original (Fs_compat.load_file file))
        [0o666; 0o644; 0o620; 0o604; 0o400])));
]
let () = Eio_main.run (fun _ -> Alcotest.run "Personal artifact application data"
  ["strict domain", schema_tests; "durable authenticated scope", storage_tests])
