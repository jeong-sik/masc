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
    "keeper.memory_os.current_health.v15"
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

(* RFC librarian-lifecycle §4.9. No loop runs in this test process, so the
   keeper has no measurement: the row says "not measured" rather than zero,
   and the counts are absent rather than a number nothing took. The journal
   still says when the Librarian last succeeded and what it last failed
   with. *)
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
    "the Librarian commit is its last success"
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
    "a failure after the last Librarian commit is shown"
    "exact_execution_failure"
    (string_field "last_failure_kind" (member "librarian" (keeper_obj keeper_id after_failure)))
;;

(* The outcome is folded from the lines appended since the last read; a
   journal that shrank is folded again from its start, and a removed one says
   nothing. *)
let test_journal_outcome_reads_appended_lines () =
  let base = fresh_dir "masc-memory-health-journal-outcome" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "outcome-" ^ Filename.basename base in
  let read () = Masc.Keeper_memory_journal_outcome.read ~keepers_dir ~keeper_id in
  let failure_kind (outcome : Masc.Keeper_memory_journal_outcome.t) =
    Option.map Masc.Keeper_memory_os_journal_codec.librarian_failure_kind_to_string outcome.last_failure in
  let empty = read () in
  Alcotest.(check bool) "no journal is no commit and no failure" true
    (Option.is_none empty.last_success_at && Option.is_none empty.last_failure);
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "librarian fact" ]);
  Alcotest.(check (option (float 0.))) "the Librarian commit is read" (Some test_now)
    (read ()).last_success_at;
  Current.append_librarian_failure ~keepers_dir ~keeper_id ~now:(test_now +. 60.)
    ~trace_id:"outcome-test" ~kind:Current.Exact_execution_failure ~detail:"refused"
    ~snapshot_present:true;
  let after_failure = read () in
  Alcotest.(check (option string)) "an appended failure is read" (Some "exact_execution_failure")
    (failure_kind after_failure);
  Alcotest.(check (option (float 0.))) "the earlier commit is kept" (Some test_now)
    after_failure.last_success_at;
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let lines = In_channel.with_open_bin path In_channel.input_all |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "") in
  Out_channel.with_open_bin path (fun channel ->
    Out_channel.output_string channel (List.nth lines (List.length lines - 1) ^ "\n"));
  let shrunk = read () in
  Alcotest.(check bool) "a shrunk journal is read from its start" true
    (Option.is_none shrunk.last_success_at
     && failure_kind shrunk = Some "exact_execution_failure");
  Sys.remove path;
  let removed = read () in
  Alcotest.(check bool) "a removed journal says nothing" true
    (Option.is_none removed.last_success_at && Option.is_none removed.last_failure)
;;

(* A line still being written, or left by a writer that stopped mid-line, is
   not read yet. The answer stays what the complete lines say, and the next
   append, which cuts the fragment first, is read. *)
let test_journal_outcome_waits_for_a_torn_line () =
  let base = fresh_dir "masc-memory-health-journal-torn" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "torn-" ^ Filename.basename base in
  let read () = Masc.Keeper_memory_journal_outcome.read ~keepers_dir ~keeper_id in
  let failure_kind (outcome : Masc.Keeper_memory_journal_outcome.t) =
    Option.map Masc.Keeper_memory_os_journal_codec.librarian_failure_kind_to_string outcome.last_failure in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "librarian fact" ]);
  Current.append_librarian_failure ~keepers_dir ~keeper_id ~now:(test_now +. 60.)
    ~trace_id:"torn-test" ~kind:Current.Exact_execution_failure ~detail:"refused"
    ~snapshot_present:true;
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path (fun channel ->
    Out_channel.output_string channel "{\"kind\":");
  let check_complete_lines label (outcome : Masc.Keeper_memory_journal_outcome.t) =
    Alcotest.(check (option (float 0.))) (label ^ ": the commit") (Some test_now)
      outcome.last_success_at;
    Alcotest.(check (option string)) (label ^ ": the failure after it")
      (Some "exact_execution_failure") (failure_kind outcome)
  in
  check_complete_lines "first read" (read ());
  check_complete_lines "read again" (read ());
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "librarian fact"; fact "another fact" ]);
  let after_commit = read () in
  Alcotest.(check (option string)) "the commit after the cut clears the failure" None
    (failure_kind after_commit);
  Alcotest.(check bool) "the commit after the cut is read" true
    (Option.is_some after_commit.last_success_at)
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

(* A keeper's own [keeper_memory_write] journals a committed line too. It is
   not a Librarian pass, so it must neither hide the Librarian failure before
   it nor wipe the Librarian success before that. *)
let test_librarian_failure_then_explicit_write_keeps_both () =
  let base = fresh_dir "masc-memory-health-librarian-write" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "librarian-write-" ^ Filename.basename base in
  ignore (write_snapshot ~keepers_dir ~keeper_id [ fact "librarian fact" ]);
  Current.append_librarian_failure
    ~keepers_dir
    ~keeper_id
    ~now:(test_now +. 60.)
    ~trace_id:"health-test"
    ~kind:Current.Exact_execution_failure
    ~detail:"the lane refused"
    ~snapshot_present:true;
  let expected_revision =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | Ok (Some snapshot) -> Some snapshot.revision
    | Ok None -> Alcotest.fail "the Librarian snapshot is missing"
    | Error detail -> Alcotest.fail detail
  in
  Current.replace
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    ~now:(test_now +. 120.)
    ~source:{ Current.kind = Current.Explicit_write; trace_id = "keeper-write" }
    ~facts:[ fact "librarian fact"; fact "keeper wrote this" ]
    ()
  |> require_ok
  |> ignore;
  let librarian =
    member "librarian" (keeper_obj keeper_id (Health.keeper_memory_health_http_json ~base_path:base))
  in
  Alcotest.(check string)
    "the failure before the keeper's write is still shown"
    "exact_execution_failure"
    (string_field "last_failure_kind" librarian);
  Alcotest.(check (option (float 0.)))
    "the last success is the Librarian's commit, not the keeper's write"
    (Some test_now)
    (float_option_field "last_success_at" librarian)
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
    Alcotest.(check string) "observation time does not trigger another model pass"
      (Inventory.fingerprint before) (Inventory.fingerprint unchanged);
    let captured = Ledger.reconcile Ledger.empty (Inventory.keepers before) in
    Alcotest.(check int) "both current facts are pending" 2 (List.length captured.new_facts);
    ignore (write_snapshot ~keepers_dir ~keeper_id:"writer" []);
    let changed = Inventory.collect ~base_path:base |> require_ok in
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
  let cycle () =
    (* This fixture writes the snapshot and turn records itself, so no writer
       announces the commit [install] listens for. *)
    Health.For_testing.invalidate ~base_path:base ~keeper:keeper_name;
    member "context_cycle"
      (keeper_obj keeper_name (Health.keeper_memory_health_http_json ~base_path:base)) in
  Alcotest.(check bool) "no prepared request inferred from saved state" true
    (is_null (member "prepared" (cycle ())));
  let messages = [Agent_core.Types.make_message ~role:Agent_core.Types.User
    [Agent_core.Types.Text "PRIVATE_CONVERSATION_TEXT"]] in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let position = B.position_of_messages messages |> get in
  let trace_id = "saved-trace" in
  let lines = [1, Ok {B.recorded_at = test_now; event = B.Turn_ended
    { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}}] in
  let snapshot = S.capture ~unread_messages:[] ~trace_id ~lines ~messages ~working_state:"PRIVATE_WORKING_STATE"
    |> Result.map_error S.error_to_string |> get in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  O.record ~config ~keeper_name
    {prepared_at = test_now; runtime_id = "fixture-runtime";
     input = O.Summarized {trace_id = "previous-trace"; end_atom = 4; boundary_line = 7}; request_bytes = 2048};
  O.record_synthesis ~config ~keeper_name
    {observed_at=test_now; trace_id=Some trace_id; state=O.Running; stop_reason=None;
     range=Some {start_atom=1;end_atom=2;completed_end_atom=8}};
  let observed = cycle () in
  Alcotest.(check string) "synthesis is independent of ordinary drain" "running"
    (string_field "state" (member "synthesis" observed));
  O.record_synthesis ~config ~keeper_name
    {observed_at=test_now; trace_id=Some trace_id; state=O.Cancelled; stop_reason=None;
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

(* A snapshot that stopped moving while the Librarian kept reading is what a
   request pays for: it starts at the cut and carries every atom up to the
   position. The cut alone cannot say that, so the position is read from its
   own file and reported beside it (#37793). *)
let test_unread_evidence_is_observed_without_publication () =
  let module H = Masc.Keeper_librarian_unread in
  let module S = Masc.Librarian_continuity_snapshot in
  let module B = Masc.Keeper_turn_boundaries in
  let module D = Masc.Tui_decode_memory_health in
  let base = fresh_dir "masc-unread-health" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) @@ fun () ->
  let config = Masc.Workspace.default_config base in
  let keeper_name = "unread-observed" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  let ledger = Current.unread_ledger_path ~keepers_dir ~keeper_id:keeper_name in
  Alcotest.(check bool) "an absent ledger is only observed" true
    (Current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name = Ok []);
  Alcotest.(check bool) "reading absence creates no ledger" false (Sys.file_exists ledger);
  let trace_id = "unread-health-trace" in
  let messages = [Agent_core.Types.make_message ~role:Agent_core.Types.User
    [Agent_core.Types.Text "PRIVATE_UNREAD_ORIGINAL"]] in
  let position = B.position_of_messages messages |> require_ok in
  let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1 in
  let lines = [1, Ok {B.recorded_at=test_now;event=B.Turn_ended
    {task_context=Masc.Keeper_turn_task_context.No_task;turn_ref;
     history_at_start=B.Fresh_history;position}}] in
  let atom = H.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:0 ~message_in_atom:0
      ~messages ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] |> require_ok in
  let official = H.for_official_turn ~turn_ref ~boundary_line:2 ~message_in_turn:0 ~messages
      ~reasons:[Masc.Keeper_librarian_input_refusal.Input_capacity] |> require_ok in
  let snapshot = S.capture ~unread_messages:[atom] ~trace_id ~lines ~messages
      ~working_state:"PRIVATE_DERIVED_STATE" |> Result.map_error S.error_to_string |> require_ok in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  let range : Current.official_range_id = {receipt_scope="health-fixture";
    after_boundary_line=0;turns=[2,turn_ref];unread_messages=[official]} in
  ignore (Current.apply_disposition ~pass:Masc.Keeper_memory_commit_pass.Durable ~keepers_dir ~keeper_id:keeper_name ~now:test_now
    ~source ~revisions:[] ~absorbed:[] ~official_range_id:range ~new_claims:[] () |> require_ok);
  ignore (Current.committed_unread_messages ~keepers_dir ~keeper_id:keeper_name |> require_ok);
  let files = [path;ledger;Current.durable_range_receipt_path ~keepers_dir ~keeper_id:keeper_name] in
  let before = List.map Fs_compat.load_file files in
  let produced = Health.keeper_memory_health_http_json ~base_path:base in
  let fields = match produced with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "the production health response must be an object" in
  let without_execution = List.remove_assoc "execution" fields in
  List.iter (fun (label, invalid) ->
    Alcotest.(check bool) label true
      (Result.is_error (D.decode_memory_health_snapshot invalid)))
    [ "missing execution refuses the response", `Assoc without_execution
    ; "duplicate execution refuses the response",
      `Assoc (("execution", member "execution" produced) :: fields)
    ; "null execution refuses the response", `Assoc (("execution", `Null) :: without_execution)
    ; "scalar execution refuses the response", `Assoc (("execution", `String "ok") :: without_execution)
    ; "array execution refuses the response", `Assoc (("execution", `List []) :: without_execution)
    ; "unknown root field still refuses the response", `Assoc (("unexpected", `Null) :: fields)
    ];
  let reading () =
    (* This fixture writes the snapshot and the ledger itself, so no writer
       announces the commit [install] listens for. *)
    Health.For_testing.invalidate ~base_path:base ~keeper:keeper_name;
    let json = Health.keeper_memory_health_http_json ~base_path:base in
    let decoded = D.decode_memory_health_snapshot json |> require_ok in
    match List.find_opt (fun (row : D.memory_keeper_health) -> row.mkh_keeper_id=keeper_name) decoded.mhs_keepers with
    | Some row -> row.mkh_context_cycle
    | None -> Alcotest.fail "production health projection lost the Keeper row" in
  let observed = reading () in
  Alcotest.(check bool) "HTTP projection reaches TUI with exact snapshot evidence" true
    (observed.mcc_unread_snapshot = Ok [atom]);
  Alcotest.(check bool) "official evidence remains separate from the snapshot" true
    (observed.mcc_unread_memory = Ok [official]);
  Alcotest.(check (list string)) "diagnostics do not rewrite stores" before
    (List.map Fs_compat.load_file files);
  Fs_compat.save_file ledger "{";
  let partial = reading () in
  Alcotest.(check bool) "unreadable Memory does not hide known snapshot evidence" true
    (partial.mcc_unread_memory = Error () && partial.mcc_unread_snapshot = Ok [atom]);
  Fs_compat.save_file ledger (List.nth before 1);
  Fs_compat.save_file path "{";
  let partial = reading () in
  Alcotest.(check bool) "unreadable snapshot does not hide known Memory evidence" true
    (partial.mcc_unread_snapshot = Error () && partial.mcc_unread_memory = Ok [official])
;;

let test_context_cycle_reads_the_librarian_position_beside_the_cut () =
  let module S = Masc.Librarian_continuity_snapshot in
  let module B = Masc.Keeper_turn_boundaries in
  let module P = Masc.Keeper_librarian_progress in
  let module D = Masc.Tui_decode_memory_health in
  let base = fresh_dir "masc-context-lag" in
  let config = Masc.Workspace.default_config base in
  let keeper_name = "context-lagging" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) @@ fun () ->
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  let cycle ?(invalidate = true) () =
    (* [P.write] announces its commit, and the observer [install] wires is
       what must empty the row afterwards; pre-empting that with a manual
       invalidation would hide the path this change repairs. The snapshot
       below is written straight to a file, though, and no writer announces
       that one, so the caller says which kind of read it is. *)
    if invalidate then Health.For_testing.invalidate ~base_path:base ~keeper:keeper_name;
    let json = Health.keeper_memory_health_http_json ~base_path:base in
    json, member "context_cycle" (keeper_obj keeper_name json) in
  let decoded_cycle json : D.memory_context_cycle =
    let decoded = D.decode_memory_health_snapshot json |> require_ok in
    match List.find_opt
        (fun (row : D.memory_keeper_health) -> String.equal row.mkh_keeper_id keeper_name)
        decoded.mhs_keepers with
    | Some row -> row.mkh_context_cycle
    | None -> Alcotest.fail "the production context cycle must reach the TUI" in
  let initial_json, initial = cycle () in
  Alcotest.(check bool) "a keeper that has read nothing has no position" true
    (is_null (member "read_position" initial));
  Alcotest.(check bool) "and no read error to explain it" true
    (is_null (member "read_position_read_error" initial));
  let initial_reading = decoded_cycle initial_json in
  Alcotest.(check bool) "no progress is distinct from an unreadable progress file" true
    (initial_reading.mcc_read_position = None
     && not initial_reading.mcc_read_position_unreadable);
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let messages = [Agent_core.Types.make_message ~role:Agent_core.Types.User
    [Agent_core.Types.Text "the turn the snapshot covers"]] in
  let position = B.position_of_messages messages |> get in
  let trace_id = "lagging-trace" in
  let lines = [1, Ok {B.recorded_at = test_now; event = B.Turn_ended
    { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}}] in
  let snapshot = S.capture ~unread_messages:[] ~trace_id ~lines ~messages ~working_state:"a working state"
    |> Result.map_error S.error_to_string |> get in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  (* The Librarian read past its own cut: the durable round moved while the
     continuity round did not commit. *)
  (* Written where the Librarian writes it: the runtime keepers dir, not the
     config dir the journal and snapshots sit in. The first version of this
     test wrote through the same wrong root the handler read, and passed
     while every live position came back absent. *)
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  Alcotest.(check bool) "the position lives under a different root than the journal" false
    (String.equal runtime_keepers_dir keepers_dir);
  P.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    {P.position = {trace_id; end_atom = 12887; last_atom_digest = String.make 64 'a'};
     boundary_lines_seen = 385}
  |> Result.map_error P.write_error_to_string |> get;
  (* No manual invalidation: [P.write] fires the commit observer for the
     runtime root, and that observer has to be what empties the row. *)
  let observed_json, observed = cycle ~invalidate:false () in
  Alcotest.(check int) "the cut the request starts at" snapshot.S.end_atom
    (int_field "end_atom" (member "saved" observed));
  Alcotest.(check int) "the position that cut is read against" 12887
    (int_field "read_position" observed);
  Alcotest.(check bool) "a snapshot that is not being rewritten says nothing about it" true
    (is_null (member "rewriting_through" observed));
  let reading = decoded_cycle observed_json in
  Alcotest.(check (option int)) "the decoder preserves the durable read position"
    (Some 12887) reading.mcc_read_position;
  Alcotest.(check bool) "a readable position is confirmed" false
    reading.mcc_read_position_unreadable;
  Alcotest.(check (option int)) "a non-rewrite stays absent after decoding"
    None reading.mcc_rewriting_through;
  (* Mutate only the relationships this decoder owns, using the complete
     production response above instead of a second schema fixture. *)
  let replace_field name value = function
    | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
    | _ -> Alcotest.fail "the production value must be an object" in
  let rejects_cycle label invalid_cycle =
    let row = keeper_obj keeper_name observed_json
      |> replace_field "context_cycle" invalid_cycle in
    let invalid_json = replace_field "keepers" (`List [row]) observed_json in
    let decoded = D.decode_memory_health_snapshot invalid_json |> require_ok in
    Alcotest.(check bool) label true
      (List.exists
         (fun (refusal : D.memory_keeper_refusal) ->
           refusal.mkr_keeper_id = Some keeper_name)
         decoded.mhs_refused_keepers
       && not (List.exists
         (fun (row : D.memory_keeper_health) -> String.equal row.mkh_keeper_id keeper_name)
         decoded.mhs_keepers)) in
  rejects_cycle "a position cannot also carry a read failure"
    (replace_field "read_position_read_error" (`String "progress_unreadable") observed);
  rejects_cycle "a rewrite target must be beyond its saved cut"
    (replace_field "rewriting_through" (`Int snapshot.S.end_atom) observed);
  rejects_cycle "a rewrite target needs its saved snapshot"
    (observed |> replace_field "saved" `Null
      |> replace_field "rewriting_through" (`Int 12887));
  let rewriting = S.capture_checkpoint_prefix ~unread_messages:[]
      ~catch_up_end_atom:(Some 12887) ~trace_id ~lines ~messages
      ~working_state:"a snapshot being rewritten" ()
    |> Result.map_error S.error_to_string |> get in
  Yojson.Safe.to_file path (S.to_json rewriting);
  let rewriting_json, _ = cycle () in
  let rewriting_reading = decoded_cycle rewriting_json in
  Alcotest.(check (option int)) "the production rewrite target survives decoding"
    (Some 12887) rewriting_reading.mcc_rewriting_through;
  Alcotest.(check (option int)) "the rewrite keeps the independent read position"
    (Some 12887) rewriting_reading.mcc_read_position;
  (* An unreadable position file is why there is no number, which a keeper
     that has read nothing does not say. *)
  Out_channel.with_open_bin
    (P.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name)
    (fun oc -> output_string oc "{not json");
  let unreadable_json, unreadable = cycle () in
  Alcotest.(check string) "an unreadable position says so" "progress_unreadable"
    (string_field "read_position_read_error" unreadable);
  Alcotest.(check bool) "and carries no number" true (is_null (member "read_position" unreadable));
  Alcotest.(check int) "the cut is read independently of it" snapshot.S.end_atom
    (int_field "end_atom" (member "saved" unreadable));
  let unreadable_reading = decoded_cycle unreadable_json in
  Alcotest.(check bool) "the decoder retains why the number is absent" true
    (unreadable_reading.mcc_read_position = None
     && unreadable_reading.mcc_read_position_unreadable)
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
                { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
                ; history_at_start = B.Fresh_history
                ; position
                }
          } )
    ]
  in
  let snapshot =
    S.capture ~unread_messages:[] ~trace_id ~lines ~messages ~working_state:"working state"
    |> Result.map_error S.error_to_string
    |> get
  in
  let path = Masc.Keeper_librarian_continuity.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Yojson.Safe.to_file path (S.to_json snapshot);
  (* The runtime keepers dir, not the config one this handler otherwise reads.
     Writing through the same wrong root the reader used is what let the first
     version of this test pass while every live lag came back unmeasured. *)
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  Alcotest.(check bool) "the position lives under a different root than the journal" false
    (String.equal runtime_keepers_dir keepers_dir);
  let write_position ~trace_id ~end_atom =
    P.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
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

(* RFC librarian-lifecycle §4.10: the Librarian_stalled alarm on the health
   payload, from files alone. Nothing here runs a drain, so the in-memory
   measurement stays absent the whole time, as on a server that just
   started. The choice itself -- a position that does not fit, a Librarian
   that catches up -- is tested with Keeper_next_request_forecast.librarian_gap;
   this checks that the payload carries it. *)
let test_the_librarian_stalled_alarm_is_read_from_files () =
  let module P = Masc.Keeper_librarian_progress in
  let module B = Masc.Keeper_turn_boundaries in
  Eio_main.run @@ fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = fresh_dir "masc-librarian-stalled" in
  let config = Masc.Workspace.default_config base in
  let get = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let meta =
    Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "librarian-stalled" ]) |> get
  in
  let keeper_name = meta.name in
  let store = Masc.Keeper_types_support.keeper_turn_record_store config keeper_name in
  Fun.protect
    ~finally:(fun () ->
      Dated_jsonl.prepare_for_directory_removal store;
      Fs_compat.remove_tree base;
      match previous_fs with
      | Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ())
  @@ fun () ->
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let librarian () =
    (* This fixture writes the snapshot and turn records itself, so no writer
       announces the commit [install] listens for. *)
    Health.For_testing.invalidate ~base_path:base ~keeper:keeper_name;
    member "librarian"
      (keeper_obj keeper_name (Health.keeper_memory_health_http_json ~base_path:base))
  in
  let gap () =
    match member "stalled" (librarian ()) with
    | `Null -> None
    | stalled ->
      Alcotest.(check string) "a gap is tagged as one" "gap" (string_field "kind" stalled);
      Some (int_field "gap_start_atom" stalled, int_field "gap_end_atom" stalled)
  in
  Alcotest.(check (option (pair int int))) "no files, no alarm" None (gap ());
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let persisted =
    List.concat_map
      (fun i ->
         [ Agent_core.Types.make_message ~role:Agent_core.Types.User
             [ Agent_core.Types.Text (Printf.sprintf "ask %d" i) ]
         ; Agent_core.Types.make_message ~role:Agent_core.Types.Assistant
             [ Agent_core.Types.Text (Printf.sprintf "answer %d" i) ]
         ])
      (List.init 5 Fun.id)
  in
  let checkpoint : Agent_core.Checkpoint.t =
    { provider_binding = None; version = Agent_core.Checkpoint.checkpoint_version
    ; session_id = trace_id
    ; agent_name = keeper_name
    ; model = "librarian-stalled-model"
    ; system_prompt = None
    ; messages = persisted
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 0.
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None; mcp_sessions = []
    ; working_context = None
    }
  in
  let (_ : _) =
    Masc.Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
      ~session_dir:(Masc.Keeper_types_support.keeper_session_dir config trace_id)
      ~history_retained:0 checkpoint
    |> get
  in
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  let position = B.position_of_messages persisted |> get in
  B.append ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    { B.recorded_at = test_now
    ; event =
        B.Turn_ended
          { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
          ; history_at_start = B.Fresh_history
          ; position
          }
    }
  |> Result.map_error B.append_error_to_string |> get;
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest persisted in
  P.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    { P.position = { trace_id; end_atom = 2; last_atom_digest = Option.get (digest_at 1) }
    ; boundary_lines_seen = 1
    }
  |> Result.map_error P.write_error_to_string |> get;
  let _, total_atoms = Runtime_model_input_tail_window.annotate persisted in
  let record ~turn ~observed first_atom =
    let window : Turn_record.model_input_window =
      { transmitted_atoms = total_atoms - first_atom
      ; total_atoms
      ; measurement = Turn_record.Wire_shape
      ; model_input_front = Model_input_front.At_atom (Option.get (digest_at first_atom))
      }
    in
    Masc.Keeper_turn_record_writer.write ~request_observations:[]
      ~config ~keeper_name ~agent_name:keeper_name ~turn_kind:Turn_record.Direct
      ~trace_id ~absolute_turn:turn ~runtime_profile:"glm"
      ~selected_model:None ~finish_reason:None ~context_window:None
      ~price_input_per_million:None ~price_output_per_million:None
      ~request_latency_ms:None ~ttfrc_ms:None ~request_wire_observation:None
      ~model_input_window:(Some window)
      ~response_observed_model_input:
        (if observed then Some { Turn_record.runtime_profile = "glm"; window } else None)
      ~refused_model_input:None
      ~raw_trace_run_ref:None
      ~sampling:{ temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
      ~usage:
        { input_tokens = None
        ; output_tokens = None
        ; cache_creation_input_tokens = None
        ; cache_read_input_tokens = None
        ; scope = Runtime_usage_scope.Usage_scope_unavailable
        ; input_provenance = None
        }
      ~turn_output_tokens:None
      ~execution_ids:[] ~blocks:[] ~input_components:None ~tool_surface_ref:None ()
  in
  record ~turn:1 ~observed:true 2;
  Alcotest.(check (option (pair int int))) "a request from the Librarian point is no gap" None
    (gap ());
  (* The pinned part and this turn alone outgrew the provider: the turn
     ended on the refusal and recorded no accepted start. *)
  record ~turn:2 ~observed:false 8;
  Alcotest.(check (option (pair int int))) "a refused turn raises no alarm" None (gap ());
  record ~turn:3 ~observed:true 8;
  Alcotest.(check (option (pair int int))) "an accepted start past the point is the gap"
    (Some (2, 8)) (gap ());
  Alcotest.(check bool) "with no drain measured in this process" true
    (is_null (member "measured_at" (librarian ())));
  (* A read position that does not read is neither no gap nor the gap: the
     payload says which file, so the row is not silent the moment a read
     breaks, and does not name atoms as missing that it could not weigh. *)
  let progress_path =
    P.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
  in
  let output = open_out progress_path in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
    output_string output "{not-json");
  let stalled = member "stalled" (librarian ()) in
  Alcotest.(check bool) "an unreadable read position is not null" false (is_null stalled);
  Alcotest.(check string) "it is tagged unmeasured" "unmeasured" (string_field "kind" stalled);
  Alcotest.(check string) "and names the file that did not read" "read_position_unreadable"
    (string_field "cause" stalled);
  Alcotest.(check bool) "with the reader's message" true
    (String.length (string_field "detail" stalled) > 0)
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
    "keeper.memory_os.current_health.v15" (string_field "schema" answer);
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

(* RFC-0517 §2.2: a commit moves its Keeper's since-start cells of the pass
   that committed by exactly what it changed, and the hourly trend holds the
   facts after each hour's last commit, from any source, for the last week. *)
let test_a_commit_moves_its_pass_cells_and_the_hourly_trend () =
  let module Pass = Masc.Keeper_memory_commit_pass in
  let module Outcome = Masc.Keeper_memory_journal_outcome in
  let base = fresh_dir "masc-memory-health-change-cells" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_id = "change-cells" in
  Fs_compat.mkdir_p keepers_dir;
  let seconds_per_hour = 3600. in
  let hour_of time = Float.floor (time /. seconds_per_hour) in
  (* Every commit sits inside an hour that has already ended, so the clock
     this test reads cannot move a commit across an hour's edge. *)
  let current_hour = hour_of (Unix.gettimeofday ()) in
  let at ~hours_ago ~minute =
    ((current_hour -. float_of_int hours_ago) *. seconds_per_hour) +. (minute *. 60.)
  in
  let explicit kind = { source with Current.kind } in
  let id = Types.memory_id in
  let passes =
    [ "admission"; "durable"; "continuity"; "cleanup"; "keeper_write"; "keeper_delete"
    ; "operator_delete" ]
  in
  let changes = [ "added"; "absorbed"; "superseded"; "dropped" ] in
  let row () = Health.keeper_memory_health_row_http_json ~base_path:base ~keeper:keeper_id in
  let cells answer =
    let table = member "changes_since_start" (member "keeper" answer) in
    List.map (fun pass -> List.map (fun change -> int_field change (member pass table)) changes) passes
  in
  let absorbed_one = fact "absorbed one"
  and absorbed_two = fact "absorbed two"
  and absorbed_three = fact "absorbed three"
  and revised_one = fact "revised one"
  and revised_two = fact "revised two"
  and retired = fact "retired claim"
  and kept = fact "kept claim" in
  ignore
    (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
       ~now:(at ~hours_ago:200 ~minute:15.) ~source
       ~facts:
         [ absorbed_one; absorbed_two; absorbed_three; revised_one; revised_two; retired; kept ]
       ()
     |> require_ok);
  let written = fact "written claim" in
  ignore
    (Current.upsert_fact ~pass:Pass.Keeper_write ~keepers_dir ~keeper_id
       ~now:(at ~hours_ago:168 ~minute:15.) ~source:(explicit Current.Explicit_write) written
     |> Result.map_error Current.upsert_error_to_string
     |> require_ok);
  (match
     Current.retract_fact ~pass:Pass.Keeper_delete ~keepers_dir ~keeper_id
       ~now:(at ~hours_ago:167 ~minute:15.) ~source:(explicit Current.Explicit_retract)
       ~memory_id:(id written) ~reason:"the Keeper withdrew it" ()
   with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "the retraction failed");
  let before = cells (row ()) in
  (* One durable disposition: three absorptions, two revisions, a plain drop
     and four new claims, so each change moves by its own amount. *)
  let merged = fact "merged claim"
  and successor_one = fact "successor one"
  and successor_two = fact "successor two"
  and fresh = fact "fresh claim" in
  let drop value reason = { Types.memory_id = id value; reason } in
  let absorb from = { Types.absorbed = id from; into = id merged } in
  let revision from into = { Types.superseded = id from; superseded_by = id into } in
  ignore
    (Current.apply_disposition ~pass:Pass.Durable
       ~dropped_statements:
         [ drop revised_one "successor one restates it"
         ; drop revised_two "successor two restates it"
         ; drop retired "no longer true"
         ]
       ~absorbed:[ absorb absorbed_one; absorb absorbed_two; absorb absorbed_three ]
       ~revisions:[ revision revised_one successor_one; revision revised_two successor_two ]
       ~keepers_dir ~keeper_id ~now:(at ~hours_ago:3 ~minute:10.) ~source
       ~new_claims:[ merged; successor_one; successor_two; fresh ]
       ()
     |> require_ok);
  let moved = List.map2 (List.map2 (fun before after -> after - before)) before (cells (row ())) in
  Alcotest.(check (list (pair string (list int))))
    "the durable commit moves only its own pass, by each change it made"
    (List.map
       (fun pass -> pass, if String.equal pass "durable" then [ 4; 3; 2; 1 ] else [ 0; 0; 0; 0 ])
       passes)
    (List.combine passes moved);
  (* A later commit of the same hour takes its point; a Librarian pass that
     restates a held fact keeps the snapshot and adds no claim. *)
  ignore
    (Current.upsert_fact ~pass:Pass.Keeper_write ~keepers_dir ~keeper_id
       ~now:(at ~hours_ago:3 ~minute:40.) ~source:(explicit Current.Explicit_write)
       (fact "late claim")
     |> Result.map_error Current.upsert_error_to_string
     |> require_ok);
  let before_restatement = cells (row ()) in
  let restated =
    Current.apply_disposition ~pass:Pass.Durable ~absorbed:[] ~revisions:[] ~keepers_dir ~keeper_id
      ~now:(at ~hours_ago:1 ~minute:15.) ~source ~new_claims:[ fresh ] ()
    |> require_ok
  in
  Alcotest.(check bool) "the restatement keeps the snapshot" true
    (restated.Current.commit = Current.Unchanged);
  Alcotest.(check (list (list int))) "a kept snapshot moves no cell" before_restatement
    (cells (row ()));
  let points = List.map (fun (point : Outcome.facts_at_hour) -> point.recorded_at, point.facts) in
  let journaled =
    [ at ~hours_ago:168 ~minute:15., 8
    ; at ~hours_ago:167 ~minute:15., 7
    ; at ~hours_ago:3 ~minute:40., 6
    ; at ~hours_ago:1 ~minute:15., 6
    ]
  in
  Alcotest.(check (list (pair (float 0.) int)))
    "the journal keeps the week of hours that ends with its newest commit"
    journaled
    (points (Outcome.read ~keepers_dir ~keeper_id).Outcome.facts_by_hour);
  let answer = row () in
  let generated_hour = hour_of (float_field "generated_at" answer) in
  (* The answer reads the same clock a moment later: this hour, or the next
     one when an hour ended in between. The hours it keeps are counted from
     its own time below. *)
  Alcotest.(check bool) "the answer was written in this test's hour or the next" true
    (generated_hour = current_hour || generated_hour = current_hour +. 1.);
  let in_trend (recorded_at, _) =
    let hour = hour_of recorded_at in
    hour >= generated_hour -. 167. && hour <= generated_hour
  in
  let trend = List.filter in_trend journaled in
  Alcotest.(check (list (pair (float 0.) int)))
    "the row keeps the hours of the week that ends with its own"
    trend
    (List.map
       (fun point -> float_field "recorded_at" point, int_field "facts" point)
       (list_field "facts_by_hour" (member "keeper" answer)));
  Alcotest.(check (list (pair (float 0.) int)))
    "a point after the answer's hour is left out" []
    (points
       (Outcome.within ~now:(float_field "generated_at" answer)
          [ { Outcome.recorded_at = (generated_hour +. 1.) *. seconds_per_hour; facts = 1 } ]));
  let module Decode = Masc.Tui_decode_memory_health in
  match Decode.decode_memory_health_row ~keeper:keeper_id answer with
  | Ok { Decode.mhr_keeper = Decode.Row_present decoded; _ } ->
    Alcotest.(check (list (pair (float 0.) int))) "the TUI reads the same trend" trend
      (points decoded.Decode.mkh_facts_by_hour);
    Alcotest.(check (list (pair string (list int))))
      "the TUI reads the same counts"
      (List.combine passes (cells answer))
      (List.map
         (fun (pass, (counts : Masc.Keeper_memory_commit_change.counts)) ->
            ( Pass.to_label pass
            , [ counts.added; counts.absorbed; counts.superseded; counts.dropped ] ))
         decoded.Decode.mkh_changes_since_start)
  | Ok _ -> Alcotest.fail "the TUI did not read the row as present"
  | Error detail -> Alcotest.fail detail
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

(* A source observation can require attention before any durable measurement.
   The producer preserves its original identity and does not call it stopped. *)
let test_attention_retains_originals_and_clears_on_observation () =
  let module Pending = Masc.Keeper_librarian_pending in
  let module Queue = Masc.Keeper_librarian_queue_refresh in
  let module Worker = Masc.Keeper_memory_admission_worker in
  let base = fresh_dir "masc-memory-health-attention" in
  let config = Masc.Workspace.default_config base in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  let keeper_name = "attention-original" in
  ignore (write_snapshot ~keepers_dir ~keeper_id:keeper_name [fact "retained"]);
  let worker wait : Pending.worker =
    {installation_id = "original-installation"; request_id = "original-request"; wait} in
  let read () = Health.For_testing.with_runtime
      ~keeper_health:Health.For_testing.keeper_health
      (fun () -> Health.keeper_memory_health_http_json ~base_path:base) in
  Fun.protect ~finally:(fun () -> Queue.forget_measurement ~config ~keeper_name) (fun () ->
    List.iter (fun (wait, expected) ->
      let original = worker wait in
      Queue.For_testing.run_explicit_admission_with ~base_path:base ~keeper_name
        ~run:(fun () -> Worker.Awaiting_worker original);
      let json = read () in
      let row = keeper_obj keeper_name json in
      let librarian = member "librarian" row in
      Alcotest.(check bool) "attention is derived from the original wait" expected
        (bool_field "operator_action_required" librarian);
      Alcotest.(check bool) "durable measurement remains absent" true
        (is_null (member "state" librarian) && is_null (member "measured_at" librarian));
      Alcotest.(check bool) "the admission original survives the wire" true
        (Yojson.Safe.equal (Pending.to_json (Worker original)) (member "admission_wait" librarian));
      Alcotest.(check (list string)) "attention alert follows the typed wait"
        (if expected then ["librarian_attention_required"] else [])
        (list_field "alerts" row |> List.map (string_field "code"));
      Alcotest.(check int) "attention counts Keepers, not observations" (if expected then 1 else 0)
        (int_field "librarian_attention_required_keepers" (alert_summary json));
      Alcotest.(check int) "attention does not imply stopped" 0
        (int_field "librarian_stopped_keepers" (alert_summary json)))
      [ Pending.Capacity, false; Processing, false; Outcome_unknown, true;
        Unreachable, false; Missing_after_dispatch, true; Journal_recheck, false ];
    Alcotest.(check bool) "both observations derive one requirement" true
      (Pending.attention_required
        ~durable:(Some (Worker (worker Pending.Missing_after_dispatch)))
        ~admission:(Some (Admission_waiting (worker Pending.Outcome_unknown))));
    Alcotest.(check bool) "a failed admission pass needs attention" true
      (Pending.attention_required ~durable:None ~admission:(Some (Admission_failed "pass refused")));
    let refused = "admission pass refused its records" in
    Queue.For_testing.run_explicit_admission_with ~base_path:base ~keeper_name
      ~run:(fun () -> Worker.Unavailable refused);
    let failed = member "librarian" (keeper_obj keeper_name (read ())) in
    Alcotest.(check bool) "a failed admission pass reaches the Keeper row" true
      (bool_field "operator_action_required" failed);
    Alcotest.(check bool) "the failed pass survives the wire with its error" true
      (Yojson.Safe.equal (Pending.to_json (Local_failure refused)) (member "admission_wait" failed));
    (match Masc.Tui_decode_memory_health.decode_memory_health_snapshot (read ()) with
     | Error detail -> Alcotest.fail detail
     | Ok snapshot ->
       Alcotest.(check bool) "the TUI decoder reads the failed pass from the server answer" true
         (List.exists (fun (keeper : Masc.Tui_decode_memory_health.memory_keeper_health) ->
            String.equal keeper.mkh_keeper_id keeper_name
            && keeper.mkh_librarian.mlh_admission_wait = Some (Pending.Admission_failed refused))
            snapshot.Masc.Tui_decode_memory_health.mhs_keepers));
    Alcotest.(check bool) "local recovery failure needs attention" true
      (Pending.attention_required ~durable:(Some (Local_failure "source read failed")) ~admission:None);
    List.iter (fun pending ->
      Alcotest.(check bool) "unfinished publication is not an unknown execution" false
        (Pending.attention_required ~durable:(Some pending) ~admission:None))
      [ Pending.Publication {request_id="publication"; detail="settling"};
        Basis_changed {request_id="basis"};
        Message_floor {request_id="floor"; detail="waiting"} ];
    Queue.For_testing.run_explicit_admission_with ~base_path:base ~keeper_name
      ~run:(fun () -> Worker.Idle);
    let json = read () in
    Alcotest.(check int) "a later non-wait observation clears the derived requirement" 0
      (int_field "librarian_attention_required_keepers" (alert_summary json)))
;;

(* The TUI reads one Keeper's row after its push and merges it into the fleet
   answer it holds (RFC-0487). The merged answer is the fleet answer read
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

let test_failed_health_reads_are_retried () =
  let base = fresh_dir "masc-memory-health-retry" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ignore (write_snapshot ~keepers_dir ~keeper_id:"alpha" [fact "recovered fact"]);
  let valid_json =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"alpha" with
    | Ok (Some snapshot) -> Yojson.Safe.to_string (Current.to_json snapshot)
    | Ok None -> Alcotest.fail "the valid snapshot is missing"
    | Error detail -> Alcotest.fail detail
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha" in
  let attempts = ref 0 in
  Health.For_testing.with_runtime
    ~keeper_health:(fun ~config ~keepers_dir keeper_id ->
      incr attempts;
      Fs_compat.save_file path (if !attempts = 1 then {|{"schema":"wrong"}|} else valid_json);
      Health.For_testing.keeper_health ~config ~keepers_dir keeper_id)
    (fun () ->
      let first = Health.keeper_memory_health_http_json ~base_path:base in
      Alcotest.(check bool) "the failed read is explicit" false
        (is_null (member "read_error" (keeper_obj "alpha" first)));
      let second = Health.keeper_memory_health_http_json ~base_path:base in
      Alcotest.(check bool) "the recovered read has no old error" true
        (is_null (member "read_error" (keeper_obj "alpha" second)));
      Alcotest.(check int) "the failed health read was retried" 2 !attempts)
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
        ; Alcotest.test_case "failed health reads are retried" `Quick
            test_failed_health_reads_are_retried
        ; Alcotest.test_case "cold health read and commit do not deadlock" `Quick
            test_cold_health_read_and_commit_do_not_deadlock
        ; Alcotest.test_case "one Keeper's row is its fleet row" `Quick
            test_one_keepers_row_is_its_fleet_row
        ; Alcotest.test_case "a commit moves its pass cells and the hourly trend" `Quick
            test_a_commit_moves_its_pass_cells_and_the_hourly_trend
        ; Alcotest.test_case "the totals count the rows" `Quick test_totals_count_the_rows
        ; Alcotest.test_case "attention retains original observations" `Quick
            test_attention_retains_originals_and_clears_on_observation
        ; Alcotest.test_case "a merged row is the fleet read after the write" `Quick
            test_a_merged_row_is_the_fleet_read_after_the_write
        ; Alcotest.test_case "unread evidence is observed without publication" `Quick
            test_unread_evidence_is_observed_without_publication
        ; Alcotest.test_case "saved versus prepared context" `Quick
            test_context_cycle_separates_saved_and_prepared
        ; Alcotest.test_case "the Librarian position is read beside the cut" `Quick
            test_context_cycle_reads_the_librarian_position_beside_the_cut
        ; Alcotest.test_case "the Librarian_stalled alarm is read from files" `Quick
            test_the_librarian_stalled_alarm_is_read_from_files
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
        ; Alcotest.test_case "journal outcome reads appended lines" `Quick
            test_journal_outcome_reads_appended_lines
        ; Alcotest.test_case "journal outcome waits for a torn line" `Quick
            test_journal_outcome_waits_for_a_torn_line
        ; Alcotest.test_case "journal unreadable is not empty" `Quick
            test_journal_outcome_distinguishes_unreadable_from_empty
        ; Alcotest.test_case "journal failure retains evidence and recovers" `Quick
            test_journal_failure_keeps_evidence_and_recovers_without_another_commit
        ; Alcotest.test_case "librarian failure then explicit write" `Quick
            test_librarian_failure_then_explicit_write_keeps_both
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
