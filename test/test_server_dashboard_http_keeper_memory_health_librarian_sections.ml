(** Regression tests for current Memory OS fleet-health projection. *)

module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
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
    | Some row ->
      Alcotest.(check bool) "this process runs no Memory writer, and the row says so" true
        (row.mkh_writer = Masc.Tui_decode_memory_writer.None_in_process);
      row.mkh_context_cycle
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
;;

let test_cache_invalidation_survives_symlinked_parent_before_runtime_dir_exists () =
  let module P = Masc.Keeper_librarian_progress in
  let root = fresh_dir "masc-health-symlink-root" in
  let actual = Filename.concat root "actual" in
  let link = Filename.concat root "workspace-link" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  Unix.mkdir actual 0o755;
  Unix.symlink actual link;
  let config = Masc.Workspace.default_config link in
  let keeper_name = "symlink-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:link in
  write_keeper_config ~keepers_dir ~keeper_id:keeper_name ();
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  Alcotest.(check bool) "runtime keepers dir is absent before initial health read" false
    (Sys.file_exists runtime_keepers_dir);
  Health.For_testing.invalidate ~base_path:link ~keeper:keeper_name;
  let initial_json = Health.keeper_memory_health_http_json ~base_path:link in
  let initial_cycle = member "context_cycle" (keeper_obj keeper_name initial_json) in
  Alcotest.(check bool) "initial health observes absent read_position" true
    (is_null (member "read_position" initial_cycle));
  P.write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    { P.position =
        { trace_id = "symlink-trace"
        ; end_atom = 42
        ; last_atom_digest = String.make 64 'b'
        }
    ; boundary_lines_seen = 7
    }
  |> Result.map_error P.write_error_to_string |> require_ok;
  (* No manual invalidation: [P.write] creates [runtime_keepers_dir] and fires
     its commit observer with the canonicalized path. *)
  let updated_json = Health.keeper_memory_health_http_json ~base_path:link in
  let updated_cycle = member "context_cycle" (keeper_obj keeper_name updated_json) in
  Alcotest.(check int) "cache invalidation resolves symlinked parent even when dir was absent at registration"
    42 (int_field "read_position" updated_cycle)
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
    ; pending_input = None
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
      [ Pending.Processing, false; Outcome_unknown, true;
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

let () =
  Alcotest.run
    "server_dashboard_http_keeper_memory_health_librarian_sections"
    [ ( "current snapshot"
      , [ Alcotest.test_case "failed health reads are retried" `Quick
            test_failed_health_reads_are_retried
        ; Alcotest.test_case "a commit moves its pass cells and the hourly trend" `Quick
            test_a_commit_moves_its_pass_cells_and_the_hourly_trend
        ; Alcotest.test_case "attention retains original observations" `Quick
            test_attention_retains_originals_and_clears_on_observation
        ; Alcotest.test_case "unread evidence is observed without publication" `Quick
            test_unread_evidence_is_observed_without_publication
        ; Alcotest.test_case "saved versus prepared context" `Quick
            test_context_cycle_separates_saved_and_prepared
        ; Alcotest.test_case "the Librarian position is read beside the cut" `Quick
            test_context_cycle_reads_the_librarian_position_beside_the_cut
        ; Alcotest.test_case "cache invalidation survives symlinked parent when runtime dir is absent at registration" `Quick
            test_cache_invalidation_survives_symlinked_parent_before_runtime_dir_exists
        ; Alcotest.test_case "the Librarian_stalled alarm is read from files" `Quick
            test_the_librarian_stalled_alarm_is_read_from_files
        ; Alcotest.test_case "continuity lag measured or unknown" `Quick
            test_the_continuity_lag_is_measured_or_says_it_cannot_be
        ; Alcotest.test_case "workspace context preserves sources and failures" `Quick
            test_workspace_context_preserves_sources_and_failures
        ; Alcotest.test_case "librarian position without a loop" `Quick
            test_reports_the_librarian_position_without_a_loop
        ; Alcotest.test_case "journal outcome reads appended lines" `Quick
            test_journal_outcome_reads_appended_lines
        ; Alcotest.test_case "journal outcome waits for a torn line" `Quick
            test_journal_outcome_waits_for_a_torn_line
        ; Alcotest.test_case "librarian failure then explicit write" `Quick
            test_librarian_failure_then_explicit_write_keeps_both
        ] )
    ]
;;
