module A = Masc.Artifact_project_source
module S = Masc.Artifact_project_source_store
let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored = function Ok value -> value | Error error -> Alcotest.fail (S.error_message error)
let unavailable = function
  | Error (S.Unavailable _) -> ()
  | Error ((S.Invalid _ | S.Missing | S.Commit_uncertain _) as error) ->
    Alcotest.fail (S.error_message error)
  | Ok _ -> Alcotest.fail "unsafe or damaged project source was accepted"
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let with_base f =
  let base = Filename.temp_file "artifact-project-source-" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
let build = `Assoc ["kind", `String "browser_modules"; "entry_html", `String "index.html"]
let source_files = ["package.json", "{}\n"; "index.html", "\239\187\191<h1>같이 편집해요 😀</h1>\r\n";
                    "이미지/원본.png", "\000\255\128PNG\r\n"; "empty.txt", ""]
let request_json ?(build = build) files =
  `Assoc ["schema", `String "masc.artifact_project.v1";
          "build", build; "install_scripts", `Bool false;
          "files", `List (List.map (fun (path, content) ->
            `Assoc ["path", `String path; "content_base64", `String (Base64.encode_string content)]) files)]
let request = request_json source_files |> A.request_of_json |> ok
let save base_path request = S.save ~base_path ~author:"keeper-함께" request |> stored
let metadata base id = Filename.concat
  (Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "artifact_project_sources") (id ^ ".json")
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let check_request expected actual =
  Alcotest.(check string) "worker contract and all file bytes survive"
    (Yojson.Safe.to_string (A.request_to_json expected))
    (Yojson.Safe.to_string (A.request_to_json actual))
let test_durable_source () = with_base (fun base_path ->
  let first = save base_path request in
  Masc.Keeper_fs.clear_dir_cache ();
  let source, recovered = S.read ~base_path ~id:first.id |> stored in
  Alcotest.(check string) "author is durable" "keeper-함께" source.author;
  check_request request recovered;
  let next = request_json (source_files @ ["later.json", "{\"changed\":true}"])
    |> A.request_of_json |> ok |> save base_path in
  Alcotest.(check bool) "new source has a new identity" false (first.id = next.id);
  let _, unchanged = S.read ~base_path ~id:first.id |> stored in
  check_request request unchanged;
  let maintain mode = Tool_blob_maintenance.run ~base_path
    ~board_posts_file:(fun ~workspace_masc_dir -> Filename.concat workspace_masc_dir "absent-board.json")
    ~mode |> Result.map_error Tool_blob_maintenance.error_to_string |> ok in
  let observation = maintain Tool_blob_maintenance.Observe_only in
  Alcotest.(check int) "shared source blobs are retention roots" 5 observation.live_references;
  ignore (maintain Tool_blob_maintenance.Delete_previous_candidates);
  ignore (maintain Tool_blob_maintenance.Observe_only);
  let swept = maintain Tool_blob_maintenance.Delete_previous_candidates in
  Alcotest.(check int) "retention preserves project files" 0 swept.deleted;
  let _, retained = S.read ~base_path ~id:first.id |> stored in
  check_request request retained;
  with_base (fun other -> match S.read ~base_path:other ~id:first.id with
    | Error S.Missing -> ()
    | _ -> Alcotest.fail "source crossed a workspace boundary"))
let test_package_script () = with_base (fun base_path ->
  let build = `Assoc ["kind", `String "package_script"; "script", `String "build:docs";
                      "output_directory", `String "dist/site"; "entry_html", `String "nested/index.html"] in
  let input = request_json ~build ["package.json", "{\"scripts\":{\"build:docs\":\"exit 87\"}}"] in
  let expected = A.request_of_json input |> ok in
  let source = save base_path expected in
  let _, actual = S.read ~base_path ~id:source.id |> stored in
  check_request expected actual)
let test_rejections () =
  let reject json = match A.request_of_json json with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid source contract accepted" in
  List.iter (fun path -> reject (request_json (source_files @ [path, "unsafe"])))
    ["../escape"; "/absolute"; "C:/drive"; "folder\\file"; "a//b"; "./file";
     "node_modules/a.js"; "dir/.git/config"; "nul\000file"; "broken\255"];
  reject (request_json (source_files @ ["index.html", "duplicate"]));
  reject (request_json (source_files @ ["parent", "file"; "parent/child", "nested"]));
  reject (request_json ["index.html", "no package"]);
  reject (request_json ["package.json", "no entry"]);
  (match request_json source_files with
   | `Assoc fields ->
     reject (`Assoc (("install_scripts", `Bool true) :: fields));
     reject (`Assoc (("unknown", `Null) :: fields));
     reject (`Assoc (List.remove_assoc "build" fields));
     List.iter (fun encoded -> reject (`Assoc (("files", `List [
       `Assoc ["path", `String "package.json"; "content_base64", `String encoded];
       `Assoc ["path", `String "index.html"; "content_base64", `String ""]])
       :: List.remove_assoc "files" fields))) ["e30"; "e30=\n"; "!!!!"; "Zh=="]
   | _ -> Alcotest.fail "fixture must be an object")
let test_damaged_files () = with_base (fun base_path ->
  let source = save base_path request in
  let file = List.hd source.files in
  let blob_root = Tool_blob_store.create ~base_path |> Tool_blob_store.root_dir in
  let blob = Filename.concat (Filename.concat blob_root (String.sub file.body.sha256 0 2)) file.body.sha256 in
  write blob "damaged";
  S.read ~base_path ~id:source.id |> unavailable;
  ignore (save base_path request);
  ignore (S.read ~base_path ~id:source.id |> stored);
  Unix.unlink blob;
  S.read ~base_path ~id:source.id |> unavailable;
  let outside = Filename.concat base_path "external-blob" in
  write outside "{}\n"; Unix.symlink outside blob;
  S.read ~base_path ~id:source.id |> unavailable)
let test_metadata_boundary () = with_base (fun base_path ->
  let source = save base_path request in
  let path = metadata base_path source.id in
  let original = In_channel.with_open_bin path In_channel.input_all in
  Unix.chmod path 0o644;
  S.read ~base_path ~id:source.id |> unavailable;
  Unix.chmod path 0o600;
  write path "{broken";
  S.read ~base_path ~id:source.id |> unavailable;
  let wrong = { source with id = "project-" ^ String.make 32 'b' } in
  write path (A.to_json wrong |> Yojson.Safe.to_string);
  S.read ~base_path ~id:source.id |> unavailable;
  write path original;
  Unix.unlink path;
  let outside = Filename.concat base_path "outside.json" in
  write outside original; Unix.symlink outside path;
  S.read ~base_path ~id:source.id |> unavailable)
let test_unsafe_directory () = with_base (fun base_path ->
  let source = save base_path request in
  let dir = Filename.dirname (metadata base_path source.id) in
  Unix.chmod dir 0o777;
  S.read ~base_path ~id:source.id |> unavailable;
  S.save ~base_path ~author:"human" request |> unavailable;
  Unix.chmod dir 0o700;
  let moved = Filename.concat base_path "moved" in
  Unix.rename dir moved; Unix.symlink moved dir;
  S.read ~base_path ~id:source.id |> unavailable;
  S.save ~base_path ~author:"human" request |> unavailable)
let test_manifest_references () = with_base (fun base_path ->
  let source = save base_path request in
  let file = List.hd source.files in
  let wrong_length = Tool_output.make_artifact_ref ~sha256:file.body.sha256
    ~bytes:(file.body.bytes + 1) ~preview:file.body.preview ~mime:file.body.mime
    |> Result.map_error Tool_output.make_error_to_string |> ok in
  let wrong = { source with files = { file with body = wrong_length } :: List.tl source.files } in
  write (metadata base_path source.id) (A.to_json wrong |> Yojson.Safe.to_string);
  S.read ~base_path ~id:source.id |> unavailable;
  let malformed = match A.to_json source with
    | `Assoc fields -> `Assoc (("files", `List [
        `Assoc ["path", `String "package.json"; "body", `Assoc ["_blob", `String "broken"]]])
        :: List.remove_assoc "files" fields)
    | _ -> Alcotest.fail "manifest must be an object" in
  (match A.of_json malformed with Error _ -> () | Ok _ -> Alcotest.fail "invalid blob wrapper accepted");
  write (metadata base_path source.id) (Yojson.Safe.to_string malformed);
  S.read ~base_path ~id:source.id |> unavailable;
  match Tool_blob_maintenance.run ~base_path
    ~board_posts_file:(fun ~workspace_masc_dir -> Filename.concat workspace_masc_dir "absent-board.json")
    ~mode:Tool_blob_maintenance.Delete_previous_candidates with
  | Error _ -> () | Ok _ -> Alcotest.fail "retention ignored a malformed owned reference")
let test_blob_parent_symlinks () =
  List.iter (fun shard -> with_base (fun base_path -> with_base (fun outside ->
    let masc = Common.masc_dir_from_base_path ~base_path in
    Unix.mkdir masc 0o700;
    let blobs = Filename.concat masc "tool_blobs" in
    let target = if shard then (
      Unix.mkdir blobs 0o700;
      let digest = Agent_core_sha256.(digest_string "{}\n" |> to_hex) in
      Filename.concat blobs (String.sub digest 0 2)) else blobs in
    Unix.symlink outside target;
    S.save ~base_path ~author:"human" request |> unavailable;
    Alcotest.(check int) "no source bytes written outside workspace" 0
      (Array.length (Sys.readdir outside));
    let metadata_dir = Filename.dirname (metadata base_path ("project-" ^ String.make 32 'a')) in
    Alcotest.(check bool) "no committed source metadata" false
      (Array.exists (fun name -> Filename.check_suffix name ".json") (Sys.readdir metadata_dir)))))
    [false; true]

let () = Eio_main.run (fun _ -> match Array.to_list Sys.argv with
  | [_; "--save"; base_path; input] ->
    let request = Yojson.Safe.from_file input |> A.request_of_json |> ok in
    let source = save base_path request in
    print_endline (A.to_json source |> Yojson.Safe.to_string)
  | [_; "--read"; base_path; id] ->
    let _, request = S.read ~base_path ~id |> stored in
    print_endline (A.request_to_json request |> Yojson.Safe.to_string)
  | _ -> Alcotest.run "artifact project source"
    ["durable import", [
      Alcotest.test_case "exact bytes, independent snapshots and retention" `Quick test_durable_source;
      Alcotest.test_case "package script selection survives without execution" `Quick test_package_script;
      Alcotest.test_case "invalid import contracts" `Quick test_rejections;
      Alcotest.test_case "corrupt, missing and symbolic-link blobs" `Quick test_damaged_files;
      Alcotest.test_case "private metadata, corruption, identity and symlinks" `Quick test_metadata_boundary;
      Alcotest.test_case "unsafe source directories" `Quick test_unsafe_directory;
      Alcotest.test_case "reference lengths, malformed metadata and retention" `Quick test_manifest_references;
      Alcotest.test_case "blob parent symlinks reject before writes" `Quick test_blob_parent_symlinks]])
