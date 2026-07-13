(** test_keeper_state_machine_correspondence — OCaml ↔ TLA+ field-set
    correspondence harness for KeeperStateMachine (P5).

    Mechanically detects spec-code SHAPE divergence: for each event,
    cross-checks the set of [conditions] fields modified by the OCaml
    [update_conditions] function against the set of primed-variable
    assignments in the matching TLA+ action.

    Background
    ----------
    The original [manual_reconcile_required] one-way trap (pre-#7334)
    was a single-line spec-code divergence that hid in plain sight:
    the TLA+ [TurnSucceeded] action cleared the latch but the OCaml
    handler did not. The TLA+ liveness property still passed under the
    spec's own (drifted) semantics, so TLC could not catch it. After
    PR #7334 removed the latch entirely from both sides, the audit
    [docs/tla-audit/state-fsm-gap-2026-04-13.md] kept proposal P5 open:
    "Add an OCaml-TLA+ correspondence test" so any future single-field
    divergence is caught mechanically at test time.

    What this test checks
    ---------------------
    SHAPE only — for each event, the set of [conditions] field names
    modified must equal the set of variable names that are primed-
    assigned in the corresponding TLA+ action. Value-level
    correspondence (does TLA+ set TRUE when OCaml sets true?) is
    enforced by the existing per-event unit tests in
    [test_keeper_state_machine.ml] plus the snapshot trace in
    [synthetic.tla-trace.jsonl]; we deliberately do not duplicate it.

    Method
    ------
    OCaml side: for each [event], run [update_conditions] on two bases
    (all-fields-false and all-fields-true) and take the union of field
    diffs from [conditions_to_json]. The two-base union guarantees we
    observe writes regardless of the value the event happens to set.

    TLA+ side: read [specs/keeper-state-machine/KeeperStateMachine.tla],
    slice out the Events section (between the "Events" header and the
    "Next State" header), parse each [Name == ... /\ var' = ... ]
    action, and collect primed-variable names. Restricting the slice keeps
    temporal property expressions out of the action parser.

    Modeling-boundary filter
    ------------------------
    The TLA+ model intentionally projects only the conditions relevant to
    its lifecycle properties. The harness therefore compares the
    intersection with the OCaml [conditions] field names.
    The set of OCaml [conditions] fields is itself derived from
    [conditions_to_json], so adding a new field automatically extends
    the comparison without touching this test. *)

open Alcotest
module SM = Keeper_state_machine
module SM_json = Keeper_state_machine_json

(* ── OCaml-side change-set computation ─────────────────────── *)

(** Set every condition field to a single boolean. *)
let all_set b : SM.conditions =
  {
    launch_pending = b;
    fiber_alive = b;
    heartbeat_healthy = b;
    turn_healthy = b;
    context_within_budget = b;
    context_handoff_needed = b;
    compaction_active = b;
    handoff_active = b;
    operator_paused = b;
    stop_requested = b;
    dead_tombstone_latched = b;
    restart_requested = b;
    drain_complete = b;
    context_overflow = b;
    credential_archived = b;
  }

let json_field_diff (a : Yojson.Safe.t) (b : Yojson.Safe.t) : string list =
  match (a, b) with
  | `Assoc fa, `Assoc fb ->
      List.filter_map
        (fun (k, va) ->
          match List.assoc_opt k fb with
          | Some vb when va = vb -> None
          | _ -> Some k)
        fa
  | _ -> []

(** OCaml-side: set of [conditions] fields that [update_conditions]
    mutates for the given event. Computed by union over both bases. *)
let ocaml_changed_fields (ev : SM.event) : string list =
  let base_f = all_set false in
  let base_t = all_set true in
  let after_f = SM.update_conditions base_f ev in
  let after_t = SM.update_conditions base_t ev in
  let d_f =
    json_field_diff
      (SM_json.conditions_to_json base_f)
      (SM_json.conditions_to_json after_f)
  in
  let d_t =
    json_field_diff
      (SM_json.conditions_to_json base_t)
      (SM_json.conditions_to_json after_t)
  in
  List.sort_uniq String.compare (d_f @ d_t)

(* ── TLA+ spec parsing ─────────────────────────────────────── *)

let rec find_repo_root dir =
  let candidate =
    Filename.concat dir "specs/keeper-state-machine/KeeperStateMachine.tla"
  in
  if Sys.file_exists candidate then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      Alcotest.fail "could not find repo root for KeeperStateMachine.tla"
    else find_repo_root parent

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> find_repo_root (Filename.dirname Sys.executable_name)

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(** Substring search: index of [needle] in [hay] starting at [pos],
    or [-1] if absent. *)
let index_of hay needle pos =
  let nlen = String.length needle in
  let hlen = String.length hay in
  let rec loop i =
    if i + nlen > hlen then -1
    else if String.sub hay i nlen = needle then i
    else loop (i + 1)
  in
  loop pos

(** Slice the spec to the Events section: between the Events header
    and the Next State header. Properties and DerivePhase are excluded. *)
let events_section content =
  let start_marker = "\\* \xe2\x94\x80\xe2\x94\x80 Events" in
  let end_marker = "\\* \xe2\x94\x80\xe2\x94\x80 Next State" in
  let start = index_of content start_marker 0 in
  let stop = index_of content end_marker 0 in
  if start < 0 || stop < 0 || stop <= start then
    Alcotest.fail
      "could not locate Events / Next State section markers in \
       KeeperStateMachine.tla"
  else String.sub content start (stop - start)

(** Match top-level action header on a single line: [Name ==] with
    optional trailing whitespace. Anchored at start of line. *)
let action_header_regex =
  Str.regexp "^\\([A-Z][A-Za-z0-9]*\\) ==[ \t]*$"

(** Match a primed-variable assignment in the form [/\ var' = ...] or
    [/\ var' \in ...]. Variable names are lowercase identifiers. The
    leading "/\\" disambiguates from constructs inside UNCHANGED
    tuples (which list bare names, no prime, no leading /\\). *)
let primed_assign_regex =
  Str.regexp "/\\\\[ \t]+\\([a-z_][a-z_0-9]*\\)'[ \t]*\\(=\\|\\\\in\\)"

(** Collect all primed-variable assignments inside a body of action
    lines. Returns deduplicated, sorted variable names. *)
let primed_vars_in_body lines =
  let acc = ref [] in
  List.iter
    (fun line ->
      let pos = ref 0 in
      let continue = ref true in
      while !continue do
        match Str.search_forward primed_assign_regex line !pos with
        | exception Not_found -> continue := false
        | _ ->
            acc := Str.matched_group 1 line :: !acc;
            pos := Str.match_end ()
      done)
    lines;
  List.sort_uniq String.compare !acc

(** Walk the events-section text line by line, grouping each
    contiguous block under its [Name ==] header. Returns
    [(action_name, body_lines)] pairs in declaration order. *)
let parse_actions content =
  let lines = String.split_on_char '\n' content in
  let rec loop acc current = function
    | [] -> (
        match current with
        | None -> List.rev acc
        | Some (name, body) -> List.rev ((name, List.rev body) :: acc))
    | line :: rest ->
        if Str.string_match action_header_regex line 0 then
          let name = Str.matched_group 1 line in
          let acc' =
            match current with
            | None -> acc
            | Some (n, body) -> (n, List.rev body) :: acc
          in
          loop acc' (Some (name, [])) rest
        else
          let current' =
            match current with
            | None -> None
            | Some (n, body) -> Some (n, line :: body)
          in
          loop acc current' rest
  in
  loop [] None lines

let load_spec_actions () =
  let path =
    Filename.concat
      (project_root ())
      "specs/keeper-state-machine/KeeperStateMachine.tla"
  in
  let content = read_file path in
  let section = events_section content in
  parse_actions section
  |> List.map (fun (name, body) -> (name, primed_vars_in_body body))

(** OCaml [conditions] field names, derived from the default record's
    JSON projection. The harness compares only this shared field set. *)
let conditions_field_names () : string list =
  match SM_json.conditions_to_json SM.default_conditions with
  | `Assoc fs -> List.map fst fs |> List.sort String.compare
  | _ ->
      Alcotest.fail "conditions_to_json did not return a JSON object"

(* ── Event ↔ TLA+ action correspondence table ──────────────── *)

(** PascalCase TLA+ action name + a canonical OCaml event instance. We
    pin one canonical instance per parameterized event: the harness
    only checks SHAPE (which fields are written), so the specific
    parameter values do not matter — but using the same payload twice
    (against [all_set false] and [all_set true]) keeps coverage
    deterministic. *)
let canonical_events : (string * SM.event) list =
  [
    ("HeartbeatOk", SM.Heartbeat_ok);
    ("HeartbeatFailed", SM.Heartbeat_failed { consecutive = 1 });
    ("TurnSucceeded", SM.Turn_succeeded);
    ("TurnFailed", SM.Turn_failed { consecutive = 1 });
    ( "ContextMeasured",
      SM.Context_measured
        {
          context_ratio = 0.5;
          message_count = 10;
          token_count = 1000;
          context_actions =
            {
              compact = false;
              handoff = false;
            };
        } );
    ("CompactionStarted", SM.Compaction_started);
    ( "CompactionCompletedWithSavings",
      SM.Compaction_completed { before_tokens = 100_000; after_tokens = 50_000 } );
    ( "CompactionCompletedNoSavings",
      SM.Compaction_completed { before_tokens = 50_000; after_tokens = 50_000 } );
    ("CompactionFailed", SM.Compaction_failed { reason = "test" });
    ("HandoffStarted", SM.Handoff_started);
    ( "HandoffCompleted",
      SM.Handoff_completed { new_trace_id = "t-test"; generation = 1 } );
    ("HandoffFailed", SM.Handoff_failed { reason = "test" });
    ("OperatorPause", SM.Operator_pause);
    ("OperatorResume", SM.Operator_resume);
    ("StopRequested", SM.Stop_requested);
    ("OperatorStop", SM.Operator_stop { remove_meta = false });
    ("DrainCompleteEv", SM.Drain_complete);
    ("FiberStarted", SM.Fiber_started);
    ("FiberTerminated", SM.Fiber_terminated { outcome = "test"; provider_id = None; http_status = None });
    ("SupervisorRestartAttempt", SM.Supervisor_restart_attempt { attempt = 1 });
    ( "ContextOverflowDetected",
      SM.Context_overflow_detected
        { source = `Oas_signal; token_count = 200_000; limit_tokens = Some 200_000 } );
    ("AutoCompactTriggered", SM.Auto_compact_triggered);
    ("OperatorCompactRequested", SM.Operator_compact_requested);
    ( "OperatorClearRequested",
      SM.Operator_clear_requested
        { preserve_system = true; reason = "test" } );
  ]

(* ── Test cases ────────────────────────────────────────────── *)

(** Every event listed in [canonical_events] must have a matching
    TLA+ action of the same PascalCase name in the spec, and vice
    versa. This catches a new event being added on either side
    without a paired definition on the other. *)
let test_action_set_parity () =
  let spec_actions = load_spec_actions () in
  let spec_names =
    List.sort String.compare (List.map fst spec_actions)
  in
  let ocaml_names =
    List.sort String.compare (List.map fst canonical_events)
  in
  let only_spec =
    List.filter (fun n -> not (List.mem n ocaml_names)) spec_names
  in
  let only_ocaml =
    List.filter (fun n -> not (List.mem n spec_names)) ocaml_names
  in
  if only_spec <> [] || only_ocaml <> [] then begin
    Printf.printf "TLA+ actions  (%d): [%s]\n" (List.length spec_names)
      (String.concat "; " spec_names);
    Printf.printf "OCaml events  (%d): [%s]\n" (List.length ocaml_names)
      (String.concat "; " ocaml_names);
    Printf.printf "Only in TLA+  : [%s]\n" (String.concat "; " only_spec);
    Printf.printf "Only in OCaml : [%s]\n" (String.concat "; " only_ocaml);
    Alcotest.fail
      "KeeperStateMachine.tla actions and OCaml event variants \
       diverged. Add the missing entry on the matching side, or \
       update [canonical_events] in this test."
  end

(** For every event, the OCaml-side modified-field set must equal the
    TLA+ action's primed-variable set. This is the core P5 property:
    if a future change adds a field write on one side without the
    other, this test fails with a precise diff. *)
let test_field_set_correspondence () =
  let spec_actions = load_spec_actions () in
  let conditions_fields = conditions_field_names () in
  let restrict xs =
    List.filter (fun v -> List.mem v conditions_fields) xs
    |> List.sort_uniq String.compare
  in
  let mismatches =
    List.filter_map
      (fun (action_name, ev) ->
        let ocaml_set = ocaml_changed_fields ev in
        match List.assoc_opt action_name spec_actions with
        | None -> None (* parity test handles this *)
        | Some tla_set ->
            let tla_set = restrict tla_set in
            if ocaml_set = tla_set then None
            else Some (action_name, ocaml_set, tla_set))
      canonical_events
  in
  if mismatches <> [] then begin
    List.iter
      (fun (name, o, t) ->
        let only_ocaml =
          List.filter (fun s -> not (List.mem s t)) o
        in
        let only_tla =
          List.filter (fun s -> not (List.mem s o)) t
        in
        Printf.printf "[%s]\n" name;
        Printf.printf "  OCaml writes : [%s]\n" (String.concat "; " o);
        Printf.printf "  TLA+ primes  : [%s]\n" (String.concat "; " t);
        Printf.printf "  Only OCaml   : [%s]\n"
          (String.concat "; " only_ocaml);
        Printf.printf "  Only TLA+    : [%s]\n"
          (String.concat "; " only_tla))
      mismatches;
    Alcotest.fail
      "OCaml [update_conditions] and TLA+ action primed-variable set \
       diverge. Either align the OCaml handler or update the TLA+ \
       action — both must agree on which condition fields each event \
       writes."
  end

let () =
  run "keeper_state_machine_correspondence"
    [
      ( "parity",
        [
          test_case "action set parity" `Quick test_action_set_parity;
          test_case "field set correspondence" `Quick
            test_field_set_correspondence;
        ] );
    ]
