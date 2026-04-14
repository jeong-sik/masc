open Alcotest
open Masc_mcp

(** Helper: create a minimal unit_record for testing *)
let make_unit ?(roster = []) ?(leader_id = None) ?(parent_unit_id = None)
    ?(updated_at = "2026-01-01T00:00:00Z") ~unit_id ~label ~kind () =
  Cp_cleanup.
    {
      unit_id;
      label;
      kind;
      parent_unit_id;
      leader_id;
      roster;
      capability_profile = [];
      policy = Cp_cleanup.default_policy kind;
      budget = Cp_cleanup.default_budget kind;
      source = "managed";
      created_at = "2026-01-01T00:00:00Z";
      updated_at;
    }

(** Helper: create a minimal operation_record for testing *)
let make_operation ?(status = Cp_cleanup.Active) ?(updated_at = "2026-01-01T00:00:00Z")
    ~operation_id ~assigned_unit_id () =
  Cp_cleanup.
    {
      operation_id;
      objective = "test objective";
      intent_id = None;
      assigned_unit_id;
      policy_class = "strict";
      budget_class = "standard";
      workload_template = None;
      workload_profile = "coding_task";
      stage = None;
      artifact_scope = [];
      depends_on_operation_ids = [];
      search_strategy = "best_first_v1";
      detachment_session_id = None;
      trace_id = "trace-test";
      checkpoint_ref = None;
      active_goal_ids = [];
      note = None;
      created_by = "test";
      source = "managed";
      status;
      created_at = "2026-01-01T00:00:00Z";
      updated_at;
    }

(** Helper: create a minimal detachment_record for testing *)
let make_detachment ~detachment_id ~operation_id () =
  Cp_cleanup.
    {
      detachment_id;
      operation_id;
      assigned_unit_id = "unit-1";
      leader_id = None;
      roster = [];
      session_id = None;
      checkpoint_ref = None;
      runtime_kind = None;
      runtime_ref = None;
      source = "managed";
      status = Cp_types.Det_active;
      last_event_at = None;
      last_progress_at = None;
      heartbeat_deadline = None;
      created_at = "2026-01-01T00:00:00Z";
      updated_at = "2026-01-01T00:00:00Z";
    }

(** Helper: create a minimal intent_record for testing *)
let make_intent ?(state = Cp_cleanup.Active_intent) ?(updated_at = "2026-01-01T00:00:00Z")
    ~intent_id () =
  Cp_cleanup.
    {
      intent_id;
      title = "test intent";
      owner = "test";
      workload_profile = "coding_task";
      success_metric = None;
      invariants = [];
      artifact_priors = [];
      state;
      current_focus =
        { stage = None; artifact_scope = []; unit_id = None; verification_state = None };
      checkpoint_ref = None;
      source = "managed";
      created_at = "2026-01-01T00:00:00Z";
      updated_at;
    }

(* ====================== *)
(* find_dead_units tests   *)
(* ====================== *)

let test_find_dead_units_detects_empty_roster_stale () =
  let units =
    [
      make_unit ~unit_id:"u1" ~label:"Dead Unit" ~kind:Squad
        ~roster:[] ~leader_id:None ~updated_at:"2025-01-01T00:00:00Z" ();
      make_unit ~unit_id:"u2" ~label:"Live Unit" ~kind:Squad
        ~roster:[ "agent-a" ] ~leader_id:(Some "agent-a")
        ~updated_at:"2026-03-15T00:00:00Z" ();
    ]
  in
  let dead = Cp_cleanup.find_dead_units ~days:14 units in
  check int "one dead unit" 1 (List.length dead);
  check string "dead unit id" "u1"
    (List.hd dead).Cp_cleanup.unit_id

let test_find_dead_units_skips_units_with_leader () =
  let units =
    [
      make_unit ~unit_id:"u1" ~label:"Has Leader" ~kind:Squad
        ~roster:[] ~leader_id:(Some "leader-1")
        ~updated_at:"2025-01-01T00:00:00Z" ();
    ]
  in
  let dead = Cp_cleanup.find_dead_units ~days:14 units in
  check int "no dead units (has leader)" 0 (List.length dead)

let test_find_dead_units_skips_recent () =
  let units =
    [
      make_unit ~unit_id:"u1" ~label:"Recent Empty" ~kind:Squad
        ~roster:[] ~leader_id:None
        ~updated_at:"2099-01-01T00:00:00Z" ();
    ]
  in
  let dead = Cp_cleanup.find_dead_units ~days:14 units in
  check int "no dead units (recent)" 0 (List.length dead)

(* ========================== *)
(* find_orphaned_units tests   *)
(* ========================== *)

let test_find_orphaned_units_detects_missing_parent () =
  let units =
    [
      make_unit ~unit_id:"root" ~label:"Root" ~kind:Company ();
      make_unit ~unit_id:"child" ~label:"Child" ~kind:Platoon
        ~parent_unit_id:(Some "non-existent") ();
    ]
  in
  let orphaned = Cp_cleanup.find_orphaned_units units in
  check int "one orphaned unit" 1 (List.length orphaned);
  check string "orphaned id" "child"
    (List.hd orphaned).Cp_cleanup.unit_id

let test_find_orphaned_units_accepts_valid_parent () =
  let units =
    [
      make_unit ~unit_id:"root" ~label:"Root" ~kind:Company ();
      make_unit ~unit_id:"child" ~label:"Child" ~kind:Platoon
        ~parent_unit_id:(Some "root") ();
    ]
  in
  let orphaned = Cp_cleanup.find_orphaned_units units in
  check int "no orphans" 0 (List.length orphaned)

let test_find_orphaned_units_skips_root () =
  let units =
    [
      make_unit ~unit_id:"root" ~label:"Root" ~kind:Company ();
    ]
  in
  let orphaned = Cp_cleanup.find_orphaned_units units in
  check int "root is not orphaned" 0 (List.length orphaned)

(* ================================= *)
(* find_terminal_operations tests     *)
(* ================================= *)

let test_find_terminal_operations_detects_completed_stale () =
  let ops =
    [
      make_operation ~operation_id:"op1" ~assigned_unit_id:"u1"
        ~status:Completed ~updated_at:"2025-01-01T00:00:00Z" ();
      make_operation ~operation_id:"op2" ~assigned_unit_id:"u1"
        ~status:Active ~updated_at:"2025-01-01T00:00:00Z" ();
      make_operation ~operation_id:"op3" ~assigned_unit_id:"u1"
        ~status:Failed ~updated_at:"2025-01-01T00:00:00Z" ();
    ]
  in
  let terminal = Cp_cleanup.find_terminal_operations ~days:14 ops in
  check int "two terminal operations" 2 (List.length terminal)

let test_find_terminal_operations_skips_recent () =
  let ops =
    [
      make_operation ~operation_id:"op1" ~assigned_unit_id:"u1"
        ~status:Completed ~updated_at:"2099-01-01T00:00:00Z" ();
    ]
  in
  let terminal = Cp_cleanup.find_terminal_operations ~days:14 ops in
  check int "no terminal (recent)" 0 (List.length terminal)

(* ====================================== *)
(* find_orphaned_detachments tests         *)
(* ====================================== *)

let test_find_orphaned_detachments_detects_missing_operation () =
  let detachments =
    [
      make_detachment ~detachment_id:"det1" ~operation_id:"op-exists" ();
      make_detachment ~detachment_id:"det2" ~operation_id:"op-gone" ();
    ]
  in
  let orphaned =
    Cp_cleanup.find_orphaned_detachments
      ~operation_ids:[ "op-exists" ] detachments
  in
  check int "one orphaned detachment" 1 (List.length orphaned);
  check string "orphaned det id" "det2"
    (List.hd orphaned).Cp_cleanup.detachment_id

(* =============================== *)
(* find_dropped_intents tests       *)
(* =============================== *)

let test_find_dropped_intents_detects_dropped_stale () =
  let intents =
    [
      make_intent ~intent_id:"i1" ~state:Dropped_intent
        ~updated_at:"2025-01-01T00:00:00Z" ();
      make_intent ~intent_id:"i2" ~state:Active_intent
        ~updated_at:"2025-01-01T00:00:00Z" ();
    ]
  in
  let dropped = Cp_cleanup.find_dropped_intents ~days:14 intents in
  check int "one dropped intent" 1 (List.length dropped);
  check string "dropped intent id" "i1"
    (List.hd dropped).Cp_cleanup.intent_id

let test_find_dropped_intents_skips_recent () =
  let intents =
    [
      make_intent ~intent_id:"i1" ~state:Dropped_intent
        ~updated_at:"2099-01-01T00:00:00Z" ();
    ]
  in
  let dropped = Cp_cleanup.find_dropped_intents ~days:14 intents in
  check int "no dropped (recent)" 0 (List.length dropped)

(* ========================== *)
(* is_terminal_status tests    *)
(* ========================== *)

let test_is_terminal_status () =
  check bool "completed is terminal" true
    (Cp_cleanup.is_terminal_status Completed);
  check bool "cancelled is terminal" true
    (Cp_cleanup.is_terminal_status Cancelled);
  check bool "failed is terminal" true
    (Cp_cleanup.is_terminal_status Failed);
  check bool "active is not terminal" false
    (Cp_cleanup.is_terminal_status Active);
  check bool "planned is not terminal" false
    (Cp_cleanup.is_terminal_status Planned);
  check bool "paused is not terminal" false
    (Cp_cleanup.is_terminal_status Paused)

(* ============================== *)
(* cleanup_result_to_json tests    *)
(* ============================== *)

let test_cleanup_result_to_json () =
  let result =
    Cp_cleanup.
      {
        dead_units_removed = 2;
        orphaned_units_removed = 1;
        operations_archived = 3;
        detachments_removed = 0;
        intents_removed = 1;
      }
  in
  let json = Cp_cleanup.cleanup_result_to_json result in
  let open Yojson.Safe.Util in
  check int "dead_units_removed" 2
    (json |> member "dead_units_removed" |> to_int);
  check int "operations_archived" 3
    (json |> member "operations_archived" |> to_int);
  check int "intents_removed" 1
    (json |> member "intents_removed" |> to_int)

(* ====================== *)
(* cutoff_iso tests        *)
(* ====================== *)

let test_cutoff_iso_format () =
  let iso = Cp_cleanup.cutoff_iso ~days:14 in
  check bool "ISO format (starts with 20)" true
    (String.length iso > 0 && String.sub iso 0 2 = "20");
  check bool "ISO format (ends with Z)" true
    (iso.[String.length iso - 1] = 'Z');
  check bool "ISO format (contains T)" true
    (String.contains iso 'T')

(* ============================================ *)
(* Test suite registration                       *)
(* ============================================ *)

let () =
  run "cp_cleanup"
    [
      ( "find_dead_units",
        [
          test_case "detects empty roster + stale" `Quick
            test_find_dead_units_detects_empty_roster_stale;
          test_case "skips units with leader" `Quick
            test_find_dead_units_skips_units_with_leader;
          test_case "skips recent empty units" `Quick
            test_find_dead_units_skips_recent;
        ] );
      ( "find_orphaned_units",
        [
          test_case "detects missing parent" `Quick
            test_find_orphaned_units_detects_missing_parent;
          test_case "accepts valid parent" `Quick
            test_find_orphaned_units_accepts_valid_parent;
          test_case "skips root units" `Quick
            test_find_orphaned_units_skips_root;
        ] );
      ( "find_terminal_operations",
        [
          test_case "detects completed/failed stale" `Quick
            test_find_terminal_operations_detects_completed_stale;
          test_case "skips recent terminal" `Quick
            test_find_terminal_operations_skips_recent;
        ] );
      ( "find_orphaned_detachments",
        [
          test_case "detects missing operation" `Quick
            test_find_orphaned_detachments_detects_missing_operation;
        ] );
      ( "find_dropped_intents",
        [
          test_case "detects dropped stale" `Quick
            test_find_dropped_intents_detects_dropped_stale;
          test_case "skips recent dropped" `Quick
            test_find_dropped_intents_skips_recent;
        ] );
      ( "is_terminal_status",
        [
          test_case "terminal vs active status" `Quick
            test_is_terminal_status;
        ] );
      ( "cleanup_result_to_json",
        [
          test_case "serializes correctly" `Quick
            test_cleanup_result_to_json;
        ] );
      ( "cutoff_iso",
        [
          test_case "produces valid ISO format" `Quick
            test_cutoff_iso_format;
        ] );
    ]
