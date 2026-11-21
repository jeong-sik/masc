(** Regression tests for current Memory OS fleet-health projection. *)

module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module SourceCurrent = Masc.Keeper_memory_source_current
module Metrics = Masc.Otel_metric_store
module KeeperMetrics = Keeper_metrics
module Health = Server_dashboard_http_keeper_memory_health

let test_now = 1_700_000_000.0
let fresh_dir prefix = Filename.temp_dir prefix ""

(* The projection caches each keeper's row and drops it when a writer reports a
   commit. The server wires that at startup ([Server_runtime_bootstrap]); a test
   that writes and then reads again has to wire the same observers, or the
   second read answers from the row the first one cached.

   Installing at module load is not idempotent: [install] retains the restore
   closures it collects but never returns them, and each
   [install_commit_observer] replaces the previous observer rather than
   chaining, so a later [For_testing.with_runtime] restore can drop this
   registration. *)
let () = Health.install ()

let fact claim : Types.fact =
  Types.observed ~claim ~category:Types.Fact ~now:test_now
    ~origin:{ kind = Types.Authored; trace_id = "" }
;;

let derived_fact ~claim ~premise =
  match
    Types.derived
      ~claim
      ~category:Types.Fact
      ~now:test_now
      ~origin:{ kind = Types.Authored; trace_id = "health-test" }
      ~derivations:
        [ { rule_id = "health_support"; premise_ids = [ Types.memory_id premise ] } ]
  with
  | Ok fact -> fact
  | Error detail -> Alcotest.fail detail
;;

let source =
  { Current.kind = Current.Librarian
  ; trace_id = "health-test"
  }
;;

let require_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let write_snapshot ?(now = test_now) ~keepers_dir ~keeper_id facts =
  Fs_compat.mkdir_p keepers_dir;
  let expected_revision =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok None -> None
    | Ok (Some snapshot) -> Some snapshot.revision
    | Error detail -> Alcotest.fail detail
  in
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now
    ~source
    ~facts
    ()
  |> require_ok
;;

let source_sha256 = "sha256:" ^ String.make 64 'a'

let write_source_snapshot ~keepers_dir ~keeper_id ~facts ~invalidations =
  Fs_compat.mkdir_p keepers_dir;
  let snapshot : SourceCurrent.t =
    { revision = 3
    ; updated_at = test_now
    ; trace_id = "source-health-test"
    ; facts
    ; invalidations
    }
  in
  Fs_compat.save_file
    (SourceCurrent.path_for_keepers_dir ~keepers_dir ~keeper_id)
    (Yojson.Safe.pretty_to_string (SourceCurrent.to_json snapshot) ^ "\n")
;;

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let int_field name json =
  match assoc_field name json with
  | Some (`Int n) -> n
  | _ -> Alcotest.failf "expected int field %S" name
;;

let float_field name json =
  match assoc_field name json with
  | Some (`Float f) -> f
  | Some (`Int n) -> float_of_int n
  | _ -> Alcotest.failf "expected float field %S" name
;;

let string_field name json =
  match assoc_field name json with
  | Some (`String s) -> s
  | _ -> Alcotest.failf "expected string field %S" name
;;

let bool_field name json =
  match assoc_field name json with
  | Some (`Bool b) -> b
  | _ -> Alcotest.failf "expected bool field %S" name
;;

let list_field name json =
  match assoc_field name json with
  | Some (`List xs) -> xs
  | _ -> Alcotest.failf "expected list field %S" name
;;

let member name json =
  match assoc_field name json with
  | Some value -> value
  | None -> Alcotest.failf "expected field %S" name
;;

let is_null = function
  | `Null -> true
  | _ -> false
;;

let totals json =
  match assoc_field "totals" json with
  | Some value -> value
  | None -> Alcotest.fail "expected totals object"
;;

let alert_summary json =
  match assoc_field "alert_summary" json with
  | Some value -> value
  | None -> Alcotest.fail "expected alert_summary object"
;;

let keeper_ids json =
  list_field "keepers" json
  |> List.filter_map (fun keeper ->
    match assoc_field "keeper_id" keeper with
    | Some (`String id) -> Some id
    | _ -> None)
;;

let keeper_obj id json =
  match
    list_field "keepers" json
    |> List.find_opt (fun keeper ->
      match assoc_field "keeper_id" keeper with
      | Some (`String candidate) -> String.equal id candidate
      | _ -> false)
  with
  | Some keeper -> keeper
  | None -> Alcotest.failf "keeper %S missing" id
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv name (Option.value old ~default:"");
      Config_dir_resolver.reset ())
    f
;;

let test_uses_explicit_base_path_not_ambient_resolver () =
  let target_base = fresh_dir "masc-memory-health-target" in
  let ambient_base = fresh_dir "masc-memory-health-ambient" in
  let target_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:target_base
  in
  let ambient_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:ambient_base
  in
  ignore
    (write_snapshot
       ~keepers_dir:target_keepers_dir
       ~keeper_id:"target"
       [ fact "target fact" ]);
  ignore
    (write_snapshot
       ~keepers_dir:ambient_keepers_dir
       ~keeper_id:"ambient"
       [ fact "ambient fact" ]);
  with_env "MASC_BASE_PATH" ambient_base (fun () ->
    let json = Health.keeper_memory_health_http_json ~base_path:target_base in
    Alcotest.(check (list string)) "explicit base path" [ "target" ] (keeper_ids json))
;;

let test_reports_revision_snapshot_bytes_and_latest_delta () =
  let base = fresh_dir "masc-memory-health-current" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let first = fact "A" in
  let changed = fact "A revised" in
  let second = fact "B" in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"solo" [ first ]);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"solo" [ changed; second ]);
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj "solo" json in
  Alcotest.(check string)
    "schema"
    "keeper.memory_os.current_health.v18"
    (string_field "schema" json);
  Alcotest.(check int) "revision" 2 (int_field "revision" keeper);
  Alcotest.(check int) "facts" 2 (int_field "facts" keeper);
  Alcotest.(check int) "observed facts" 2 (int_field "observed_facts" keeper);
  Alcotest.(check int) "derived facts" 0 (int_field "derived_facts" keeper);
  Alcotest.(check int) "support invalidations" 0
    (int_field "support_invalidations" keeper);
  Alcotest.(check bool) "snapshot bytes" true (int_field "snapshot_bytes" keeper > 0);
  Alcotest.(check int) "added" 2 (int_field "added" keeper);
  Alcotest.(check int) "removed" 1 (int_field "removed" keeper);
  (* The facts were first seen at [test_now], years before the wall clock the
     handler reads, so both are in the oldest of the 24 bins. *)
  Alcotest.(check (list int))
    "age_bins"
    (List.init 23 (fun _ -> 0) @ [ 2 ])
    (List.map Yojson.Safe.Util.to_int (list_field "age_bins" keeper));
  Alcotest.(check int) "no alerts" 0 (List.length (list_field "alerts" keeper));
  Alcotest.(check int) "total facts" 2 (int_field "facts" (totals json));
  Alcotest.(check int) "total observed facts" 2
    (int_field "observed_facts" (totals json));
  Alcotest.(check bool) "generated_at" true (float_field "generated_at" json >= 0.0)
;;

let test_reports_derived_facts_and_support_invalidations () =
  let base = fresh_dir "masc-memory-health-support" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let premise = fact "dependency is healthy" in
  let conclusion = derived_fact ~claim:"rollout can proceed" ~premise in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"support" [ premise; conclusion ]);
  let supported = Health.keeper_memory_health_http_json ~base_path:base in
  let supported_keeper = keeper_obj "support" supported in
  Alcotest.(check int) "one observed fact" 1
    (int_field "observed_facts" supported_keeper);
  Alcotest.(check int) "one derived fact" 1
    (int_field "derived_facts" supported_keeper);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"support" [ conclusion ]);
  let invalidated = Health.keeper_memory_health_http_json ~base_path:base in
  let invalidated_keeper = keeper_obj "support" invalidated in
  Alcotest.(check int) "unsupported conclusion is absent" 0
    (int_field "facts" invalidated_keeper);
  Alcotest.(check int) "support retraction is visible" 1
    (int_field "support_invalidations" invalidated_keeper);
  Alcotest.(check int) "fleet total includes support retraction" 1
    (int_field "support_invalidations" (totals invalidated))
;;

let test_source_only_snapshot_is_enumerated_and_counted () =
  let base = fresh_dir "masc-memory-health-source-only" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let facts : SourceCurrent.fact list =
    [ { claim = "source-backed current fact"
      ; first_seen = test_now
      ; source = { path = "evidence/current.txt"; sha256 = source_sha256 }
      }
    ]
  in
  let invalidations : SourceCurrent.invalidation list =
    [ { source_path = "evidence/old.txt"
      ; invalidated_at = test_now
      ; reason = SourceCurrent.Source_changed
      }
    ]
  in
  write_source_snapshot
    ~keepers_dir
    ~keeper_id:"source-only"
    ~facts
    ~invalidations;
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryOsLibrarianFailures)
    ~labels:[ "keeper", "source-only"; "site", "memory_os_librarian" ]
    ~delta:1.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "source snapshot contributes identity"
    [ "source-only" ]
    (keeper_ids json);
  let keeper = keeper_obj "source-only" json in
  Alcotest.(check bool) "ordinary absent" false (bool_field "snapshot_present" keeper);
  Alcotest.(check bool)
    "source present"
    true
    (bool_field "source_snapshot_present" keeper);
  Alcotest.(check int) "source revision" 3 (int_field "source_revision" keeper);
  Alcotest.(check int) "source facts" 1 (int_field "source_facts" keeper);
  Alcotest.(check int)
    "source invalidations"
    1
    (int_field "source_invalidations" keeper);
  Alcotest.(check bool)
    "source bytes"
    true
    (int_field "source_snapshot_bytes" keeper > 0);
  Alcotest.(check int) "total source facts" 1 (int_field "source_facts" (totals json));
  Alcotest.(check int)
    "total source invalidations"
    1
    (int_field "source_invalidations" (totals json));
  let alerts = list_field "alerts" keeper in
  Alcotest.(check (list string))
    "ordinary starvation remains explicit"
    [ "librarian_starvation" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check string)
    "alert acknowledges remaining source-bound memory"
    "Librarian runs failed and no ordinary current-memory snapshot exists. A source-bound snapshot remains available, but it does not demonstrate or repair Librarian selection."
    (string_field "message" (List.hd alerts))
;;

let test_corrupt_source_snapshot_is_visible () =
  let base = fresh_dir "masc-memory-health-source-corrupt" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let path =
    SourceCurrent.path_for_keepers_dir ~keepers_dir ~keeper_id:"source-broken"
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file path {|{"schema":"wrong"}|};
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj "source-broken" json in
  Alcotest.(check (list string))
    "source read alert"
    [ "source_snapshot_read_error" ]
    (list_field "alerts" keeper |> List.map (string_field "code"));
  Alcotest.(check int)
    "source read errors"
    1
    (int_field "source_read_errors" (totals json));
  Alcotest.(check int)
    "source read error keepers"
    1
    (int_field "source_snapshot_read_error_keepers" (alert_summary json))
;;

let test_journal_outcome_distinguishes_unreadable_from_empty () =
  let module Outcome = Masc.Keeper_memory_journal_outcome in
  let base = fresh_dir "masc-memory-health-journal-unreadable" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "unreadable" in
  Fs_compat.mkdir_p keepers_dir;
  let read () = Outcome.read ~keepers_dir ~keeper_id in
  let missing = read () in
  Alcotest.(check bool) "a confirmed missing journal is not a read error" true
    (Option.is_none missing.read_error && missing.facts_by_hour = []);
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir path) (fun () ->
    let unavailable = read () in
    Alcotest.(check bool) "an unreadable first journal is not an empty success" true
      (Option.is_some unavailable.read_error && unavailable.facts_by_hour = []));
  Fs_compat.save_file path "";
  let empty = read () in
  Alcotest.(check bool) "an actual empty journal clears the read error" true
    (Option.is_none empty.read_error && empty.facts_by_hour = [])
;;

let test_journal_failure_keeps_evidence_and_recovers_without_another_commit () =
  let base = fresh_dir "masc-memory-health-journal-recovery" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "journal-recovery" in
  let write facts =
    ignore (write_snapshot ~now:(Unix.gettimeofday ()) ~keepers_dir ~keeper_id facts)
  in
  let row () =
    Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:keeper_id
    |> member "keeper"
  in
  let latest_facts row =
    match List.rev (list_field "facts_by_hour" row) with
    | point :: _ -> int_field "facts" point
    | [] -> Alcotest.fail "the journal trend has no retained commit"
  in
  write [ fact "one" ];
  let first = row () in
  Alcotest.(check int) "the first journal observation has one fact" 1 (latest_facts first);
  Alcotest.(check bool) "the first journal read is healthy" true
    (is_null (member "read_error" first));
  (* A real commit invalidates the cached row before its journal is read. *)
  write [ fact "one"; fact "two" ];
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let held = path ^ ".held" in
  Unix.rename path held;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir path; Unix.rename held path)
    (fun () ->
      let unavailable = row () in
      Alcotest.(check int) "the independently readable snapshot stays visible" 2
        (int_field "facts" unavailable);
      Alcotest.(check int) "the last successful journal evidence is retained" 1
        (latest_facts unavailable);
      Alcotest.(check bool) "retained journal points are marked incomplete" false
        (is_null (member "read_error" unavailable));
      let fleet = Health.keeper_memory_health_http_json ~base_path:base in
      Alcotest.(check int) "the journal failure contributes to the read-error total" 1
        (int_field "read_errors" (totals fleet)));
  let recovered = row () in
  Alcotest.(check bool) "an error row is reread after recovery without a new commit" true
    (is_null (member "read_error" recovered));
  Alcotest.(check int) "the previously unread append is now visible" 2
    (latest_facts recovered)
;;

let test_corrupt_snapshot_is_visible_as_read_error () =
  let base = fresh_dir "masc-memory-health-corrupt" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"good" [ fact "good fact" ]);
  let broken_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"broken"
  in
  Fs_compat.save_file broken_path {|{"schema":"wrong"}|};
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "both keepers stay visible"
    [ "broken"; "good" ]
    (keeper_ids json |> List.sort String.compare);
  let broken = keeper_obj "broken" json in
  Alcotest.(check (list string))
    "read alert"
    [ "snapshot_read_error" ]
    (list_field "alerts" broken |> List.map (string_field "code"));
  Alcotest.(check int) "total read errors" 1 (int_field "read_errors" (totals json))
;;

let test_sorts_by_snapshot_bytes_and_handles_empty_store () =
  let base = fresh_dir "masc-memory-health-sort" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"small" [ fact "x" ]);
  ignore
    (write_snapshot
       ~keepers_dir
       ~keeper_id:"large"
       [ fact "a much longer current memory claim"
       ; fact "another much longer current memory claim"
       ]);
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string))
    "largest snapshot first"
    [ "large"; "small" ]
    (keeper_ids json);
  let empty_base = fresh_dir "masc-memory-health-empty" in
  let empty = Health.keeper_memory_health_http_json ~base_path:empty_base in
  Alcotest.(check (list string)) "empty keepers" [] (keeper_ids empty);
  Alcotest.(check int) "empty unread total" 0 (int_field "librarian_unread_turns" (totals empty));
  Alcotest.(check int) "empty bytes" 0 (int_field "snapshot_bytes" (totals empty))
;;

(* Canonical identity comes from [keeper.name] with a file-basename fallback
   (keeper_types_profile_toml_io.inspect_keeper_toml). [name] defaults to the
   basename because that is the fleet norm;
   [test_toml_name_override_uses_canonical_identity] exercises the split. *)
let write_keeper_config ?name ~keepers_dir ~keeper_id () =
  Fs_compat.mkdir_p keepers_dir;
  let canonical = Option.value name ~default:keeper_id in
  Fs_compat.save_file
    (Filename.concat keepers_dir (keeper_id ^ ".toml"))
    (Printf.sprintf "[keeper]\nname = %S\n" canonical)
;;

(* A keeper that has a config but never committed memory is exactly the case
   the endpoint must not hide: it needs a row even with no snapshot file. *)
let test_configured_keeper_without_snapshot_gets_row () =
  let base = fresh_dir "masc-memory-health-configured" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "configured-" ^ Filename.basename base in
  write_keeper_config ~keepers_dir ~keeper_id ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check bool) "snapshot_present" false (bool_field "snapshot_present" keeper);
  Alcotest.(check int) "facts" 0 (int_field "facts" keeper);
  Alcotest.(check int)
    "no alerts without failures"
    0
    (List.length (list_field "alerts" keeper))
;;

let test_librarian_starvation_is_error_alert () =
  let base = fresh_dir "masc-memory-health-starve" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "starving-" ^ Filename.basename base in
  write_keeper_config ~keepers_dir ~keeper_id ();
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryOsLibrarianFailures)
    ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
    ~delta:4.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check int) "failures" 4 (int_field "librarian_failures" keeper);
  let alerts = list_field "alerts" keeper in
  Alcotest.(check (list string))
    "starvation code"
    [ "librarian_starvation" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check (list string))
    "error severity"
    [ "error" ]
    (List.map (string_field "severity") alerts);
  Alcotest.(check int)
    "summary error alerts"
    1
    (int_field "error_alerts" (alert_summary json));
  Alcotest.(check int)
    "summary starving keepers"
    1
    (int_field "librarian_starving_keepers" (alert_summary json))
;;

let test_librarian_failures_with_snapshot_is_warn_alert () =
  let base = fresh_dir "masc-memory-health-failwarn" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "failing-" ^ Filename.basename base in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "existing memory" ]);
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryOsLibrarianFailures)
    ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
    ~delta:2.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check bool) "snapshot_present" true (bool_field "snapshot_present" keeper);
  let alerts = list_field "alerts" keeper in
  Alcotest.(check (list string))
    "failures code"
    [ "librarian_failures" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check (list string))
    "warn severity"
    [ "warn" ]
    (List.map (string_field "severity") alerts);
  Alcotest.(check int)
    "summary error alerts"
    0
    (int_field "error_alerts" (alert_summary json))
;;

(* Metrics and snapshots are keyed by the canonical [name] in the toml, not
   by the file basename; enumeration must surface the canonical identity or
   a renamed keeper's starvation stays invisible behind a ghost row. *)
let test_toml_name_override_uses_canonical_identity () =
  let base = fresh_dir "masc-memory-health-rename" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let canonical = "actual-" ^ Filename.basename base in
  write_keeper_config ~name:canonical ~keepers_dir ~keeper_id:"alias" ();
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryOsLibrarianFailures)
    ~labels:[ "keeper", canonical; "site", "memory_os_librarian" ]
    ~delta:1.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check (list string)) "canonical row only" [ canonical ] (keeper_ids json);
  let keeper = keeper_obj canonical json in
  Alcotest.(check int) "failures visible" 1 (int_field "librarian_failures" keeper);
  Alcotest.(check (list string))
    "starvation on canonical row"
    [ "librarian_starvation" ]
    (list_field "alerts" keeper |> List.map (string_field "code"))
;;

let test_workspace_context_path_errors_and_source_snapshot () =
  let base = fresh_dir "workspace-memory-context-paths" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    write_keeper_config ~keepers_dir ~keeper_id:"loop" ();
    let ordinary_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"loop" in
    let source_path = SourceCurrent.path_for_keepers_dir ~keepers_dir ~keeper_id:"loop" in
    Unix.symlink (Filename.basename ordinary_path) ordinary_path;
    Unix.symlink (Filename.basename source_path) source_path;
    write_source_snapshot ~keepers_dir ~keeper_id:"source-only"
      ~facts:[ { SourceCurrent.claim = "Keep the source attribution"
               ; first_seen = test_now
               ; source = { path = "evidence/current.txt"; sha256 = source_sha256 } } ]
      ~invalidations:[ { SourceCurrent.source_path = "evidence/old.txt"
                       ; invalidated_at = test_now
                       ; reason = SourceCurrent.Source_changed } ];
    let expected_source =
      Fs_compat.load_file (SourceCurrent.path_for_keepers_dir ~keepers_dir ~keeper_id:"source-only")
      |> Yojson.Safe.from_string
    in
    let context = Health.workspace_memory_context_http_json ~base_path:base in
    let field = Yojson.Safe.Util.member in
    List.iter (fun store ->
      let unavailable = keeper_obj "loop" context |> field store in
      Alcotest.(check string) (store ^ " loop is unavailable") "unavailable"
        (string_field "status" unavailable);
      Alcotest.(check bool) "failure detail retained" true
        (String.length (string_field "detail" unavailable) > 0)) [ "ordinary"; "source_bound" ];
    let source = keeper_obj "source-only" context |> field "source_bound" in
    Alcotest.(check string) "source snapshot available" "available" (string_field "status" source);
    Alcotest.(check string) "all source bindings and invalidations preserved"
      (Yojson.Safe.to_string expected_source)
      (Yojson.Safe.to_string (field "snapshot" source));
    (* Remove the deliberately malformed links before recursive cleanup. *)
    Unix.unlink ordinary_path;
    Unix.unlink source_path)
;;

let test_workspace_context_discovery_not_directory () =
  let base = fresh_dir "workspace-memory-context-directory" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    Fs_compat.mkdir_p (Filename.dirname keepers_dir);
    Fs_compat.save_file keepers_dir "not a directory";
    let context = Health.workspace_memory_context_http_json ~base_path:base in
    Alcotest.(check string) "invalid discovery path is unavailable" "unavailable"
      (Yojson.Safe.Util.member "discovery" context |> string_field "status");
    Alcotest.(check (list string)) "no invented owners" [] (keeper_ids context))
;;

let test_curator_inventory_canonical_owner_discovery () =
  let module Inventory = Masc.Workspace_memory_context in
  let base = fresh_dir "workspace-curator-owners" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    write_keeper_config ~name:"actual" ~keepers_dir ~keeper_id:"alias" ();
    ignore (write_snapshot ~keepers_dir ~keeper_id:"actual" [fact "Keep canonical attribution"]);
    Fs_compat.save_file (Filename.concat keepers_dir "broken.toml") "[keeper\n";
    let inventory = Inventory.collect ~base_path:base |> require_ok |> Inventory.keepers in
    Alcotest.(check (list string)) "canonical owner is not duplicated under filename alias"
      ["actual"; "broken"] (List.map (fun (row : Inventory.keeper) -> row.keeper_id) inventory);
    Alcotest.(check (list string)) "invalid config basename remains visible in missing-store gaps"
      ["broken"] (inventory |> List.filter_map (fun (row : Inventory.keeper) ->
        match row.ordinary, row.source_bound with
        | Inventory.Missing, Inventory.Missing -> Some row.keeper_id
        | _ -> None)))
;;

let test_curator_inventory_binds_actual_commits () =
  let module Inventory = Masc.Workspace_memory_context in
  let module Ledger = Masc.Workspace_memory_ledger in
  let base = fresh_dir "workspace-curator-inventory" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    ignore (write_snapshot ~keepers_dir ~keeper_id:"writer" [fact "Draft has three criteria"]);
    ignore (write_snapshot ~keepers_dir ~keeper_id:"reviewer" [fact "Criteria are not files"]);
    let before = Inventory.collect ~base_path:base |> require_ok in
    let unchanged = Inventory.collect ~base_path:base |> require_ok in
    let before_identity = Inventory.fingerprint before in
    Alcotest.(check string) "observation time does not change captured inventory identity"
      before_identity (Inventory.fingerprint unchanged);
    let captured = Ledger.reconcile Ledger.empty (Inventory.keepers before) in
    Alcotest.(check int) "both current facts are pending" 2 (List.length captured.new_facts);
    ignore (write_snapshot ~keepers_dir ~keeper_id:"writer" []);
    let changed = Inventory.collect ~base_path:base |> require_ok in
    Alcotest.(check string) "the captured identity does not reread changed stores"
      before_identity (Inventory.fingerprint before);
    Alcotest.(check bool) "actual retraction changes the inventory" true
      (Inventory.fingerprint before <> Inventory.fingerprint changed);
    Alcotest.(check int) "in-flight facts stay captured" 2 (List.length captured.current_facts);
    Alcotest.(check int) "writer retraction removes one current fact" 1
      (List.length (Ledger.reconcile Ledger.empty (Inventory.keepers changed)).current_facts);
    Fs_compat.save_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"reviewer") "{broken";
    let unavailable = Inventory.collect ~base_path:base |> require_ok |> Inventory.keepers in
    Alcotest.(check bool) "corruption remains an unavailable store" true
      (List.exists (fun (row : Inventory.keeper) ->
        row.keeper_id = "reviewer" && match row.ordinary with
        | Inventory.Unavailable _ -> true | _ -> false) unavailable))
;;

(* One Keeper's row is the element the fleet answer carries for it, and a
   name the fleet does not list, a path-shaped one included, answers [null]. *)
let test_one_keepers_row_is_its_fleet_row () =
  let base = fresh_dir "masc-memory-health-one-row" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"solo" [ fact "A"; fact "B" ]);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"other" [ fact "C" ]);
  let fleet = Health.keeper_memory_health_http_json ~base_path:base in
  let answer = Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"solo" in
  Alcotest.(check string) "the row answer names the fleet schema"
    "keeper.memory_os.current_health.v18" (string_field "schema" answer);
  Alcotest.(check bool) "the row is the fleet's row for the Keeper" true
    (Yojson.Safe.equal (keeper_obj "solo" fleet) (member "keeper" answer));
  let row_of keeper =
    member "keeper" (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper)
  in
  Alcotest.(check bool) "an unlisted Keeper answers no row" true
    (Yojson.Safe.equal `Null (row_of "absent"));
  Alcotest.(check bool) "a path-shaped name answers no row" true
    (Yojson.Safe.equal `Null (row_of "../solo"))
;;

(* The totals count the rows: unread turns go unknown with one unmeasured
   row, the continuity lag sums the measured rows and counts the rest, and
   the alert summary counts each severity. *)
let test_totals_count_the_rows () =
  let module Totals = Masc.Keeper_memory_health_totals in
  let row ?(unread = Some (1, 2)) ?(continuity = Some 3) ?(alerts = []) ?(failures = 0)
      ?(snapshot_present = true) ?(stopped = false) ?(attention = false) ?(read_error = false) facts : Totals.Row.t =
    { Totals.Row.facts
    ; observed_facts = facts
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 10
    ; added = 1
    ; removed = 0
    ; source_facts = 0
    ; source_invalidations = 0
    ; source_snapshot_bytes = 0
    ; unread_atom_turns = Option.map fst unread
    ; unread_official_turns = Option.map snd unread
    ; continuity_unread_atoms = continuity
    ; librarian_failures = failures
    ; vision_ingest_errors = 0
    ; read_error
    ; source_read_error = false
    ; snapshot_present
    ; librarian_stopped = stopped
    ; librarian_attention_required = attention
    ; alerts
    }
  in
  let measured = Totals.of_rows [ row 2; row 3 ~continuity:None ] in
  Alcotest.(check int) "facts are summed" 5 measured.Totals.facts;
  Alcotest.(check (option int)) "unread turns are summed when every row is measured" (Some 6)
    measured.Totals.librarian_unread_turns;
  Alcotest.(check int) "the continuity lag sums the measured rows" 3
    measured.Totals.librarian_continuity_unread_atoms;
  Alcotest.(check int) "and counts the rest" 1 measured.Totals.librarian_continuity_unmeasured;
  let mixed =
    Totals.of_rows
      [ row 1 ~unread:None ~failures:1 ~snapshot_present:false ~stopped:true ~read_error:true
          ~alerts:[ Totals.Alert_warn; Totals.Alert_error ]
      ; row 1 ~attention:true
      ]
  in
  Alcotest.(check (option int)) "one unmeasured row leaves unread turns unknown" None
    mixed.Totals.librarian_unread_turns;
  Alcotest.(check int) "warn alerts" 1 mixed.Totals.warn_alerts;
  Alcotest.(check int) "error alerts" 1 mixed.Totals.error_alerts;
  Alcotest.(check int) "every alert" 2 mixed.Totals.total_alerts;
  Alcotest.(check int) "Keepers with alerts" 1 mixed.Totals.keepers_with_alerts;
  Alcotest.(check int) "read errors" 1 mixed.Totals.read_errors;
  Alcotest.(check int) "stopped Keepers" 1 mixed.Totals.librarian_stopped_keepers;
  Alcotest.(check int) "attention is counted separately from stopped" 1
    mixed.Totals.librarian_attention_required_keepers;
  Alcotest.(check int) "a Keeper with failures and no snapshot starves" 1
    mixed.Totals.librarian_starving_keepers;
  Alcotest.(check (option int)) "no row is a measured zero" (Some 0)
    (Totals.of_rows []).Totals.librarian_unread_turns
;;

(* The TUI reads one Keeper's row after its push and merges it into the fleet
   answer it holds. The merged answer is the fleet answer read
   after the write: the same rows, in the same order, with the same totals.
   A Keeper that left loses its row, and another Keeper's refused row, whose
   counts only the server has, stops the merge. *)
let test_a_merged_row_is_the_fleet_read_after_the_write () =
  let module Decode = Masc.Tui_decode_memory_health in
  let base = fresh_dir "masc-memory-health-merge" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [ fact "A" ]);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"beta" [ fact "B1"; fact "B2" ]);
  let fleet () =
    match Decode.decode_memory_health_snapshot (Health.keeper_memory_health_http_json ~base_path:base) with
    | Ok snapshot -> snapshot
    | Error detail -> Alcotest.fail detail
  in
  let held = fleet () in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [ fact "A"; fact "A2"; fact "A3" ]);
  let row_answer keeper =
    match
      Decode.decode_memory_health_row ~keeper
        (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper)
    with
    | Ok answer -> answer
    | Error detail -> Alcotest.fail detail
  in
  let answer = row_answer "alpha" in
  let row =
    match answer.Decode.mhr_keeper with
    | Decode.Row_present row -> row
    | Decode.Row_refused refusal -> Alcotest.fail refusal.Decode.mkr_reason
    | Decode.Row_absent -> Alcotest.fail "a listed Keeper has no row"
  in
  let observed_now (snapshot : Decode.memory_health_snapshot) =
    { snapshot with Decode.mhs_generated_at = 0.0 }
  in
  (match
     Decode.with_keeper_row held ~generated_at:answer.Decode.mhr_generated_at ~keeper_id:"alpha"
       (Some row)
   with
   | Some merged ->
     Alcotest.(check bool) "the merged answer is the fleet read after the write" true
       (observed_now merged = observed_now (fleet ()));
     Alcotest.(check bool) "it is observed when the row was" true
       (merged.Decode.mhs_generated_at >= answer.Decode.mhr_generated_at)
   | None -> Alcotest.fail "a row merges into an answer with no refused row");
  (* A removal answer carries the time it was read, the same as a present one
     ([masc_tui.ml] passes [mhr_generated_at] on both branches). Passing 0.0
     here made this a stale answer, and [with_keeper_row] refuses a stale one
     before it looks at the row at all (#50852). *)
  (match Decode.with_keeper_row held ~generated_at:answer.Decode.mhr_generated_at ~keeper_id:"beta" None with
   | Some removed ->
     Alcotest.(check (list string)) "a Keeper that left loses its row" [ "alpha" ]
       (List.map (fun (keeper : Decode.memory_keeper_health) -> keeper.Decode.mkh_keeper_id)
          removed.Decode.mhs_keepers);
     Alcotest.(check int) "and the totals count the rows left"
       (List.fold_left
          (fun total (keeper : Decode.memory_keeper_health) -> total + keeper.Decode.mkh_facts)
          0 removed.Decode.mhs_keepers)
       removed.Decode.mhs_total_facts
   | None -> Alcotest.fail "a removal merges into an answer with no refused row");
  let refused name = { Decode.mkr_keeper_id = Some name; mkr_reason = "refused" } in
  (* These two read the answer just fetched, so they carry its time too. With
     0.0 the first one was refused for staleness rather than for gamma's
     refused row, and passed without ever reaching the check it names. *)
  Alcotest.(check bool) "another Keeper's refused row stops the merge" true
    (Option.is_none
       (Decode.with_keeper_row
          { held with Decode.mhs_refused_keepers = [ refused "gamma" ] }
          ~generated_at:answer.Decode.mhr_generated_at ~keeper_id:"alpha" (Some row)));
  Alcotest.(check bool) "the Keeper's own refused row is replaced by its row" true
    (Option.is_some
       (Decode.with_keeper_row
          { held with Decode.mhs_refused_keepers = [ refused "alpha" ] }
          ~generated_at:answer.Decode.mhr_generated_at ~keeper_id:"alpha" (Some row)));
  Alcotest.(check bool) "a row answer for another Keeper is refused" true
    (Result.is_error
       (Decode.decode_memory_health_row ~keeper:"beta"
          (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"alpha")));
  Alcotest.(check bool) "an unlisted Keeper's answer decodes as no row" true
    (match (row_answer "absent").Decode.mhr_keeper with
     | Decode.Row_absent -> true
     | Decode.Row_present _ | Decode.Row_refused _ -> false)
;;

let test_memory_health_reloads_only_the_changed_keeper () =
  let base = fresh_dir "masc-memory-health-incremental" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "alpha one"]);
  ignore (write_snapshot ~keepers_dir ~keeper_id:"beta" [fact "beta one"]);
  let reads = Hashtbl.create 2 in
  let count keeper_id =
    Hashtbl.replace reads keeper_id (1 + Option.value ~default:0 (Hashtbl.find_opt reads keeper_id))
  in
  let read_count keeper_id = Option.value ~default:0 (Hashtbl.find_opt reads keeper_id) in
  Health.For_testing.with_runtime
    ~keeper_health:(fun ~config ~keepers_dir keeper_id ->
      count keeper_id;
      Health.For_testing.keeper_health ~config ~keepers_dir keeper_id)
    (fun () ->
      ignore (Health.keeper_memory_health_http_json ~base_path:base);
      ignore (Health.keeper_memory_health_http_json ~base_path:base);
      Alcotest.(check int) "alpha is cold once" 1 (read_count "alpha");
      Alcotest.(check int) "beta is cold once" 1 (read_count "beta");
      ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "alpha one"; fact "alpha two"]);
      let json = Health.keeper_memory_health_http_json ~base_path:base in
      Alcotest.(check int) "only alpha is refreshed" 2 (read_count "alpha");
      Alcotest.(check int) "beta is not reloaded" 1 (read_count "beta");
      Alcotest.(check int) "the committed alpha revision is visible" 2
        (int_field "revision" (keeper_obj "alpha" json));
      ignore (Health.keeper_memory_health_http_json ~base_path:base);
      Alcotest.(check int) "alpha is warm too" 2 (read_count "alpha");
      Alcotest.(check int) "beta remains warm" 1 (read_count "beta"))
;;

let test_row_health_reads_use_cache_and_invalidate () =
  let base = fresh_dir "masc-memory-health-row-cache" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "alpha one"]);
  let attempts = ref 0 in
  Health.For_testing.with_runtime
    ~keeper_health:(fun ~config ~keepers_dir keeper_id ->
      incr attempts;
      Health.For_testing.keeper_health ~config ~keepers_dir keeper_id)
    (fun () ->
      ignore (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"alpha");
      ignore (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"alpha");
      Alcotest.(check int) "the row is cold once and then warm" 1 !attempts;
      ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "alpha one"; fact "alpha two"]);
      ignore (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"alpha");
      Alcotest.(check int) "only the committed row is refreshed" 2 !attempts;
      ignore (Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:"alpha");
      Alcotest.(check int) "the refreshed row is warm" 2 !attempts)
;;

let test_cold_health_read_and_commit_do_not_deadlock () =
  let base = fresh_dir "masc-memory-health-lock-order" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "before commit"]);
  let cold_health = Health.For_testing.keeper_health
      ~config:(Masc.Workspace.default_config base) ~keepers_dir "alpha" in
  let read_started = Atomic.make false in
  let allow_return = Atomic.make false in
  let writer_finished = Atomic.make false in
  let attempts = ref 0 in
  let wait_for_commit () =
    let deadline = Unix.gettimeofday () +. 2.0 in
    let rec wait () =
      if Atomic.get writer_finished then true
      else if Unix.gettimeofday () >= deadline then false
      else (Unix.sleepf 0.005; wait ())
    in
    wait ()
  in
  Health.For_testing.with_runtime
    ~keeper_health:(fun ~config ~keepers_dir keeper_id ->
      incr attempts;
      if !attempts = 1 then begin
        Atomic.set read_started true;
        while not (Atomic.get allow_return) do Unix.sleepf 0.001 done;
        cold_health
      end else
        Health.For_testing.keeper_health ~config ~keepers_dir keeper_id)
    (fun () ->
      let reader = Domain.spawn (fun () ->
        Health.keeper_memory_health_http_json ~base_path:base)
      in
      while not (Atomic.get read_started) do Unix.sleepf 0.001 done;
      let writer = Domain.spawn (fun () ->
        Fun.protect
          ~finally:(fun () -> Atomic.set writer_finished true)
          (fun () ->
            ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha"
              [fact "before commit"; fact "after commit"])))
      in
      let finished_before_return = wait_for_commit () in
      Atomic.set allow_return true;
      Domain.join writer;
      let json = Domain.join reader in
      Alcotest.(check bool) "commit finished before the cold read resumed" true finished_before_return;
      Alcotest.(check int) "the newer commit wins over the cold read" 2
        (int_field "revision" (keeper_obj "alpha" json));
      Alcotest.(check int) "the superseded read was retried" 2 !attempts)
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "current snapshot"
      , [ Alcotest.test_case "a write reloads only its own Keeper" `Quick
            test_memory_health_reloads_only_the_changed_keeper
        ; Alcotest.test_case "row reads use cache and invalidate on writes" `Quick
            test_row_health_reads_use_cache_and_invalidate
        ; Alcotest.test_case "cold health read and commit do not deadlock" `Quick
            test_cold_health_read_and_commit_do_not_deadlock
        ; Alcotest.test_case "one Keeper's row is its fleet row" `Quick
            test_one_keepers_row_is_its_fleet_row
        ; Alcotest.test_case "the totals count the rows" `Quick test_totals_count_the_rows
        ; Alcotest.test_case "a merged row is the fleet read after the write" `Quick
            test_a_merged_row_is_the_fleet_read_after_the_write
        ; Alcotest.test_case "curator canonical owners and malformed config" `Quick
            test_curator_inventory_canonical_owner_discovery
        ; Alcotest.test_case "curator inventory binds committed sources and retractions" `Quick
            test_curator_inventory_binds_actual_commits
        ; Alcotest.test_case "workspace context malformed paths and source snapshot" `Quick
            test_workspace_context_path_errors_and_source_snapshot
        ; Alcotest.test_case "workspace context discovery not directory" `Quick
            test_workspace_context_discovery_not_directory
        ; Alcotest.test_case "explicit base path" `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ; Alcotest.test_case "revision bytes and delta" `Quick
            test_reports_revision_snapshot_bytes_and_latest_delta
        ; Alcotest.test_case "derived facts and support invalidations" `Quick
            test_reports_derived_facts_and_support_invalidations
        ; Alcotest.test_case "journal unreadable is not empty" `Quick
            test_journal_outcome_distinguishes_unreadable_from_empty
        ; Alcotest.test_case "journal failure retains evidence and recovers" `Quick
            test_journal_failure_keeps_evidence_and_recovers_without_another_commit
        ; Alcotest.test_case "corrupt snapshot visible" `Quick
            test_corrupt_snapshot_is_visible_as_read_error
        ; Alcotest.test_case "sort and empty store" `Quick
            test_sorts_by_snapshot_bytes_and_handles_empty_store
        ; Alcotest.test_case "configured keeper without snapshot" `Quick
            test_configured_keeper_without_snapshot_gets_row
        ; Alcotest.test_case "librarian starvation error alert" `Quick
            test_librarian_starvation_is_error_alert
        ; Alcotest.test_case "librarian failures warn alert" `Quick
            test_librarian_failures_with_snapshot_is_warn_alert
        ; Alcotest.test_case "toml name override canonical identity" `Quick
            test_toml_name_override_uses_canonical_identity
        ; Alcotest.test_case "source-only snapshot counted" `Quick
            test_source_only_snapshot_is_enumerated_and_counted
        ; Alcotest.test_case "corrupt source snapshot visible" `Quick
            test_corrupt_source_snapshot_is_visible
        ] )
    ]
;;
