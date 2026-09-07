open Alcotest
module Installed = Masc.Installed_dashboard
let error = testable (fun fmt e -> Format.pp_print_string fmt (Yojson.Safe.to_string (Installed.error_json e))) ( = )
let commit = String.make 40 'a'
let sha body = Digestif.SHA256.(digest_string body |> to_hex)
let write path body =
  let ch = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out ch) (fun () -> output_string ch body)
let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path
let with_fixture ?(change_receipt = Fun.id) f =
  let temp = Filename.temp_file "installed dashboard spaces " "" in
  Unix.unlink temp; Unix.mkdir temp 0o700;
  Fun.protect ~finally:(fun () -> remove temp) (fun () ->
    let temp = Unix.realpath temp in
    let releases = Filename.concat temp ".masc-releases" in
    Unix.mkdir releases 0o700;
    let stage = Filename.concat releases "stage" in
    Unix.mkdir stage 0o700;
    let mkdir name = Unix.mkdir (Filename.concat stage name) 0o700 in
    mkdir "assets"; mkdir "assets/dashboard";
    let files = ["index.html", "<p>exact release</p>"; ".build-stamp", "2020-01-01T00:00:00Z\n"] in
    List.iter (fun (name, body) -> write (Filename.concat stage ("assets/dashboard/" ^ name)) body) files;
    write (Filename.concat stage "masc") "fixture binary";
    Unix.chmod (Filename.concat stage "masc") 0o755;
    let receipt = `Assoc ["schema", `String "masc.installed-release.v1";
      "source_commit", `String commit; "binary_asset", `String "masc-linux-x64";
      "binary_sha256", `String (sha "fixture binary");
      "files", `List (List.map (fun (path, body) -> `Assoc ["path", `String path;
        "sha256", `String (sha body); "size", `Int (String.length body); "mtime", `Float 1577836800.]) files)] in
    let body = Yojson.Safe.to_string (change_receipt receipt) in
    write (Filename.concat stage "release.json") body;
    let root = Filename.concat releases (sha body) in
    Unix.rename stage root;
    let binary = Filename.concat root "masc" in
    let pointer = Filename.concat temp "masc" in
    Unix.symlink binary pointer;
    f temp root binary pointer)
let inspect binary = Installed.inspect ~executable_path:binary ~binary_commit:(Some commit)
let bound binary = match inspect binary with
  | Installed.Bound b -> b
  | state -> fail (Yojson.Safe.to_string (Installed.evidence state))
let unavailable = function Installed.Unavailable _ -> true | _ -> false
let test_exact_release () = with_fixture (fun _ root binary _ ->
  let b = bound binary in
  check (result string error) "exact bytes" (Ok "<p>exact release</p>") (Installed.load b "index.html");
  check string "assets root" (Filename.concat root "assets") (Installed.assets_root b);
  Unix.utimes (Filename.concat root "assets/dashboard/.build-stamp") 1577836800. 1577836800.;
  check bool "old stamp does not break exact receipt" true (Result.is_ok (Installed.load b ".build-stamp")))
let test_pointer_switch () = with_fixture (fun temp _ binary pointer ->
  let b = bound (Unix.realpath pointer) in
  Unix.unlink pointer;
  let other = Filename.concat temp "other" in write other "other release";
  Unix.symlink other pointer;
  check (result string error) "running release stays bound" (Ok "<p>exact release</p>") (Installed.load b "index.html");
  check bool "original binary still exists" true (Sys.file_exists binary))
let test_receipt_removed () = with_fixture (fun _ root binary _ ->
  let b = bound binary in
  Unix.unlink (Filename.concat root "release.json");
  check bool "existing binding fails closed" true (Result.is_error (Installed.load b "index.html"));
  check bool "new selection never becomes unbound" true (unavailable (inspect binary)))
let test_asset_corruption () = with_fixture (fun _ root binary _ ->
  let b = bound binary in
  write (Filename.concat root "assets/dashboard/index.html") "<p>wrong release</p>";
  check bool "request rejects changed digest" true (Result.is_error (Installed.load b "index.html"));
  check bool "startup validates all assets" true (unavailable (inspect binary)))
let test_asset_symlink () = with_fixture (fun temp root binary _ ->
  let b = bound binary in
  let outside = Filename.concat temp "outside" in write outside "<p>exact release</p>";
  let index = Filename.concat root "assets/dashboard/index.html" in
  Unix.unlink index; Unix.symlink outside index;
  check bool "same bytes through link denied" true (Result.is_error (Installed.load b "index.html")))
let test_binary_replaced () = with_fixture (fun _ root binary _ ->
  let b = bound binary in
  let next = Filename.concat root "replacement" in write next "fixture binary"; Unix.chmod next 0o755;
  Unix.rename next binary;
  check bool "same bytes different binary inode denied" true (Result.is_error (Installed.load b "index.html")))
let test_wrong_commit () = with_fixture (fun _ _ binary _ ->
  let state = Installed.inspect ~executable_path:binary ~binary_commit:(Some (String.make 40 'b')) in
  check bool "embedded commit mismatch" true (match state with
    | Installed.Unavailable (Installed.Binary_commit_mismatch _) -> true | _ -> false);
  check bool "no cwd commit fallback" true (match Installed.inspect ~executable_path:binary ~binary_commit:None with
    | Installed.Unavailable Installed.Binary_commit_unavailable -> true | _ -> false))
let test_wrong_binary () = with_fixture (fun _ _ binary _ ->
  write binary "different binary";
  check bool "binary digest mismatch" true (match inspect binary with
    | Installed.Unavailable (Installed.Digest_mismatch _) -> true | _ -> false))
let test_traversal () =
  let change_receipt = function
    | `Assoc fields -> `Assoc (List.map (function
        | "files", `List (`Assoc entry :: rest) ->
          "files", `List (`Assoc (("path", `String "../escape") :: List.remove_assoc "path" entry) :: rest)
        | field -> field) fields)
    | json -> json in
  with_fixture ~change_receipt (fun _ _ binary _ ->
    check bool "untrusted path rejected" true (match inspect binary with
      | Installed.Unavailable Installed.Invalid_receipt -> true | _ -> false))
let test_duplicate_fields () =
  with_fixture ~change_receipt:(function `Assoc fields -> `Assoc (("schema", `String "masc.installed-release.v1") :: fields) | json -> json)
    (fun _ _ binary _ -> check bool "duplicate fields rejected" true (match inspect binary with
      | Installed.Unavailable Installed.Invalid_receipt -> true | _ -> false))
let test_receipt_identity () = with_fixture (fun _ root binary _ ->
  let path = Filename.concat root "release.json" in
  let ch = open_out_gen [Open_append; Open_text] 0o600 path in output_char ch '\n'; close_out ch;
  check bool "receipt hash is directory identity" true (match inspect binary with
    | Installed.Unavailable Installed.Receipt_identity_mismatch -> true | _ -> false))
let test_unknown_asset () = with_fixture (fun _ _ binary _ ->
  check bool "unlisted asset is 404 category" true (match Installed.load (bound binary) "../masc" with
    | Error Installed.Not_manifested -> true | _ -> false))
let test_developer_binary () =
  check bool "ordinary binary remains source/unbound authority" true (match
    Installed.inspect ~executable_path:"/tmp/checkout/_build/default/bin/main_eio.exe" ~binary_commit:None with
    | Installed.Not_installed -> true | _ -> false)
let test_authority_precedence () = with_fixture (fun _ root binary _ ->
  let installed = Installed.Bound (bound binary) in
  let select state = Masc.Web_dashboard.For_testing.select_installed_authority
      ~launch_source_root_state:state ~installed in
  check bool "unbound selects installed" true (match select Masc.Build_identity.Unbound with
    | Installed.Bound _ -> true | _ -> false);
  List.iter (fun state -> check bool "explicit source remains authoritative" true
    (match select state with Installed.Not_installed -> true | _ -> false))
    [Masc.Build_identity.Bound_valid root;
     Masc.Build_identity.Bound_invalid Masc.Build_identity.Source_root_inode_differs])
let replace_entry_field key value = function
  | `Assoc fields -> `Assoc (List.map (function
      | "files", `List files -> "files", `List (List.map (function
          | `Assoc entry -> `Assoc ((key, value) :: List.remove_assoc key entry)
          | json -> json) files)
      | field -> field) fields)
  | json -> json
let test_invalid_numeric_receipt () =
  List.iter (fun (name, key, value) ->
    with_fixture ~change_receipt:(replace_entry_field key value) (fun _ _ binary _ ->
      check bool name true (match inspect binary with
        | Installed.Unavailable Installed.Invalid_receipt -> true | _ -> false)))
    ["finite outside civil-time range", "mtime", `Float 1e308;
     (* Intlit writes verbatim wire tokens here. The malformed tokens must
        reach the receipt parser; the standard Float writer rejects them
        while constructing the fixture, before the boundary under test. *)
     "timestamp NaN", "mtime", `Intlit "NaN";
     "timestamp positive infinity", "mtime", `Intlit "Infinity";
     "timestamp negative infinity", "mtime", `Intlit "-Infinity";
     "timestamp exponent overflow", "mtime", `Intlit "1e999";
     "negative timestamp", "mtime", `Int (-1);
     "timestamp string", "mtime", `String "1577836800";
     "timestamp null", "mtime", `Null;
     "timestamp boolean", "mtime", `Bool true;
     "timestamp int outside OCaml int", "mtime", `Intlit "999999999999999999999999999999";
     "size negative", "size", `Int (-1);
     "size float", "size", `Float 1.;
     "size string", "size", `String "1";
     "size boolean", "size", `Bool true]
let test_civil_time_boundaries () =
  let last_second = Ptime.to_float_s (Ptime.truncate ~frac_s:0 Ptime.max) in
  List.iter (fun value -> with_fixture ~change_receipt:(replace_entry_field "mtime" (`Float value))
    (fun _ _ binary _ ->
      let b = bound binary in
      check (option (float 0.)) "valid boundary retained" (Some value) (Installed.build_stamp_mtime b);
      check bool "health timestamp renders" true (String.length (Time_codec.rfc3339_of_unix value) > 0)))
    [0.; last_second];
  with_fixture ~change_receipt:(replace_entry_field "mtime" (`Float (last_second +. 1.)))
    (fun _ _ binary _ -> check bool "next civil year rejected" true (match inspect binary with
      | Installed.Unavailable Installed.Invalid_receipt -> true | _ -> false))
let test_read_only_install () = with_fixture (fun _ root binary _ ->
  let files = ["release.json"; "assets/dashboard/index.html"; "assets/dashboard/.build-stamp"] in
  let dirs = [root; Filename.concat root "assets"; Filename.concat root "assets/dashboard"] in
  Fun.protect ~finally:(fun () -> List.iter (fun dir -> Unix.chmod dir 0o700) dirs)
    (fun () ->
      List.iter (fun file -> Unix.chmod (Filename.concat root file) 0o444) files;
      Unix.chmod binary 0o555;
      List.iter (fun dir -> Unix.chmod dir 0o555) dirs;
      check (result string error) "read-only installed release serves" (Ok "<p>exact release</p>")
        (Installed.load (bound binary) "index.html")))
let () = run "Installed dashboard authority" ["distribution", List.map (fun (name, test) -> test_case name `Quick test)
  ["malformed numeric fields", test_invalid_numeric_receipt;
   "civil-time boundaries", test_civil_time_boundaries;
   "read-only installed files", test_read_only_install;
   "source authority precedence", test_authority_precedence;
   "exact release and original timestamp", test_exact_release;
   "pointer switch", test_pointer_switch; "receipt removed", test_receipt_removed;
   "asset corruption", test_asset_corruption; "asset symlink", test_asset_symlink;
   "binary replacement", test_binary_replaced; "embedded commit", test_wrong_commit;
   "binary digest", test_wrong_binary; "traversal", test_traversal;
   "duplicate fields", test_duplicate_fields; "receipt identity", test_receipt_identity;
   "unmanifested request", test_unknown_asset; "developer binary", test_developer_binary]]
