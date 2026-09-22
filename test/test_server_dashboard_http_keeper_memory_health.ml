(** Regression tests for current Memory OS fleet-health projection. *)

module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module SourceCurrent = Masc.Keeper_memory_source_current
module Metrics = Masc.Otel_metric_store
module KeeperMetrics = Keeper_metrics
module Health = Server_dashboard_http_keeper_memory_health

let test_now = 1_700_000_000.0
let fresh_dir prefix = Filename.temp_dir prefix ""

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

let write_snapshot ~keepers_dir ~keeper_id facts =
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
    ~now:test_now
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

let float_option_field name json =
  match assoc_field name json with
  | Some `Null -> None
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (float_of_int n)
  | _ -> Alcotest.failf "expected float-or-null field %S" name
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
    "keeper.memory_os.current_health.v7"
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

(* RFC librarian-lifecycle §4.9. No loop runs in this test process, so the
   keeper has no measurement: the row says "not measured" rather than zero,
   and the counts are absent rather than a number nothing took. The journal
   and the snapshot's own source still say when the Librarian last succeeded
   and what it last failed with. *)
let test_reports_the_librarian_position_without_a_loop () =
  let base = fresh_dir "masc-memory-health-librarian" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "librarian-" ^ Filename.basename base in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "librarian fact" ]);
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  let librarian = member "librarian" keeper in
  Alcotest.(check bool) "state is not measured" true (is_null (member "state" librarian));
  Alcotest.(check bool)
    "atoms are not counted"
    true
    (is_null (member "unread_atom_turns" librarian));
  Alcotest.(check bool)
    "official turns are not counted"
    true
    (is_null (member "unread_official_turns" librarian));
  Alcotest.(check (option (float 0.)))
    "the snapshot the Librarian wrote is its last success"
    (Some test_now)
    (float_option_field "last_success_at" librarian);
  Alcotest.(check bool)
    "no failure is newer than that success"
    true
    (is_null (member "last_failure_kind" librarian));
  Alcotest.(check bool) "unknown keeper makes fleet unread unknown" true
    (is_null (member "librarian_unread_turns" (totals json)));
  Alcotest.(check int)
    "a keeper with no measurement is not a stopped one"
    0
    (int_field "librarian_stopped_keepers" (alert_summary json));
  Alcotest.(check (list string)) "no alert" [] (List.map (string_field "code") (list_field "alerts" keeper));
  Current.append_librarian_failure
    ~keepers_dir
    ~keeper_id
    ~now:(test_now +. 60.)
    ~trace_id:"health-test"
    ~kind:Current.Exact_execution_failure
    ~detail:"the lane refused"
    ~snapshot_present:true;
  let after_failure = Health.keeper_memory_health_http_json ~base_path:base in
  Alcotest.(check string)
    "the journal's last line names the failure"
    "exact_execution_failure"
    (string_field "last_failure_kind" (member "librarian" (keeper_obj keeper_id after_failure)))
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

(* The pre-librarian snapshot read failure aborts before the librarian runs
   and increments the counter under its own site label; the health row must
   count it or a keeper with a corrupt first snapshot reports failure-free. *)
let test_counts_snapshot_read_site_failures () =
  let base = fresh_dir "masc-memory-health-readsite" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "readfail-" ^ Filename.basename base in
  write_keeper_config ~keepers_dir ~keeper_id ();
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryOsLibrarianFailures)
    ~labels:[ "keeper", keeper_id; "site", "memory_os_current_read" ]
    ~delta:2.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check int)
    "read-site failures counted"
    2
    (int_field "librarian_failures" keeper);
  Alcotest.(check (list string))
    "starvation error raised"
    [ "librarian_starvation" ]
    (list_field "alerts" keeper |> List.map (string_field "code"))
;;

let test_workspace_context_preserves_sources_and_failures () =
  let base = fresh_dir "workspace-memory-context" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    let first = write_snapshot ~keepers_dir ~keeper_id:"writer" [ fact "Chapter one is drafted" ] in
    let second = write_snapshot ~keepers_dir ~keeper_id:"reviewer" [ fact "Chapter one needs revision" ] in
    Fs_compat.save_file
      (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"unreadable") "{broken";
    let context = Health.workspace_memory_context_http_json ~base_path:base in
    Alcotest.(check (list string)) "all owners remain separate"
      [ "reviewer"; "unreadable"; "writer" ] (keeper_ids context);
    let field name json = Yojson.Safe.Util.member name json in
    let writer = keeper_obj "writer" context |> field "ordinary" in
    Alcotest.(check string) "available" "available" (string_field "status" writer);
    Alcotest.(check string) "exact writer snapshot" (Yojson.Safe.to_string (Current.to_json first))
      (Yojson.Safe.to_string (field "snapshot" writer));
    Alcotest.(check string) "conflicting reviewer claim preserved"
      (Yojson.Safe.to_string (Current.to_json second))
      (Yojson.Safe.to_string (keeper_obj "reviewer" context |> field "ordinary" |> field "snapshot"));
    Alcotest.(check string) "corrupt is unavailable" "unavailable"
      (keeper_obj "unreadable" context |> field "ordinary" |> string_field "status");
    Alcotest.(check string) "absent source store is missing" "missing"
      (keeper_obj "writer" context |> field "source_bound" |> string_field "status");
    Alcotest.(check string) "no current source validation claim" "stored_bindings_not_revalidated"
      (string_field "source_validation" context))
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
    let inventory = Inventory.collect ~base_path:base |> require_ok |> Inventory.to_json in
    Alcotest.(check (list string)) "canonical owner is not duplicated under filename alias"
      ["actual"] (list_field "snapshots" inventory |> List.map (string_field "keeper_id")
        |> List.sort_uniq String.compare);
    Alcotest.(check (list string)) "invalid config basename remains visible in missing-store gaps"
      ["actual"; "broken"] (list_field "gaps" inventory |> List.map (string_field "keeper_id")
        |> List.sort_uniq String.compare))
;;

let test_curator_inventory_binds_actual_commits () =
  let module Inventory = Masc.Workspace_memory_context in
  let module Proposals = Masc.Workspace_memory_proposal in
  let base = fresh_dir "workspace-curator-inventory" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
    ignore (write_snapshot ~keepers_dir ~keeper_id:"writer" [fact "Draft has three criteria"]);
    ignore (write_snapshot ~keepers_dir ~keeper_id:"reviewer" [fact "Criteria are not files"]);
    let before = Inventory.collect ~base_path:base |> require_ok in
    let unchanged = Inventory.collect ~base_path:base |> require_ok in
    Alcotest.(check string) "observation time does not trigger another model pass"
      (Inventory.fingerprint before) (Inventory.fingerprint unchanged);
    let captured_input = Inventory.to_json before in
    let source_ids = list_field "sources" captured_input |> List.map (string_field "source_id") in
    let proposal = `Assoc ["shared_claims", `List []; "conflicts", `List [];
      "excluded", `List (List.map (fun id -> `Assoc ["source_id", `String id;
        "reason", `String "This test does not make a semantic decision"]) source_ids)] in
    let bound = Inventory.proposal_json before proposal in
    ignore (Proposals.decode bound |> require_ok);
    ignore (write_snapshot ~keepers_dir ~keeper_id:"writer" []);
    let changed = Inventory.collect ~base_path:base |> require_ok in
    Alcotest.(check bool) "actual retraction changes the inventory" true
      (Inventory.fingerprint before <> Inventory.fingerprint changed);
    Alcotest.(check bool) "in-flight input remains immutable" true
      (Yojson.Safe.equal captured_input (Inventory.to_json before));
    let after_json = Inventory.to_json changed in
    let snapshots = list_field "snapshots" after_json in
    let writer = List.find (fun row -> string_field "keeper_id" row = "writer") snapshots in
    let writer_id = string_field "snapshot_id" writer in
    let evidence = list_field "sources" after_json |> List.filter (fun row ->
      string_field "snapshot_id" row = writer_id) in
    Alcotest.(check bool) "empty current facts retain retraction evidence" true
      (List.exists (fun row -> Yojson.Safe.Util.member "evidence_path" row = `List [`String "change"]) evidence);
    Fs_compat.save_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"reviewer") "{broken";
    let unavailable = Inventory.collect ~base_path:base |> require_ok |> Inventory.to_json in
    Alcotest.(check bool) "corruption stays a gap rather than an empty successful store" true
      (list_field "gaps" unavailable |> List.exists (fun row ->
        string_field "keeper_id" row = "reviewer" && string_field "store" row = "ordinary"
        && string_field "status" (Yojson.Safe.Util.member "observation" row) = "unavailable")))
;;

let test_context_cycle_separates_saved_and_prepared () =
  let module O = Masc.Keeper_continuity_observation in
  let module S = Masc.Librarian_continuity_snapshot in
  let module B = Masc.Keeper_turn_boundaries in
  let base = fresh_dir "masc-context-health" in
  let config = Masc.Workspace.default_config base in
  let keeper_name = "context-observed" in
  Fun.protect ~finally:(fun () -> O.forget ~config ~keeper_name; Fs_compat.remove_tree base) @@ fun () ->
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  let cycle () = member "context_cycle"
    (keeper_obj keeper_name (Health.keeper_memory_health_http_json ~base_path:base)) in
  Alcotest.(check bool) "no prepared request inferred from saved state" true
    (is_null (member "prepared" (cycle ())));
  let messages = [Agent_core.Types.make_message ~role:Agent_core.Types.User
    [Agent_core.Types.Text "PRIVATE_CONVERSATION_TEXT"]] in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let position = B.position_of_messages messages |> get in
  let trace_id = "saved-trace" in
  let lines = [1, Ok {B.recorded_at = test_now; event = B.Turn_ended
    {turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}}] in
  let snapshot = S.capture ~trace_id ~lines ~messages ~working_state:"PRIVATE_WORKING_STATE"
    |> Result.map_error S.error_to_string |> get in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  O.record ~config ~keeper_name
    {prepared_at = test_now; runtime_id = "fixture-runtime";
     input = O.Summarized {trace_id = "previous-trace"; end_atom = 4; boundary_line = 7}; request_bytes = 2048};
  O.record_synthesis ~config ~keeper_name
    {observed_at=test_now; trace_id=Some trace_id; state=O.Running;
     range=Some {start_atom=1;end_atom=2;completed_end_atom=8}};
  let observed = cycle () in
  Alcotest.(check string) "synthesis is independent of ordinary drain" "running"
    (string_field "state" (member "synthesis" observed));
  O.record_synthesis ~config ~keeper_name
    {observed_at=test_now; trace_id=Some trace_id; state=O.Cancelled;
     range=Some {start_atom=1;end_atom=2;completed_end_atom=8}};
  Alcotest.(check string) "cancellation replaces running observation" "cancelled"
    (string_field "state" (member "synthesis" (cycle ())));
  Alcotest.(check string) "saved identity comes from disk" trace_id
    (string_field "trace_id" (member "saved" observed));
  let prepared = member "prepared" observed in
  Alcotest.(check int) "prepared bytes are observed" 2048 (int_field "request_bytes" prepared);
  Alcotest.(check string) "prepared frontier is not replaced by newer saved frontier" "previous-trace"
    (string_field "trace_id" (member "frontier" (member "input" prepared)));
  let other = Masc.Workspace.default_config (Filename.concat base "other-runtime") in
  Alcotest.(check bool) "observation does not cross runtimes" true
    (Option.is_none (O.latest ~config:other ~keeper_name));
  Out_channel.with_open_bin path (fun oc -> output_string oc "{PRIVATE_WORKING_STATE");
  let unreadable = cycle () in
  Alcotest.(check string) "corrupt state error exposes no source text" "snapshot_unreadable"
    (string_field "saved_read_error" unreadable);
  Alcotest.(check bool) "corrupt state has no saved frontier" true (is_null (member "saved" unreadable));
  Alcotest.(check bool) "prepared observation survives independent disk read failure" false
    (is_null (member "prepared" unreadable));
  O.forget ~config ~keeper_name;
  Alcotest.(check bool) "forgotten request is unknown" true (is_null (member "prepared" (cycle ())))
;;

(* RFC librarian-lifecycle §4.9: the durable round and the continuity round
   fall behind separately, so the screen carries both. A lag it cannot take
   reads as "cannot say" rather than as zero -- zero is what a caught-up
   keeper shows. *)
let test_the_continuity_lag_is_measured_or_says_it_cannot_be () =
  let module S = Masc.Librarian_continuity_snapshot in
  let module B = Masc.Keeper_turn_boundaries in
  let module P = Masc.Keeper_librarian_progress in
  let base = fresh_dir "masc-continuity-lag" in
  let config = Masc.Workspace.default_config base in
  let keeper_name = "continuity-lag" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) @@ fun () ->
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  let json () = Health.keeper_memory_health_http_json ~base_path:base in
  let librarian () = member "librarian" (keeper_obj keeper_name (json ())) in
  let lag () = member "continuity_unread_atoms" (librarian ()) in
  let lag_atoms () = int_field "continuity_unread_atoms" (librarian ()) in
  Alcotest.(check bool) "no snapshot cannot be compared" true (is_null (lag ()));
  Alcotest.(check int) "and the fleet counts it as unmeasured" 1
    (int_field "librarian_continuity_unmeasured" (totals (json ())));
  Alcotest.(check int) "with nothing summed for it" 0
    (int_field "librarian_continuity_unread_atoms" (totals (json ())));
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let messages =
    [ Agent_core.Types.make_message ~role:Agent_core.Types.User
        [ Agent_core.Types.Text "one atom" ] ]
  in
  let position = B.position_of_messages messages |> get in
  let last_atom_digest =
    match position with
    | B.Atom_history { last_atom_digest; _ } -> last_atom_digest
    | B.Empty_atom_history | B.No_atom_history | B.Stale_noop ->
      Alcotest.fail "fixture history has one atom"
  in
  let trace_id = "lag-trace" in
  let lines =
    [ ( 1
      , Ok
          { B.recorded_at = test_now
          ; event =
              B.Turn_ended
                { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
                ; history_at_start = B.Fresh_history
                ; position
                }
          } )
    ]
  in
  let snapshot =
    S.capture ~trace_id ~lines ~messages ~working_state:"working state"
    |> Result.map_error S.error_to_string
    |> get
  in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  let write_position ~trace_id ~end_atom =
    P.write ~keepers_dir ~keeper_id:keeper_name
      { P.position = { P.trace_id; end_atom; last_atom_digest }
      ; boundary_lines_seen = 1
      }
    |> Result.map_error P.write_error_to_string
    |> get
  in
  write_position ~trace_id ~end_atom:5;
  Alcotest.(check int) "the position past the snapshot is the lag" 4 (lag_atoms ());
  Alcotest.(check int) "and the fleet sums it" 4
    (int_field "librarian_continuity_unread_atoms" (totals (json ())));
  Alcotest.(check int) "with nothing left unmeasured" 0
    (int_field "librarian_continuity_unmeasured" (totals (json ())));
  write_position ~trace_id:"another-trace" ~end_atom:9;
  Alcotest.(check bool) "two traces are not comparable" true (is_null (lag ()));
  write_position ~trace_id ~end_atom:1;
  Alcotest.(check int) "a position level with the snapshot is caught up" 0 (lag_atoms ())
;;

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "current snapshot"
      , [ Alcotest.test_case "saved versus prepared context" `Quick
            test_context_cycle_separates_saved_and_prepared
        ; Alcotest.test_case "continuity lag measured or unknown" `Quick
            test_the_continuity_lag_is_measured_or_says_it_cannot_be
        ; Alcotest.test_case "curator canonical owners and malformed config" `Quick
            test_curator_inventory_canonical_owner_discovery
        ; Alcotest.test_case "curator inventory binds committed sources and retractions" `Quick
            test_curator_inventory_binds_actual_commits
        ; Alcotest.test_case "workspace context malformed paths and source snapshot" `Quick
            test_workspace_context_path_errors_and_source_snapshot
        ; Alcotest.test_case "workspace context discovery not directory" `Quick
            test_workspace_context_discovery_not_directory
        ; Alcotest.test_case "workspace context preserves sources and failures" `Quick
            test_workspace_context_preserves_sources_and_failures
        ; Alcotest.test_case "explicit base path" `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ; Alcotest.test_case "revision bytes and delta" `Quick
            test_reports_revision_snapshot_bytes_and_latest_delta
        ; Alcotest.test_case "derived facts and support invalidations" `Quick
            test_reports_derived_facts_and_support_invalidations
        ; Alcotest.test_case "librarian position without a loop" `Quick
            test_reports_the_librarian_position_without_a_loop
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
        ; Alcotest.test_case "snapshot read site failures counted" `Quick
            test_counts_snapshot_read_site_failures
        ; Alcotest.test_case "source-only snapshot counted" `Quick
            test_source_only_snapshot_is_enumerated_and_counted
        ; Alcotest.test_case "corrupt source snapshot visible" `Quick
            test_corrupt_source_snapshot_is_visible
        ] )
    ]
;;
