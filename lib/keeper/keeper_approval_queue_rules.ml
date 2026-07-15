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

let id_rng = Random.State.make_self_init ()
let id_rng_mu = Stdlib.Mutex.create ()

let make_generated_id prefix =
  let uuid =
    Stdlib.Mutex.protect id_rng_mu (fun () -> Uuidm.v4_gen id_rng ())
  in
  prefix ^ "_" ^ Uuidm.to_string uuid
;;

(* Rule transactions include durable Eio file operations and are also reached
   by synchronous dashboard/test callers. Both contexts therefore share one
   cross-context authority; an OS mutex alone cannot be held across an Eio
   suspension by two fibers on the same Domain. *)
let rules_mutex = Cross_context_mutex.create ()

let with_rules_lock f = Cross_context_mutex.with_durable_lock rules_mutex f

let rules_path ~base_path () =
  Keeper_gate_path.always_allowed ~base_path
;;

let approval_rules_persistence_surface = "keeper_approval_rules"

let report_rules_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", approval_rules_persistence_surface; "reason", reason ]
        ())
    ~surface:approval_rules_persistence_surface
    ~reason
    ~path
    ~detail
;;

let rule_json_preview json =
  Yojson.Safe.to_string json |> String_util.utf8_prefix ~max_bytes:240
;;

let rec canonical_request_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_request_json value)
    |> List.stable_sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun canonical -> `Assoc canonical
  | `List items -> `List (List.map canonical_request_json items)
  | other -> other
;;

let request_fingerprint (input : Yojson.Safe.t) =
  let canonical_json = canonical_request_json input |> Yojson.Safe.to_string in
  Digestif.SHA256.(digest_string canonical_json |> to_hex)
;;

let nonempty_string_opt = function
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None
;;

let rule_identity_matches left right =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_name right.tool_name
  && String.equal left.request_fingerprint right.request_fingerprint
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

let load_rules_unlocked ~base_path () =
  let path = rules_path ~base_path () in
  let rec parse_entries index acc = function
    | [] ->
      let rules = List.rev acc in
      (match validate_unique_rules rules with
       | Ok _ as result -> result
       | Error reason ->
         report_rules_read_drop
           ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
           ~path
           ~detail:reason;
         Error { path; reason })
    | entry :: rest ->
      (match approval_rule_of_yojson_with_error entry with
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
           ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
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
          ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
          ~path
          ~detail:reason;
        Error { path; reason }
      | Error reason ->
        report_rules_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_rules_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let save_rules_unlocked ~base_path rules : (unit, rule_store_error) result =
  let path = rules_path ~base_path () in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    let json = `List (List.map approval_rule_to_yojson rules) in
    (match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
     | Ok () -> Ok ()
     | Error reason -> Error { path; reason })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path; reason = Printexc.to_string exn }
;;

let list_rules ~base_path () =
  with_rules_lock (fun () -> load_rules_unlocked ~base_path ())
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

let upsert_rule
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      ?created_by
      ?source_approval_id
      ()
  =
  with_rules_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint = request_fingerprint input in
      let candidate =
        { id = make_generated_id "rule"
        ; keeper_name
        ; tool_name
        ; request_fingerprint
        ; created_at = Unix.gettimeofday ()
        ; created_by
        ; source_approval_id
        }
      in
      (match List.find_opt (fun rule -> rule_identity_matches rule candidate) rules with
       | Some existing -> Ok (existing, false)
       | None ->
         (match save_rules_unlocked ~base_path (candidate :: rules) with
          | Ok () -> Ok (candidate, true)
          | Error error ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string ApprovalQueueFailures)
              ~labels:
                [ "keeper", keeper_name
                ; "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save)
                ]
              ();
            Log.Keeper.warn "upsert_rule: save failed: %s" (rule_store_error_to_string error);
            Error error)))
;;

let delete_rule ~base_path ~id () =
  with_rules_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      (match List.find_opt (fun rule -> String.equal rule.id id) rules with
       | None ->
         Error
           { path = rules_path ~base_path ()
           ; reason = Printf.sprintf "approval rule %s not found" id
           }
       | Some deleted ->
         let remaining = List.filter (fun rule -> not (String.equal rule.id id)) rules in
         (match save_rules_unlocked ~base_path remaining with
          | Ok () -> Ok deleted
          | Error _ as error -> error)))
;;

let find_matching_rule
      ~base_path
      ~keeper_name
      ~tool_name
      ~input
      ()
  =
  with_rules_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint = request_fingerprint input in
      (match
         List.find_opt
           (fun rule ->
              String.equal rule.keeper_name keeper_name
              && String.equal rule.tool_name tool_name
              && String.equal rule.request_fingerprint request_fingerprint)
           rules
       with
       | None -> Ok None
       | Some rule -> Ok (Some { rule_id = rule.id })))
;;
