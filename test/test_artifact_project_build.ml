module A = Masc.Artifact_project_build
module S = Masc.Artifact_project_build_store
module Source = Masc.Artifact_project_source
module Sources = Masc.Artifact_project_source_store
let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored = function Ok value -> value | Error error -> Alcotest.fail (S.error_message error)
let source_ok = function Ok value -> value | Error error -> Alcotest.fail (Sources.error_message error)
let unavailable = function Error (S.Unavailable _) -> () | Error error -> Alcotest.fail (S.error_message error)
  | Ok _ -> Alcotest.fail "damaged or unsafe build accepted"
let invalid = function Error (S.Invalid _) -> () | Error error -> Alcotest.fail (S.error_message error)
  | Ok _ -> Alcotest.fail "build associated with a different source"
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let with_base f =
  let base = Filename.temp_file "artifact-project-build-" "" in Sys.remove base; Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
let digest text = Agent_core_sha256.(digest_string text |> to_hex)
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let metadata base id = Filename.concat
  (Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "artifact_project_builds") (id ^ ".json")
let fields = function `Assoc fields -> fields | _ -> Alcotest.fail "fixture must be an object"
let replace key value json = `Assoc ((key, value) :: List.remove_assoc key (fields json))
let member key json = List.assoc key (fields json)
let index = "\239\187\191<!doctype html><p>원본 😀</p>\r\n"
let source_files = ["package.json", "{}\n"; "index.html", index]
let browser = `Assoc ["kind", `String "browser_modules"; "entry_html", `String "index.html"]
let package = `Assoc ["kind", `String "package_script"; "script", `String "build";
                      "output_directory", `String "dist"; "entry_html", `String "nested/index.html"]
let source_request build files = `Assoc ["schema", `String "masc.artifact_project.v1";
  "build", build; "install_scripts", `Bool false; "files", `List (List.map (fun (path, content) ->
    `Assoc ["path", `String path; "content_base64", `String (Base64.encode_string content)]) files)]
let save_source base build files = source_request build files |> Source.request_of_json |> ok
  |> Sources.save ~base_path:base ~author:"human" |> source_ok
let install lock_source lockfile content = `Assoc ["mode", `String "ci"; "lock_source", `String lock_source;
  "scripts", `Bool false; "lockfile", `String lockfile; "lock_content", `String content; "lock_sha256", `String (digest content)]
let compiled_html = index ^ "<!-- generated output -->"
let html = `Assoc ["kind", `String "html"; "artifact", `Assoc ["format", `String "html";
  "content", `String compiled_html; "sha256", `String (digest compiled_html)]]
let browser_result = `Assoc ["kind", `String "browser_modules"; "entry_html", `String "index.html"; "esbuild", `String "fixture";
  "inputs", `List []; "warnings", `List []; "external_resources", `List []]
let result build output files = `Assoc ["schema", `String "masc.artifact_project_result.v1";
  "runtime", `Assoc ["node", `String "fixture"; "platform", `String "fixture"; "arch", `String "fixture"];
  "run_directory", `String "/never-read-by-store";
  "source_files", `List (List.map (fun (path, content) -> `Assoc ["path", `String path; "sha256", `String (digest content)]) files);
  "install", install "resolved" "package-lock.json" "{\"lockfileVersion\":3,\"packages\":{}}"; "build", build; "output", output]
let input json = A.input_of_json json |> ok
let save base source json = S.save ~base_path:base ~source_id:source.Source.id ~author:"keeper" (input json) |> stored
let check_result expected actual = Alcotest.(check string) "worker result restored exactly"
  (A.input_to_json (input expected) |> Yojson.Safe.to_string) (A.input_to_json actual |> Yojson.Safe.to_string)
let site_files = ["assets/pixel.bin", "\000\255\128";
  "assets/한글\"줄\n\u{2028}.css", "body{color:red}"; "empty.txt", "";
  "nested/index.html", "<!doctype html><p>빌드 결과 😀</p>\r\n"]
(* Actual Node JSON.stringify manifest digest, computed independently of Yojson. *)
let site = `Assoc ["kind", `String "site"; "entry_html", `String "nested/index.html";
  "sha256", `String "449efcab56404416583b540fc227dd2d16981d241b026cdb201b0a9f6504fe6b";
  "files", `List (List.map (fun (path, content) -> `Assoc ["path", `String path;
    "bytes", `Int (String.length content); "sha256", `String (digest content);
    "content_base64", `String (Base64.encode_string content)]) site_files)]
let test_html_retention () = with_base (fun base_path ->
  let source = save_source base_path browser source_files in
  let expected = result browser_result html source_files in
  let first = save base_path source expected in
  let second = save base_path source expected in
  Alcotest.(check bool) "new build has independent immutable identity" false (first.id = second.id);
  let _, file = S.read_file ~base_path ~id:first.id ~path:None |> stored in
  Alcotest.(check string) "HTML filename" "index.html" file.path;
  Alcotest.(check string) "HTML BOM/CRLF preserved" compiled_html file.content;
  check_result expected (S.restore ~base_path ~id:first.id |> stored);
  let maintenance mode = Tool_blob_maintenance.run ~base_path
    ~board_posts_file:(fun ~workspace_masc_dir -> Filename.concat workspace_masc_dir "absent-board.json") ~mode
    |> Result.map_error Tool_blob_maintenance.error_to_string |> ok in
  let observed = maintenance Tool_blob_maintenance.Observe_only in
  Alcotest.(check int) "generated HTML and resolved lock have independent retention roots" 4 observed.live_references;
  ignore (maintenance Tool_blob_maintenance.Delete_previous_candidates);
  ignore (maintenance Tool_blob_maintenance.Observe_only);
  let swept = maintenance Tool_blob_maintenance.Delete_previous_candidates in
  Alcotest.(check int) "source, lock and HTML retained" 0 swept.deleted;
  check_result expected (S.restore ~base_path ~id:first.id |> stored);
  with_base (fun other -> match S.read ~base_path:other ~id:first.id with
    | Error S.Missing -> () | _ -> Alcotest.fail "build crossed workspace"))
let test_site_graph () = with_base (fun base_path ->
  let source = save_source base_path package source_files in
  let expected = result package site source_files in
  let build = save base_path source expected in
  List.iter (fun (path, content) ->
    let _, file = S.read_file ~base_path ~id:build.id ~path:(Some path) |> stored in
    Alcotest.(check string) "exact graph path" path file.path;
    Alcotest.(check string) "exact graph bytes" content file.content) site_files;
  let _, entry = S.read_file ~base_path ~id:build.id ~path:None |> stored in
  Alcotest.(check string) "nested HTML entry" "nested/index.html" entry.path;
  check_result expected (S.restore ~base_path ~id:build.id |> stored);
  let maintenance mode = Tool_blob_maintenance.run ~base_path
    ~board_posts_file:(fun ~workspace_masc_dir -> Filename.concat workspace_masc_dir "absent-board.json") ~mode
    |> Result.map_error Tool_blob_maintenance.error_to_string |> ok in
  let observed = maintenance Tool_blob_maintenance.Observe_only in
  Alcotest.(check int) "site files and lock outlive source-only references" 7 observed.live_references;
  ignore (maintenance Tool_blob_maintenance.Delete_previous_candidates);
  ignore (maintenance Tool_blob_maintenance.Observe_only);
  ignore (maintenance Tool_blob_maintenance.Delete_previous_candidates);
  check_result expected (S.restore ~base_path ~id:build.id |> stored);
  (match S.read_file ~base_path ~id:build.id ~path:(Some "../escape") with
   | Error (S.Invalid _) -> () | _ -> Alcotest.fail "traversal path accepted");
  (match S.read_file ~base_path ~id:build.id ~path:(Some "missing.js") with
   | Error S.Missing -> () | _ -> Alcotest.fail "missing file is not typed"))
let test_association () = with_base (fun base_path ->
  let source = save_source base_path browser source_files in
  let expected = result browser_result html source_files in
  let attempt json = S.save ~base_path ~source_id:source.id ~author:"human" (input json) |> invalid in
  attempt (replace "source_files" (`List []) expected);
  attempt (replace "install" (replace "scripts" (`Bool true) (member "install" expected)) expected);
  attempt (replace "install" (install "supplied" "package-lock.json" "{}\n") expected);
  let package_result = result package site source_files in
  attempt package_result;
  Alcotest.(check bool) "refusal precedes build directory publication" false
    (Sys.file_exists (Filename.dirname (metadata base_path ("build-" ^ String.make 32 'a')))))
let test_supplied_lock () = with_base (fun base_path ->
  let files = source_files @ ["package-lock.json", "{\"package\":true}"; "npm-shrinkwrap.json", "{\"shrinkwrap\":true}"] in
  let source = save_source base_path browser files in
  let expected = result browser_result html files
    |> replace "install" (install "supplied" "npm-shrinkwrap.json" "{\"shrinkwrap\":true}") in
  let build = save base_path source expected in
  check_result expected (S.restore ~base_path ~id:build.id |> stored);
  let attempt lock = S.save ~base_path ~source_id:source.id ~author:"human"
    (replace "install" lock expected |> input) |> invalid in
  attempt (install "supplied" "package-lock.json" "{\"package\":true}");
  attempt (install "supplied" "npm-shrinkwrap.json" "{\"changed\":true}");
  attempt (install "resolved" "package-lock.json" "{}"))
let test_strict_results () =
  let expected = result package site source_files in
  let reject json = match A.input_of_json json with Error _ -> () | Ok _ -> Alcotest.fail "invalid worker result accepted" in
  reject (`Assoc (("output", html) :: fields expected));
  reject (replace "extra" `Null expected);
  reject (replace "output" html expected);
  reject (replace "output" (replace "sha256" (`String (String.make 64 '0')) site) expected);
  reject (replace "install" (replace "lock_sha256" (`String (String.make 64 '0')) (member "install" expected)) expected);
  let files = match member "files" site with `List files -> files | _ -> Alcotest.fail "files" in
  List.iter (fun file -> reject (replace "output" (replace "files" (`List (file :: List.tl files)) site) expected))
    [replace "path" (`String "../escape") (List.hd files);
     replace "bytes" (`Int (-1)) (List.hd files);
     replace "content_base64" (`String "YQ") (List.hd files);
     replace "sha256" (`String (String.make 64 '0')) (List.hd files)]
let test_corruption () = with_base (fun base_path ->
  let source = save_source base_path package source_files in
  let build = save base_path source (result package site source_files) in
  let _, file = S.read_file ~base_path ~id:build.id ~path:(Some "assets/pixel.bin") |> stored in
  let root = Tool_blob_store.create ~base_path |> Tool_blob_store.root_dir in
  let blob = Filename.concat (Filename.concat root (String.sub file.body.sha256 0 2)) file.body.sha256 in
  write blob "corrupt";
  S.read_file ~base_path ~id:build.id ~path:(Some file.path) |> unavailable;
  S.restore ~base_path ~id:build.id |> unavailable;
  let path = metadata base_path build.id in
  Unix.chmod path 0o644; S.read ~base_path ~id:build.id |> unavailable;
  Unix.chmod path 0o600; write path "{broken"; S.read ~base_path ~id:build.id |> unavailable)
let test_unsafe_metadata () = with_base (fun base_path ->
  let source = save_source base_path browser source_files in
  let build = save base_path source (result browser_result html source_files) in
  let path = metadata base_path build.id in
  let original = In_channel.with_open_bin path In_channel.input_all in
  Unix.unlink path;
  let outside = Filename.concat base_path "external.json" in write outside original; Unix.symlink outside path;
  S.read ~base_path ~id:build.id |> unavailable;
  let directory = Filename.dirname path in
  Unix.chmod directory 0o777;
  S.save ~base_path ~source_id:source.id ~author:"keeper" (input (result browser_result html source_files)) |> unavailable;
  Unix.chmod directory 0o700)
let test_entry_selection () = with_base (fun base_path ->
  let files = ["package.json", "{}"; "a.html", "<p>A</p>"; "b.html", "<p>B</p>"] in
  let entry path = replace "entry_html" (`String path) browser in
  let a = save_source base_path (entry "a.html") files in
  let b = save_source base_path (entry "b.html") files in
  let selection = replace "entry_html" (`String "a.html") browser_result in
  let output = replace "artifact" (`Assoc ["format", `String "html"; "content", `String "<p>A</p>";
    "sha256", `String (digest "<p>A</p>")]) html in
  let expected = result selection output files in
  S.save ~base_path ~source_id:b.id ~author:"keeper" (input expected) |> invalid;
  Alcotest.(check bool) "cross-entry refusal precedes metadata directory creation" false
    (Sys.file_exists (Filename.dirname (metadata base_path ("build-" ^ String.make 32 'a'))));
  let saved = save base_path a expected in
  check_result expected (S.restore ~base_path ~id:saved.id |> stored);
  let json = A.to_json saved |> replace "source_id" (`String b.id) in
  write (metadata base_path saved.id) (Yojson.Safe.to_string json);
  S.read ~base_path ~id:saved.id |> unavailable;
  S.restore ~base_path ~id:saved.id |> unavailable;
  S.read_file ~base_path ~id:saved.id ~path:(Some "b.html") |> unavailable;
  let absent = result (`Assoc (List.remove_assoc "entry_html" (fields browser_result))) html source_files in
  match A.input_of_json absent with Error _ -> () | Ok _ -> Alcotest.fail "selected entry is required")

let () = Eio_main.run (fun _ -> match Array.to_list Sys.argv with
  | [_; "--save"; base_path; source_id; input_path] ->
    let build = Yojson.Safe.from_file input_path |> input |> S.save ~base_path ~source_id ~author:"qa-keeper" |> stored in
    print_endline (A.to_json build |> Yojson.Safe.to_string)
  | [_; "--restore"; base_path; id] -> S.restore ~base_path ~id |> stored |> A.input_to_json |> Yojson.Safe.to_string |> print_endline
  | [_; "--read-file"; base_path; id; path; destination] ->
    let _, file = S.read_file ~base_path ~id ~path:(Some path) |> stored in write destination file.content
  | _ -> Alcotest.run "artifact project build" ["retained builds", [
    Alcotest.test_case "HTML, immutable records and offline retention" `Quick test_html_retention;
    Alcotest.test_case "site graph, Unicode JSON digest and exact paths" `Quick test_site_graph;
    Alcotest.test_case "source and install/build association before publication" `Quick test_association;
    Alcotest.test_case "supplied lock and shrinkwrap precedence" `Quick test_supplied_lock;
    Alcotest.test_case "closed worker result and payload integrity" `Quick test_strict_results;
    Alcotest.test_case "payload and metadata corruption" `Quick test_corruption;
    Alcotest.test_case "unsafe metadata paths" `Quick test_unsafe_metadata;
    Alcotest.test_case "browser entry selection binds save and all readers" `Quick test_entry_selection]])
