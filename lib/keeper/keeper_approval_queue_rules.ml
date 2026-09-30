(** Durable, nonblocking HITL queue state and exact Always Allowed rules.

    This module does not classify an effect, interpret an operation name, or
    own a Keeper lane. *)

(** Types, conversions, and JSON serialization extracted to
    [Keeper_approval_queue_rules_types].  State management below. *)

include Keeper_approval_queue_rules_types

let record_queue_failure ~keeper_name ~site ?(id = "-") ?(event_type = "-") exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:[ "keeper", keeper_name; "site", site ]
    ();
  Log.Keeper.warn
    "approval_queue: %s failed keeper=%s id=%s event=%s err=%s"
    site
    keeper_name
    id
    event_type
    (Printexc.to_string exn)
;;

(* ── Global queue (Lock-free Atomic.t) ───────────────────── *)

module SMap = Set_util.StringMap

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then () else atomic_update atomic f
;;

let pending : pending_approval SMap.t Atomic.t = Atomic.make SMap.empty

(* This module used to own an RNG and a mutex to reimplement what [Random_id]
   already provides. Its own entropy source meant the guarantee here was
   whatever [Random.State.make_self_init] gives, separate from the one the
   other 28 call sites rely on. *)
let make_generated_id prefix = prefix ^ "_" ^ Random_id.uuid_v7 ()

(* Rule reads and writes include Eio file operations and are also reached by
   synchronous dashboard/test callers. Both contexts therefore share one
   cross-context authority; writes defer cancellation after acquisition while
   reads remain cancellable. *)
let rules_mutex = Cross_context_mutex.create ()

let with_rules_read_lock f = Cross_context_mutex.with_lock rules_mutex f
let with_rules_write_lock f = Cross_context_mutex.with_durable_lock rules_mutex f

let rules_path ~base_path () =
  Keeper_gate_path.always_allowed ~base_path
;;

let approval_rules_persistence_surface = "keeper_approval_rules"

let report_rules_read_drop ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", approval_rules_persistence_surface; "reason", reason_wire ]
        ())
    ~surface:approval_rules_persistence_surface
    ~reason
    ~path
    ~detail
;;

let rule_json_preview json =
  Yojson.Safe.to_string json |> String_util.utf8_prefix ~max_bytes:240
;;

let nonempty_string_opt = function
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
;;

module Revision = Keeper_rule_revision

let rule_identity_matches = Revision.identity_equal
;;

let validate_unique_rules rules =
  let rec loop seen = function
    | [] -> Ok rules
    | (rule : approval_rule) :: rest ->
      if List.exists (fun previous -> String.equal previous.id rule.id) seen
      then Error (Printf.sprintf "duplicate approval rule id %s" rule.id)
      else if List.exists (fun previous -> rule_identity_matches previous rule) seen
      then
        Error
          (Printf.sprintf
             "duplicate exact Always Allowed identity for keeper=%s operation=%s"
             rule.keeper_name
             rule.tool_name)
      else loop (rule :: seen) rest
  in
  loop [] rules
;;

let validate_unique_rule_states states =
  match validate_unique_rules (List.map (fun (state : Revision.state) -> state.rule) states) with
  | Error _ as error -> error
  | Ok _ ->
      let rec loop seen = function
        | [] -> Ok states
        | (state : Revision.state) :: rest ->
            if List.exists (fun (previous : Revision.state) ->
              String.equal previous.revision state.revision
              || String.equal previous.operation_id state.operation_id) seen
            then Error "duplicate approval rule revision or operation ID"
            else loop (state :: seen) rest
      in loop [] states
;;

let load_rule_states_unlocked ~base_path () =
  let path = rules_path ~base_path () in
  let rec parse_entries index acc = function
    | [] ->
      let rules = List.rev acc in
      (match validate_unique_rule_states rules with
       | Ok _ -> Ok rules
       | Error reason ->
         report_rules_read_drop
           ~reason:Read_drop_reason.Invalid_payload
           ~path
           ~detail:reason;
         Error { path; reason })
    | entry :: rest ->
      (match Revision.state_of_yojson entry with
       | Ok rule -> parse_entries (index + 1) (rule :: acc) rest
       | Error reason ->
         let detail =
           Printf.sprintf
             "approval rule entry %d rejected (%s): %s"
             index
             reason
             (rule_json_preview entry)
         in
         report_rules_read_drop
           ~reason:Read_drop_reason.Invalid_payload
           ~path
           ~detail;
         Error { path; reason = detail })
  in
  try
    if not (Sys.file_exists path)
    then Ok []
    else (
      match Safe_ops.read_json_file_safe path with
      | Ok (`List entries) -> parse_entries 0 [] entries
      | Ok json ->
        let reason =
          Printf.sprintf
            "approval rules file must be a JSON list, got: %s"
            (rule_json_preview json)
        in
        report_rules_read_drop
          ~reason:Read_drop_reason.Invalid_payload
          ~path
          ~detail:reason;
        Error { path; reason }
      | Error reason ->
        report_rules_read_drop
          ~reason:Read_drop_reason.Entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_rules_read_drop
      ~reason:Read_drop_reason.Entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let save_rule_states_unlocked ~base_path rules : (unit, rule_store_error) result =
  let path = rules_path ~base_path () in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let json = `List (List.map Revision.state_to_yojson rules) in
    (match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
     | Ok () -> Ok ()
     | Error reason -> Error { path; reason })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let load_rules_unlocked ~base_path () =
  Result.map (List.filter_map Revision.rule) (load_rule_states_unlocked ~base_path ())
;;

let current_rule_state states candidate =
  List.find_opt (fun (state : Revision.state) -> rule_identity_matches state.rule candidate) states
;;

let prepare_rule_intent_unlocked ~base_path ~states ~operation_id candidate =
  Revision.prepare ~current:(current_rule_state states candidate)
    ~revision:(make_generated_id "rule_revision") ~operation_id
    ~presence:Revision.Active candidate
  |> Result.map_error (fun reason -> { path = rules_path ~base_path (); reason })
;;

(** Capture once before the approval decision is journaled. Applying or
    retrying must reuse this intent; a conflict must never refresh it. *)
let prepare_rule_intent ~base_path ~keeper_name ~tool_name ~input
    ~operation_id ?created_by ?source_approval_id ?expires_at () =
  with_rules_read_lock (fun () ->
    match load_rule_states_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok states ->
        let candidate =
          { id = make_generated_id "rule"; keeper_name; tool_name;
            request_fingerprint = Keeper_approval_request_fingerprint.request_fingerprint input;
            created_at = Unix.gettimeofday (); created_by; source_approval_id; expires_at } in
        prepare_rule_intent_unlocked ~base_path ~states ~operation_id candidate)
;;

type rule_application =
  | Rule_applied of approval_rule
  | Rule_already_applied of approval_rule
  | Rule_conflict of Revision.state option

let apply_rule_intent_unlocked ~base_path ~states intent =
  let current = current_rule_state states intent.Revision.next.rule in
  match Revision.decide ~current intent with
  | Revision.Conflict current -> Ok (Rule_conflict current)
  | Revision.Already_applied state -> Ok (Rule_already_applied state.rule)
  | Revision.Apply state ->
      let updated = state :: List.filter (fun (previous : Revision.state) ->
        not (rule_identity_matches previous.rule state.rule)) states in
      (match validate_unique_rule_states updated with
       | Error reason -> Error { path = rules_path ~base_path (); reason }
       | Ok _ ->
           match save_rule_states_unlocked ~base_path updated with
           | Ok () -> Ok (Rule_applied state.rule)
           | Error _ as error -> error)
;;

let apply_rule_intent ~base_path intent =
  match intent.Revision.next.presence with
  | Revision.Deleted -> Error { path = rules_path ~base_path ();
                               reason = "approval intent cannot delete a rule" }
  | Revision.Active -> with_rules_write_lock (fun () ->
    match load_rule_states_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok states -> apply_rule_intent_unlocked ~base_path ~states intent)
;;

let list_rules ~base_path () =
  with_rules_read_lock (fun () -> load_rules_unlocked ~base_path ())
;;

let list_rules_dashboard_json ~base_path () =
  Result.map
    (fun rules ->
       let rules =
         List.sort (fun left right -> Float.compare right.created_at left.created_at) rules
       in
       `List (List.map approval_rule_to_yojson rules))
    (list_rules ~base_path ())
;;

(** Ensure-only entrypoint for existing callers. Renewal uses a durable
    prepared intent. This entrypoint cannot resurrect a deleted rule. *)
let upsert_rule ~base_path ~keeper_name ~tool_name ~input ?created_by
    ?source_approval_id ?expires_at () =
  with_rules_write_lock (fun () ->
    match load_rule_states_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok states ->
        let candidate =
          { id = make_generated_id "rule"; keeper_name; tool_name;
            request_fingerprint = Keeper_approval_request_fingerprint.request_fingerprint input;
            created_at = Unix.gettimeofday (); created_by; source_approval_id; expires_at } in
        match current_rule_state states candidate with
        | Some { Revision.presence = Revision.Active; rule; _ } -> Ok (rule, false)
        | Some { Revision.presence = Revision.Deleted; _ } ->
            Error { path = rules_path ~base_path ();
                    reason = "deleted rule requires a new approval intent" }
        | None ->
            let operation_id = Option.value source_approval_id
                ~default:(make_generated_id "rule_operation") in
            match prepare_rule_intent_unlocked ~base_path ~states ~operation_id candidate with
            | Error _ as error -> error
            | Ok intent ->
                match apply_rule_intent_unlocked ~base_path ~states intent with
                | Ok (Rule_applied rule) -> Ok (rule, true)
                | Ok (Rule_already_applied rule) -> Ok (rule, false)
                | Ok (Rule_conflict _) ->
                    Error { path = rules_path ~base_path (); reason = "rule changed during creation" }
                | Error error ->
                    Otel_metric_store.inc_counter
                      Keeper_metrics.(to_string ApprovalQueueFailures)
                      ~labels:[ "keeper", keeper_name;
                        "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save) ] ();
                    Error error)
;;

let delete_rule ~base_path ~id () =
  with_rules_write_lock (fun () ->
    match load_rule_states_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok states ->
        match List.find_opt (fun (state : Revision.state) ->
          state.presence = Revision.Active && String.equal state.rule.id id) states with
        | None -> Error { path = rules_path ~base_path ();
                          reason = Printf.sprintf "approval rule %s not found" id }
        | Some state ->
            match Revision.prepare ~current:(Some state)
                ~revision:(make_generated_id "rule_revision")
                ~operation_id:(make_generated_id "rule_delete")
                ~presence:Revision.Deleted state.rule with
            | Error reason -> Error { path = rules_path ~base_path (); reason }
            | Ok intent ->
                match apply_rule_intent_unlocked ~base_path ~states intent with
                | Ok (Rule_applied rule | Rule_already_applied rule) -> Ok rule
                | Ok (Rule_conflict _) ->
                    Error { path = rules_path ~base_path (); reason = "rule changed during deletion" }
                | Error _ as error -> error)
;;

let find_matching_rule
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      (* NDT-OK: wall-clock default at this store I/O boundary; callers inject ~now. *)
      ?(now = Unix.gettimeofday ())
      ()
  =
  with_rules_read_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint =
        Keeper_approval_request_fingerprint.request_fingerprint input
      in
      (match
         List.find_opt
           (fun rule ->
              String.equal rule.keeper_name keeper_name
              && String.equal rule.tool_name tool_name
              && String.equal rule.request_fingerprint request_fingerprint)
           rules
       with
       | None -> Ok Rule_match_absent
       | Some rule ->
         let matched = { rule_id = rule.id } in
         if rule_expired ~now rule
         then Ok (Rule_match_expired matched)
         else Ok (Rule_match_active matched)))
;;
