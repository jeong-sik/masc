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
    "keeper.memory_os.current_health.v3"
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

let test_reports_librarian_lane_busy_alert () =
  let base = fresh_dir "masc-memory-health-lane" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "lane-" ^ Filename.basename base in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "lane fact" ]);
  Metrics.inc_counter
    KeeperMetrics.(to_string MemoryLaneCoalesced)
    ~labels:[ "keeper", keeper_id; "lane", "librarian" ]
    ~delta:3.0
    ();
  let json = Health.keeper_memory_health_http_json ~base_path:base in
  let keeper = keeper_obj keeper_id json in
  Alcotest.(check int) "busy count" 3 (int_field "librarian_lane_busy" keeper);
  let alerts = list_field "alerts" keeper in
  Alcotest.(check (list string))
    "alert code"
    [ "librarian_lane_busy" ]
    (List.map (string_field "code") alerts);
  Alcotest.(check int)
    "summary busy keepers"
    1
    (int_field "librarian_lane_busy_keepers" (alert_summary json))
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

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health"
    [ ( "current snapshot"
      , [ Alcotest.test_case "explicit base path" `Quick
            test_uses_explicit_base_path_not_ambient_resolver
        ; Alcotest.test_case "revision bytes and delta" `Quick
            test_reports_revision_snapshot_bytes_and_latest_delta
        ; Alcotest.test_case "derived facts and support invalidations" `Quick
            test_reports_derived_facts_and_support_invalidations
        ; Alcotest.test_case "librarian lane busy alert" `Quick
            test_reports_librarian_lane_busy_alert
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
