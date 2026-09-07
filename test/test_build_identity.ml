open Masc

let test_resolve_commit_prefers_embedded () =
  let probe_called = ref false in
  let commit =
    Build_identity.resolve_commit
      ~embedded:(Some " feed0123 ")
      ~probe:(fun () ->
        probe_called := true;
        Some "deadbeef")
  in
  Alcotest.(check (option string)) "embedded wins" (Some "feed0123") commit;
  Alcotest.(check bool) "probe not called" false !probe_called

let test_resolve_commit_uses_probe_when_embedded_missing () =
  let commit =
    Build_identity.resolve_commit
      ~embedded:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "probe used" (Some "deadbeef") commit

let test_resolve_commit_details_prefers_embedded_binary () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some " feed0123 ")
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "binary commit is embedded"
    (Some "feed0123") details.binary_commit;
  Alcotest.(check (option string)) "binary source is embedded"
    (Some "embedded") details.binary_commit_source;
  Alcotest.(check (option string)) "compat commit uses embedded"
    (Some "feed0123") details.commit;
  Alcotest.(check (option string)) "commit source is embedded"
    (Some "embedded") details.commit_source;
  Alcotest.(check (option string)) "repo head still surfaced"
    (Some "deadbeef") details.repo_head_commit

let test_resolve_commit_details_marks_repo_head_fallback () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:None
      ~probe:(fun () -> Some "deadbeef")
  in
  Alcotest.(check (option string)) "compat commit falls back to repo head"
    (Some "deadbeef") details.commit;
  Alcotest.(check (option string)) "commit source is repo head"
    (Some "runtime_repo_head") details.commit_source;
  Alcotest.(check (option string)) "binary commit absent" None
    details.binary_commit;
  Alcotest.(check (option string)) "repo head commit present"
    (Some "deadbeef") details.repo_head_commit;
  Alcotest.(check (option string)) "repo head source"
    (Some "runtime_repo_head") details.repo_head_commit_source

let test_binary_identity_ignores_mismatched_ambient_checkout () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some "canary-build-source")
      ~probe:(fun () -> Some "ambient-checkout-head")
  in
  Alcotest.(check (option string))
    "canary identity remains its build source"
    (Some "canary-build-source")
    details.binary_commit;
  Alcotest.(check (option string))
    "ambient checkout remains separately observable"
    (Some "ambient-checkout-head")
    details.repo_head_commit

let test_binary_identity_survives_without_checkout () =
  let details =
    Build_identity.resolve_commit_details
      ~embedded:(Some "packaged-canary-source")
      ~probe:(fun () -> None)
  in
  Alcotest.(check (option string))
    "packaged canary keeps its build source"
    (Some "packaged-canary-source")
    details.binary_commit;
  Alcotest.(check (option string)) "no ambient checkout" None details.repo_head_commit

let test_current_started_at_is_stable () =
  let first = Build_identity.current () in
  Unix.sleepf 0.01;
  let second = Build_identity.current () in
  Alcotest.(check string) "stable started_at" first.started_at second.started_at;
  Alcotest.(check string)
    "stable runtime instance id"
    first.runtime_instance_id
    second.runtime_instance_id;
  Alcotest.(check bool)
    "runtime instance id has canonical UUID width"
    true
    (String.length first.runtime_instance_id = 36);
  Alcotest.(check bool) "uptime monotonic" true
    (second.uptime_seconds >= first.uptime_seconds)

let test_runtime_cwd_is_resolver_backed_snapshot () =
  let cwd = Build_identity.For_testing.runtime_cwd () in
  Alcotest.(check bool) "cwd snapshot populated" true (String.length cwd > 0);
  Alcotest.(check bool) "cwd snapshot absolute" true (not (Filename.is_relative cwd))

(* A direct _build launch reported no executable identity at all: the four
   --build-provenance-* arguments come from run-local.sh, and without them
   every field was left None, which the derived serializer omits entirely.
   /health?full=1 then had no executable_sha256 key to read and the live-proof
   runbook stopped before it began.

   The test process is itself a direct launch, so this is that case. *)
(* current () runs on every TUI render frame. When the self-hash was not
   memoised it read and digested the whole 60 MB executable each time, and the
   TUI sat at 88% of a core with sha256_do_chunk on top of the sample. *)
let test_repeated_current_does_not_rehash_the_executable () =
  let first = Build_identity.current () in
  let started = Unix.gettimeofday () in
  let repeats = 200 in
  for _ = 1 to repeats do
    ignore (Build_identity.current ())
  done
  ;
  let elapsed = Unix.gettimeofday () -. started in
  Alcotest.(check bool) "the digest is stable across calls" true
    (String.equal
       (Option.value first.Build_identity.executable_sha256 ~default:"")
       (Option.value
          (Build_identity.current ()).Build_identity.executable_sha256
          ~default:""));
  (* A re-read of this executable costs tens of milliseconds; 200 of them
     could not finish in a second. The bound is loose on purpose -- it is
     here to catch a rehash, not to pin a machine's speed. *)
  Alcotest.(check bool)
    (Printf.sprintf "%d calls stay cheap (%.3fs)" repeats elapsed)
    true
    (elapsed < 1.0)

(* `masc start` from the masc checkout produced five of these at every boot:

     build_identity: Unix.realpath failed for
       /Users/dancer/me/workspace/yousleepwhen/masc/masc

   argv0 is "masc", which is relative -- but relative to PATH, not to the cwd,
   so joining it to the cwd names a file that does not exist. The cost is not
   the warning: executable_dir then equals cwd, pick_repo_candidates collapses
   to one entry, and the repo probe answers with whatever checkout the process
   was started from. *)
let test_bare_argv0_is_not_resolved_against_the_cwd () =
  Alcotest.(check string)
    "a PATH launch answers the runtime's own resolution"
    "/opt/homebrew/bin/masc"
    (Build_identity.executable_candidate
       ~cwd:"/Users/dancer/me/workspace/yousleepwhen/masc"
       ~executable_name:"/opt/homebrew/bin/masc"
       ~argv0:"masc")

let test_argv0_with_a_directory_is_still_cwd_relative () =
  Alcotest.(check string)
    "./_build/... keeps resolving against the cwd"
    "/repo/_build/default/bin/main_eio.exe"
    (Build_identity.executable_candidate
       ~cwd:"/repo"
       ~executable_name:"_build/default/bin/main_eio.exe"
       ~argv0:"_build/default/bin/main_eio.exe")

let test_bare_names_everywhere_do_not_invent_a_path () =
  (* Neither name can be resolved without a PATH search. Answering the name is
     honest; answering cwd/name is a file that is not there. *)
  Alcotest.(check string)
    "no cwd-joined guess"
    "masc"
    (Build_identity.executable_candidate ~cwd:"/repo" ~executable_name:"masc" ~argv0:"masc")

let test_direct_launch_still_identifies_its_executable () =
  let current = Build_identity.current () in
  let json = Build_identity.to_yojson current in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "the identity says nobody verified it"
    "self_observed"
    (json |> member "provenance_source" |> to_string);
  (match json |> member "executable_sha256" with
   | `String digest ->
     Alcotest.(check int) "and carries a real sha256" 64 (String.length digest);
     Alcotest.(check bool) "made of hex" true
       (String.for_all
          (fun c ->
            (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
          digest)
   | other ->
     Alcotest.failf "a readable executable produced no hash: %s"
       (Yojson.Safe.to_string other));
  (* The launcher's number is the one the binary cannot invent, so it stays
     absent rather than being filled with something that looks like it. *)
  Alcotest.(check bool) "the build-input fingerprint is not invented" true
    (match json |> member "source_fingerprint" with
     | `Null -> true
     | _ -> false)

let test_current_json_exposes_runtime_binary_identity () =
  let current = Build_identity.current () in
  let json = Build_identity.to_yojson current in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "binary version populated" true
    (String.length (json |> member "binary_version" |> to_string) > 0);
  Alcotest.(check bool) "repo version field present" true
    (match json |> member "repo_version" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "commit source field present" true
    (match json |> member "commit_source" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "binary commit field present" true
    (match json |> member "binary_commit" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "source fingerprint field present" true
    (match json |> member "source_fingerprint" with
     | `Null | `String _ -> true
     | _ -> false);
  Alcotest.(check bool) "executable sha256 field present" true
    (match json |> member "executable_sha256" with
     | `Null | `String _ -> true
     | _ -> false);
  Alcotest.(check bool) "provenance path field present" true
    (match json |> member "executable_provenance_path" with
     | `Null | `String _ -> true
     | _ -> false);
  Alcotest.(check bool) "provenance digest field present" true
    (match json |> member "executable_provenance_sha256" with
     | `Null | `String _ -> true
     | _ -> false);
  Alcotest.(check bool) "repo head commit field present" true
    (match json |> member "repo_head_commit" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check bool) "executable path populated" true
    (String.length (json |> member "executable_path" |> to_string) > 0);
  Alcotest.(check bool) "executable dir populated" true
    (String.length (json |> member "executable_dir" |> to_string) > 0);
  Alcotest.(check bool) "repo_root field present" true
    (match json |> member "repo_root" with `Null | `String _ -> true | _ -> false);
  Alcotest.(check string)
    "runtime instance id projected"
    current.runtime_instance_id
    (json |> member "runtime_instance_id" |> to_string)

let fixture_dashboard_tree_sha256 () =
  let digest = String.make 64 'd' in
  Printf.sprintf {|[{"path":"index.html","sha256":"%s","size":9}]|} digest
  |> fun value -> Digestif.SHA256.(digest_string value |> to_hex)
;;

let executable_provenance_json
      ?(extra = [])
      ?source_root
      ?dashboard_snapshot_root
      ?(executable_inode = 2)
      ~commit
      ~fingerprint
      ~sha256
      ()
  =
  let source_root =
    Option.value ~default:(Sys.getcwd ()) source_root |> Unix.realpath
  in
  let source_root_stat = Unix.stat source_root in
  let dashboard_snapshot_root =
    Option.value ~default:source_root dashboard_snapshot_root |> Unix.realpath
  in
  let dashboard_snapshot_stat = Unix.stat dashboard_snapshot_root in
  let dashboard_asset_sha256 = String.make 64 'd' in
  let dashboard_tree_sha256 = fixture_dashboard_tree_sha256 () in
  let dashboard_assets =
    let build_receipt =
      `Assoc
        [ "schema", `String "masc.run-local-dashboard-build.v1"
        ; "producer", `String "scripts/build-dashboard-if-needed.sh --prepare-exact + --build-exact"
        ; "source_root", `String source_root
        ; "source_root_device", `Int source_root_stat.st_dev
        ; "source_root_inode", `Int source_root_stat.st_ino
        ; "source_commit", `String commit
        ; "head_tree", `String (String.make 40 'f')
        ; "index_tree", `String (String.make 40 'e')
        ; "input_sha256", `String (String.make 64 'a')
        ; "input_file_count", `Int 12
        ; "input_matches_head", `Bool true
        ; "lock_sha256", `String (String.make 64 'b')
        ; "build_mode", `String "production"
        ; "environment_path", `String "/verified"
        ; "environment_path_identity_sha256", `String (String.make 64 '4')
        ; "environment_path_executable_sha256", `String (String.make 64 '5')
        ; "environment_path_executable_count", `Int 73
        ; "environment_profile_sha256", `String (String.make 64 'c')
        ; "node_executable", `String "/verified/node"
        ; "node_executable_sha256", `String (String.make 64 '1')
        ; "node_version", `String "v24.0.0"
        ; "node_platform", `String "darwin"
        ; "node_arch", `String "arm64"
        ; "package_manager_kind", `String "pnpm"
        ; "package_manager_executable", `String "/verified/pnpm"
        ; "package_manager_executable_sha256", `String (String.make 64 '2')
        ; "pnpm_version", `String "10.0.0"
        ; "vite_version", `String "7.0.0"
        ; "installed_graph_metadata_sha256", `String (String.make 64 '3')
        ; "installed_graph_metadata_count", `Int 42
        ; "output_tree_sha256", `String dashboard_tree_sha256
        ; "output_file_count", `Int 1
        ]
    in
    `Assoc
      [ "state", `String "available"
      ; "schema", `String "masc.run-local-dashboard-assets.v1"
      ; "source_root", `String (Filename.concat source_root "assets/dashboard")
      ; "snapshot_root", `String dashboard_snapshot_root
      ; "snapshot_device", `Int dashboard_snapshot_stat.st_dev
      ; "snapshot_inode", `Int dashboard_snapshot_stat.st_ino
      ; "tree_sha256", `String dashboard_tree_sha256
      ; "file_count", `Int 1
      ; "build_receipt", build_receipt
      ; ( "files"
        , `List
            [ `Assoc
                [ "path", `String "index.html"
                ; "size", `Int 9
                ; "sha256", `String dashboard_asset_sha256
                ] ] )
      ]
  in
  `Assoc
    ([ "schema", `String "masc.run-local-executable-identity.v2"
     ; "binary_commit", `String commit
     ; "build_input_fingerprint", `String fingerprint
     ; "source_root", `String source_root
     ; "source_root_device", `Int source_root_stat.st_dev
     ; "source_root_inode", `Int source_root_stat.st_ino
     ; "dashboard_assets", dashboard_assets
     ; "executable_sha256", `String sha256
     ; "executable_device", `Int 1
     ; "executable_inode", `Int executable_inode
     ]
     @ extra)
  |> Yojson.Safe.to_string
;;

let test_executable_provenance_requires_exact_identity () =
  let commit = String.make 40 'a' in
  let fingerprint = String.make 64 'b' in
  let sha256 = String.make 64 'c' in
  let raw = executable_provenance_json ~commit ~fingerprint ~sha256 () in
  let expected : Build_identity.executable_provenance =
    let source_root = Unix.realpath (Sys.getcwd ()) in
    let source_root_stat = Unix.stat source_root in
    let dashboard_assets : Build_identity.dashboard_assets_provenance =
      { source_root = Filename.concat source_root "assets/dashboard"
      ; snapshot_root = source_root
      ; snapshot_device = source_root_stat.st_dev
      ; snapshot_inode = source_root_stat.st_ino
      ; tree_sha256 = fixture_dashboard_tree_sha256 ()
      ; build_source_commit = commit
      ; build_head_tree = String.make 40 'f'
      ; build_index_tree = String.make 40 'e'
      ; build_input_sha256 = String.make 64 'a'
      ; build_input_file_count = 12
      ; build_input_matches_head = true
      ; build_lock_sha256 = String.make 64 'b'
      ; build_mode = "production"
      ; build_environment_path = "/verified"
      ; build_environment_path_identity_sha256 = String.make 64 '4'
      ; build_environment_path_executable_sha256 = String.make 64 '5'
      ; build_environment_path_executable_count = 73
      ; build_environment_profile_sha256 = String.make 64 'c'
      ; build_producer = "scripts/build-dashboard-if-needed.sh --prepare-exact + --build-exact"
      ; build_node_executable = "/verified/node"
      ; build_node_executable_sha256 = String.make 64 '1'
      ; build_node_version = "v24.0.0"
      ; build_node_platform = "darwin"
      ; build_node_arch = "arm64"
      ; build_package_manager_kind = "pnpm"
      ; build_package_manager_executable = "/verified/pnpm"
      ; build_package_manager_executable_sha256 = String.make 64 '2'
      ; build_pnpm_version = "10.0.0"
      ; build_vite_version = "7.0.0"
      ; build_installed_graph_metadata_sha256 = String.make 64 '3'
      ; build_installed_graph_metadata_count = 42
      ; files =
          [ { Build_identity.relative_path = "index.html"
            ; size = 9
            ; sha256 = String.make 64 'd'
            } ]
      }
    in
    { binary_commit = commit
    ; build_input_fingerprint = fingerprint
    ; source_root
    ; source_root_device = source_root_stat.st_dev
    ; source_root_inode = source_root_stat.st_ino
    ; dashboard_assets = Some dashboard_assets
    ; executable_sha256 = sha256
    ; executable_device = 1
    ; executable_inode = 2
    }
  in
  Alcotest.(check (result (testable (fun ppf (value : Build_identity.executable_provenance) ->
    Format.fprintf ppf "%s/%s/%s"
      value.Build_identity.binary_commit
      value.build_input_fingerprint
      value.executable_sha256) ( = )) string))
    "exact sidecar accepted"
    (Ok expected)
    (Build_identity.parse_executable_provenance
       ~expected_binary_commit:commit
       ~expected_executable_sha256:sha256
       ~expected_executable_device:1
       ~expected_executable_inode:2
       raw)
;;

let test_executable_provenance_rejects_mismatches () =
  let commit = String.make 40 'a' in
  let fingerprint = String.make 64 'b' in
  let sha256 = String.make 64 'c' in
  let parse raw =
    Build_identity.parse_executable_provenance
      ~expected_binary_commit:commit
      ~expected_executable_sha256:sha256
      ~expected_executable_device:1
      ~expected_executable_inode:2
      raw
  in
  let check_error label expected raw =
    match parse raw with
    | Error actual -> Alcotest.(check string) label expected actual
    | Ok _ -> Alcotest.fail (label ^ ": malformed sidecar was accepted")
  in
  let map_top_fields transform raw =
    match Yojson.Safe.from_string raw with
    | `Assoc fields -> `Assoc (transform fields) |> Yojson.Safe.to_string
    | _ -> Alcotest.fail "fixture provenance is not an object"
  in
  check_error
    "digest mismatch"
    "executable provenance executable digest differs"
    (executable_provenance_json
       ~commit
       ~fingerprint
       ~sha256:(String.make 64 'd')
       ());
  check_error
    "invalid build fingerprint"
    "executable provenance build-input fingerprint is invalid"
    (executable_provenance_json ~commit ~fingerprint:"not-a-digest" ~sha256 ());
  check_error
    "replacement inode"
    "executable provenance executable inode differs"
    (executable_provenance_json
       ~commit
       ~fingerprint
       ~sha256
       ~executable_inode:3
       ());
  check_error
    "unknown fields"
    "executable provenance has unsupported fields"
    (executable_provenance_json
       ~extra:[ "unexpected", `Bool true ]
       ~commit
       ~fingerprint
       ~sha256
       ());
  let exact = executable_provenance_json ~commit ~fingerprint ~sha256 () in
  check_error
    "same-count unknown field"
    "executable provenance has unsupported fields"
    (map_top_fields
       (List.map (fun (name, value) ->
          if String.equal name "source_root_inode" then "unexpected", value else name, value))
       exact);
  check_error
    "missing field"
    "executable provenance has unsupported fields"
    (map_top_fields
       (List.filter (fun (name, _) -> not (String.equal name "source_root_inode")))
       exact);
  check_error
    "duplicate field"
    "executable provenance has unsupported fields"
    (map_top_fields
       (fun fields -> ("binary_commit", `String commit) :: fields)
       exact)
;;

let test_executable_provenance_binding_rejects_replacement_and_forgery () =
  let path = Filename.temp_file "build-provenance" ".json" in
  let snapshot_root = Filename.temp_file "dashboard-blobs" "" in
  Sys.remove snapshot_root;
  Unix.mkdir snapshot_root 0o700;
  let commit = String.make 40 'a' in
  let sha256 = String.make 64 'c' in
  let raw =
    executable_provenance_json
      ~dashboard_snapshot_root:snapshot_root
      ~commit
      ~fingerprint:(String.make 64 'b')
      ~sha256
      ()
  in
  let write value =
    if Sys.file_exists path then Unix.chmod path 0o600;
    Out_channel.with_open_bin path (fun channel -> output_string channel value);
    Unix.chmod path 0o400
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists snapshot_root then Unix.rmdir snapshot_root)
    (fun () ->
      write raw;
      let sidecar = Unix.lstat path in
      let digest = Digestif.SHA256.(digest_string raw |> to_hex) in
      let validate () =
        Build_identity.For_testing.validate_executable_provenance_binding
          ~path
          ~expected_sidecar_sha256:digest
          ~expected_sidecar_device:sidecar.st_dev
          ~expected_sidecar_inode:sidecar.st_ino
          ~expected_binary_commit:commit
          ~expected_executable_sha256:sha256
          ~expected_executable_device:1
          ~expected_executable_inode:2
      in
      Alcotest.(check bool) "exact inode binding accepted" true (Result.is_ok (validate ()));
      Sys.remove path;
      write raw;
      Alcotest.(check bool) "same-byte replacement rejected" true (Result.is_error (validate ()));
      write (raw ^ " ");
      Alcotest.(check bool) "forged bytes rejected" true (Result.is_error (validate ())))
;;

let test_executable_provenance_binding_rejects_source_root_replacement () =
  let source_root = Filename.temp_file "build-source-root" "" in
  Sys.remove source_root;
  Unix.mkdir source_root 0o755;
  let displaced_root = source_root ^ ".displaced" in
  let snapshot_root = Filename.temp_file "dashboard-blobs" "" in
  Sys.remove snapshot_root;
  Unix.mkdir snapshot_root 0o700;
  let sidecar_path = Filename.temp_file "build-provenance" ".json" in
  let commit = String.make 40 'a' in
  let sha256 = String.make 64 'c' in
  let raw =
    executable_provenance_json
      ~source_root
      ~dashboard_snapshot_root:snapshot_root
      ~commit
      ~fingerprint:(String.make 64 'b')
      ~sha256
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists sidecar_path then Sys.remove sidecar_path;
      if Sys.file_exists source_root then Unix.rmdir source_root;
      if Sys.file_exists displaced_root then Unix.rmdir displaced_root;
      if Sys.file_exists snapshot_root then Unix.rmdir snapshot_root)
    (fun () ->
      Out_channel.with_open_bin sidecar_path (fun channel -> output_string channel raw);
      Unix.chmod sidecar_path 0o400;
      let sidecar = Unix.lstat sidecar_path in
      let digest = Digestif.SHA256.(digest_string raw |> to_hex) in
      let validate () =
        Build_identity.For_testing.validate_executable_provenance_binding
          ~path:sidecar_path
          ~expected_sidecar_sha256:digest
          ~expected_sidecar_device:sidecar.st_dev
          ~expected_sidecar_inode:sidecar.st_ino
          ~expected_binary_commit:commit
          ~expected_executable_sha256:sha256
          ~expected_executable_device:1
          ~expected_executable_inode:2
      in
      Alcotest.(check bool) "original source root accepted" true (Result.is_ok (validate ()));
      Unix.rename source_root displaced_root;
      Unix.mkdir source_root 0o755;
      Alcotest.(check bool)
        "replacement source root inode rejected"
        true
      (Result.is_error (validate ())))
;;

let test_dashboard_resolution_is_bound_and_fails_closed_after_replacement () =
  let source_root = Filename.temp_file "dashboard-source" "" in
  Sys.remove source_root;
  Unix.mkdir source_root 0o755;
  let displaced_root = source_root ^ ".displaced" in
  let snapshot_root = Filename.temp_file "dashboard-blobs" "" in
  Sys.remove snapshot_root;
  Unix.mkdir snapshot_root 0o700;
  let blob_name = String.make 64 'd' in
  let blob_path = Filename.concat snapshot_root blob_name in
  Out_channel.with_open_bin blob_path (fun channel -> output_string channel "manifest!");
  Unix.chmod blob_path 0o600;
  let commit = String.make 40 'a' in
  let sha256 = String.make 64 'c' in
  let raw =
    executable_provenance_json
      ~source_root
      ~dashboard_snapshot_root:snapshot_root
      ~commit
      ~fingerprint:(String.make 64 'b')
      ~sha256
      ()
  in
  let provenance =
    Build_identity.parse_executable_provenance
      ~expected_binary_commit:commit
      ~expected_executable_sha256:sha256
      ~expected_executable_device:1
      ~expected_executable_inode:2
      raw
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists blob_path then Sys.remove blob_path;
      if Sys.file_exists snapshot_root then Unix.rmdir snapshot_root;
      if Sys.file_exists source_root then Unix.rmdir source_root;
      if Sys.file_exists displaced_root then Unix.rmdir displaced_root)
    (fun () ->
      (match Build_identity.For_testing.resolve_dashboard_asset provenance "index.html" with
       | Build_identity.Dashboard_asset_bound { path; expected_size; _ } ->
         Alcotest.(check string) "bound blob path" (Unix.realpath blob_path) path;
         Alcotest.(check int) "bound size" 9 expected_size
       | _ -> Alcotest.fail "manifested index did not resolve to bound CAS bytes");
      (match Build_identity.For_testing.resolve_dashboard_asset provenance "assets/missing.js" with
       | Build_identity.Dashboard_asset_not_manifested -> ()
       | _ -> Alcotest.fail "unmanifested asset did not fail closed");
      let unavailable = { provenance with dashboard_assets = None } in
      (match Build_identity.For_testing.resolve_dashboard_asset unavailable "index.html" with
       | Build_identity.Dashboard_assets_unavailable -> ()
       | _ -> Alcotest.fail "receipt-less bound launch did not stay unavailable");
      Unix.rename source_root displaced_root;
      Unix.mkdir source_root 0o755;
      (match Build_identity.For_testing.resolve_dashboard_asset provenance "index.html" with
       | Build_identity.Dashboard_assets_invalid
           (Build_identity.Dashboard_source_root_invalid
              Build_identity.Source_root_inode_differs) -> ()
       | _ -> Alcotest.fail "source-root replacement did not invalidate bound assets"))
;;

let test_pick_repo_candidates_exe_first_when_distinct () =
  (* Regression for the bug where running `cd ~/me && .../masc/main_eio.exe`
     reported ~/me's commit instead of masc's. exe_dir must come first. *)
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dev/masc/_build/default/bin"
      ~cwd:"/Users/dev/me"
  in
  Alcotest.(check (list string))
    "exe_dir before cwd"
    [ "/Users/dev/masc/_build/default/bin"; "/Users/dev/me" ]
    result

let test_pick_repo_candidates_dedups_equal () =
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dev/masc"
      ~cwd:"/Users/dev/masc"
  in
  Alcotest.(check (list string))
    "single entry when equal"
    [ "/Users/dev/masc" ]
    result

let test_pick_repo_candidates_not_sorted_alphabetically () =
  (* The old implementation used List.sort_uniq String.compare which
     sorted alphabetically, causing /Users/dancer/me to win over
     /Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin
     because the shorter prefix is lexicographically smaller. Assert
     that we now preserve the logical order instead. *)
  let result =
    Build_identity.pick_repo_candidates
      ~exe_dir:"/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin"
      ~cwd:"/Users/dancer/me"
  in
  match result with
  | first :: _ ->
      Alcotest.(check string)
        "exe_dir wins over shorter cwd prefix"
        "/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin"
        first
  | [] -> Alcotest.fail "pick_repo_candidates returned empty list"

let test_parse_commit_unix_ts_output () =
  Alcotest.(check (option (float 0.001)))
    "valid timestamp"
    (Some 1_712_000_000.0)
    (Build_identity.parse_commit_unix_ts_output " 1712000000\n");
  Alcotest.(check (option (float 0.001)))
    "valid timestamp above 32-bit int max"
    (Some 4_102_444_800.0)
    (Build_identity.parse_commit_unix_ts_output "4102444800\n");
  Alcotest.(check (option (float 0.001)))
    "invalid timestamp"
    None
    (Build_identity.parse_commit_unix_ts_output "not-a-timestamp\n");
  List.iter
    (fun raw ->
      Alcotest.(check (option (float 0.001)))
        ("reject non-integer timestamp " ^ raw)
        None
        (Build_identity.parse_commit_unix_ts_output raw))
    [ "nan"; "inf"; "-1"; "1.0"; "1e9"; "0x660b7d80"; "4102444801" ]

let test_parse_dune_project_version () =
  Alcotest.(check (option string)) "version parsed"
    (Some "0.19.20")
    (Build_identity.parse_dune_project_version
       "(lang dune 3.22)\n\n(name masc)\n(version 0.19.20)\n");
  Alcotest.(check (option string)) "missing version" None
    (Build_identity.parse_dune_project_version "(lang dune 3.22)\n")

let build_identity_probe_failure_count site =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_build_identity_probe_failures
    ~labels:[("site", site)]
    ()

let test_probe_failure_observer_increments_metric () =
  let before = build_identity_probe_failure_count "commit_ts_parse" in
  Build_identity.For_testing.observe_probe_failure
    ~site:"commit_ts_parse"
    (Failure "synthetic parse failure");
  let after = build_identity_probe_failure_count "commit_ts_parse" in
  Alcotest.(check (float 0.0001))
    "probe failure counted"
    (before +. 1.0)
    after

let test_commit_ts_git_status_failure_is_observed () =
  match Build_identity.repo_root () with
  | None -> ()
  | Some _ ->
      let before = build_identity_probe_failure_count "commit_ts_git_status" in
      let result =
        Build_identity.For_testing.probe_commit_unix_ts
          (Some "definitely-not-a-real-commit")
      in
      let after = build_identity_probe_failure_count "commit_ts_git_status" in
      Alcotest.(check (option (float 0.001)))
        "invalid commit has no timestamp"
        None
        result;
      Alcotest.(check bool)
        "non-zero git status counted at least once"
        true
        (after >= before +. 1.0)

let test_path_is_in_worktree_pins_the_convention () =
  let in_worktree = Masc.Build_identity.path_is_in_worktree in
  Alcotest.(check bool) "a .worktrees exe is a worktree binary" true
    (in_worktree "/Users/x/masc/.worktrees/feature/a/_build/default/bin/main_eio.exe");
  Alcotest.(check bool) "the root build is not" false
    (in_worktree "/Users/x/masc/_build/default/bin/main_eio.exe");
  Alcotest.(check bool)
    "a directory merely named worktrees does not trip it" false
    (in_worktree "/Users/x/worktrees-tools/bin/main_eio.exe");
  Alcotest.(check bool) "current() carries the verdict for this process"
    (in_worktree (Masc.Build_identity.current ()).executable_path)
    (Masc.Build_identity.current ()).executable_in_worktree

let () =
  Alcotest.run "build_identity"
    [
      ( "identity",
        [
          Alcotest.test_case "path_is_in_worktree pins the convention" `Quick
            test_path_is_in_worktree_pins_the_convention;
          Alcotest.test_case "resolve commit prefers embedded" `Quick
            test_resolve_commit_prefers_embedded;
          Alcotest.test_case "resolve commit details prefers embedded binary"
            `Quick test_resolve_commit_details_prefers_embedded_binary;
          Alcotest.test_case "resolve commit falls back to probe" `Quick
            test_resolve_commit_uses_probe_when_embedded_missing;
          Alcotest.test_case
            "resolve commit details marks repo head fallback" `Quick
            test_resolve_commit_details_marks_repo_head_fallback;
          Alcotest.test_case
            "binary identity ignores mismatched ambient checkout" `Quick
            test_binary_identity_ignores_mismatched_ambient_checkout;
          Alcotest.test_case
            "binary identity survives without checkout" `Quick
            test_binary_identity_survives_without_checkout;
          Alcotest.test_case "current started_at stable" `Quick
            test_current_started_at_is_stable;
          Alcotest.test_case "executable provenance requires exact identity" `Quick
            test_executable_provenance_requires_exact_identity;
          Alcotest.test_case "executable provenance rejects mismatches" `Quick
            test_executable_provenance_rejects_mismatches;
          Alcotest.test_case "executable provenance rejects replacement and forgery" `Quick
            test_executable_provenance_binding_rejects_replacement_and_forgery;
          Alcotest.test_case "executable provenance rejects source root replacement" `Quick
            test_executable_provenance_binding_rejects_source_root_replacement;
          Alcotest.test_case "dashboard resolution fails closed after replacement" `Quick
            test_dashboard_resolution_is_bound_and_fails_closed_after_replacement;
          Alcotest.test_case "runtime cwd snapshot is resolver backed" `Quick
            test_runtime_cwd_is_resolver_backed_snapshot;
          Alcotest.test_case "current JSON exposes runtime binary identity" `Quick
            test_current_json_exposes_runtime_binary_identity;
          Alcotest.test_case
            "pick_repo_candidates exe first when distinct" `Quick
            test_pick_repo_candidates_exe_first_when_distinct;
          Alcotest.test_case
            "pick_repo_candidates dedups equal" `Quick
            test_pick_repo_candidates_dedups_equal;
          Alcotest.test_case
            "pick_repo_candidates not sorted alphabetically" `Quick
            test_pick_repo_candidates_not_sorted_alphabetically;
          Alcotest.test_case "repeated current does not rehash the executable"
            `Quick test_repeated_current_does_not_rehash_the_executable;
          Alcotest.test_case "direct launch still identifies its executable"
            `Quick test_direct_launch_still_identifies_its_executable;
          Alcotest.test_case "a bare argv0 is not resolved against the cwd"
            `Quick test_bare_argv0_is_not_resolved_against_the_cwd;
          Alcotest.test_case "an argv0 with a directory stays cwd-relative"
            `Quick test_argv0_with_a_directory_is_still_cwd_relative;
          Alcotest.test_case "bare names everywhere do not invent a path"
            `Quick test_bare_names_everywhere_do_not_invent_a_path;
          Alcotest.test_case "parse commit timestamp output" `Quick
            test_parse_commit_unix_ts_output;
          Alcotest.test_case "parse dune-project version" `Quick
            test_parse_dune_project_version;
          Alcotest.test_case "probe failure observer increments metric" `Quick
            test_probe_failure_observer_increments_metric;
          Alcotest.test_case "git status failure increments metric" `Quick
            test_commit_ts_git_status_failure_is_observed;
        ] );
    ]
