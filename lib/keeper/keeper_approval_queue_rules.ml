open Keeper_approval_queue_rules_types

let id_rng = Random.State.make_self_init ()
let id_rng_mu = Stdlib.Mutex.create ()

let make_generated_id prefix =
  let uuid =
    Stdlib.Mutex.protect id_rng_mu (fun () -> Uuidm.v4_gen id_rng ())
  in
  prefix ^ "_" ^ Uuidm.to_string uuid
;;

(* Rule reads and writes include Eio file operations and are also reached by
   synchronous dashboard/test callers. Both contexts therefore share one
   cross-context authority; writes defer cancellation after acquisition while
   reads remain cancellable. *)
let rules_mutex = Cross_context_mutex.create ()

let with_rules_read_lock f = Cross_context_mutex.with_lock rules_mutex f
let with_rules_write_lock f = Cross_context_mutex.with_durable_lock rules_mutex f

let store_path ~base_path =
  Keeper_gate_path.always_allowed ~base_path
;;

let approval_rules_persistence_surface = "keeper_approval_rules"

let report_rules_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store_core.inc_counter
        Otel_metric_names.metric_persistence_read_drops
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

let string_is_nonblank value = String.trim value <> ""

let require_nonblank_rule_field ~path field value =
  if string_is_nonblank value
  then Ok ()
  else Error { path; reason = field ^ " must be a non-blank string" }
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
  let path = store_path ~base_path in
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
  let path = store_path ~base_path in
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

let protect_store ~base_path f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error { path = store_path ~base_path; reason = Printexc.to_string exn }
;;

let list_rules ~base_path () =
  protect_store ~base_path (fun () ->
    with_rules_read_lock (fun () -> load_rules_unlocked ~base_path ()))
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
      ~created_by
      ~source_approval_id
      ~expires_at
      ()
  =
  protect_store ~base_path (fun () ->
    with_rules_write_lock (fun () ->
    let path = store_path ~base_path in
    let open Result.Syntax in
    let* () = require_nonblank_rule_field ~path "keeper_name" keeper_name in
    let* () = require_nonblank_rule_field ~path "tool_name" tool_name in
    let* () = require_nonblank_rule_field ~path "created_by" created_by in
    let* () = require_nonblank_rule_field ~path "source_approval_id" source_approval_id in
    let now = Unix.gettimeofday () in
    match expires_at with
    | Some value when not (Float.is_finite value) ->
      Error
        { path
        ; reason = "expires_at must be a finite number"
        }
    | Some value when value <= now ->
      Error
        { path
        ; reason = "expires_at must be in the future"
        }
    | None | Some _ ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint =
        Keeper_approval_queue_rules_types.request_fingerprint input
      in
      let candidate =
        { id = make_generated_id "rule"
        ; keeper_name
        ; tool_name
        ; request_fingerprint
        ; created_at = now
        ; created_by
        ; source_approval_id
        ; expires_at
        }
      in
      (match List.find_opt (fun rule -> rule_identity_matches rule candidate) rules with
       | Some existing when rule_expired ~now existing ->
         Error
           { path
           ; reason = "the exact approval rule is expired; delete it before creating another"
           }
       | Some existing
         when not (Option.equal Float.equal existing.expires_at candidate.expires_at) ->
         Error
           { path
           ; reason = "the exact approval rule has a different expiry"
           }
       | Some existing -> Ok (existing, false)
       | None ->
         (match save_rules_unlocked ~base_path (candidate :: rules) with
          | Ok () -> Ok (candidate, true)
          | Error error ->
            Otel_metric_store_core.inc_counter
              Keeper_metrics.(to_string ApprovalQueueFailures)
              ~labels:
                [ "keeper", keeper_name
                ; "site", Keeper_approval_queue_failure_site.(to_label Upsert_rule_save)
                ]
              ();
            Log.Keeper.warn "upsert_rule: save failed: %s" (rule_store_error_to_string error);
            Error error))))
;;

let delete_rule ~base_path ~id () =
  protect_store ~base_path (fun () ->
    with_rules_write_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      (match List.find_opt (fun rule -> String.equal rule.id id) rules with
       | None ->
         Error
           { path = store_path ~base_path
           ; reason = Printf.sprintf "approval rule %s not found" id
           }
       | Some deleted ->
         let remaining = List.filter (fun rule -> not (String.equal rule.id id)) rules in
         (match save_rules_unlocked ~base_path remaining with
          | Ok () -> Ok deleted
          | Error _ as error -> error))))
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
  protect_store ~base_path (fun () ->
    with_rules_read_lock (fun () ->
    match load_rules_unlocked ~base_path () with
    | Error _ as error -> error
    | Ok rules ->
      let request_fingerprint =
        Keeper_approval_queue_rules_types.request_fingerprint input
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
         else Ok (Rule_match_active matched))))
;;

module For_testing = struct
  let store_path = store_path
end
