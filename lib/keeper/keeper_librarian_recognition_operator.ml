module Ledger = Keeper_librarian_recognition_ledger

type request = Ledger.pending_repair

type outcome =
  { action : request
  ; repair : Ledger.repair_outcome
  }

type error =
  | Invalid_request of string
  | Admission_busy of Keeper_turn_admission.autonomous_block
  | Repair_failed of Ledger.repair_error

type error_class = [ `Bad_request | `Not_found | `Conflict | `Unavailable ]

let action_to_string = function
  | Ledger.Abort_preserving_current -> "abort_preserving_current"
  | Ledger.Restore_store_before -> "restore_store_before"
  | Ledger.Settle_store_after -> "settle_store_after"
;;

let request_of_yojson = function
  | `Assoc [ ("action", `String action) ] ->
    (* STR-OK: strict untrusted HTTP action parsing into a closed variant. *)
    (match action with
     | "abort_preserving_current" -> Ok Ledger.Abort_preserving_current
     | "restore_store_before" -> Ok Ledger.Restore_store_before
     | "settle_store_after" -> Ok Ledger.Settle_store_after
     | _ -> Error (Printf.sprintf "unsupported recognition repair action %S" action))
  | `Assoc fields when List.mem_assoc "action" fields ->
    Error "recognition repair request has unexpected or duplicate fields"
  | `Assoc _ -> Error "recognition repair request requires string \"action\""
  | _ -> Error "recognition repair request must be an object"
;;

let execute config ~keeper_name action =
  match
    Keeper_turn_admission.run_admin_if_free
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun () ->
         Keeper_librarian_runtime.repair_pending_publication_for_masc_root
           ~masc_root:(Workspace.masc_root_dir config)
           ~keeper_id:keeper_name
           ~action
           ())
  with
  | `Busy block -> Error (Admission_busy block)
  | `Ran (Error error) -> Error (Repair_failed error)
  | `Ran (Ok repair) -> Ok { action; repair }
;;

let terminal_outcome_to_json = function
  | Ledger.Terminal_durable ->
    "durable", `Null
  | Ledger.Terminal_durable_marker_clear_uncertain detail ->
    "durable_marker_clear_uncertain", `String detail
;;

let outcome_to_yojson { action; repair } =
  let publication_id, terminal_state, terminal =
    match repair with
    | Ledger.Repaired_aborted (publication_id, terminal) ->
      publication_id, "aborted", terminal
    | Ledger.Repaired_committed (publication_id, terminal) ->
      publication_id, "committed", terminal
  in
  let durability, warning = terminal_outcome_to_json terminal in
  `Assoc
    [ "ok", `Bool true
    ; "action", `String (action_to_string action)
    ; "publication_id", `String publication_id
    ; "publication_state", `String terminal_state
    ; "durability", `String durability
    ; "warning", warning
    ]
;;

let error_to_string = function
  | Invalid_request detail -> detail
  | Admission_busy block ->
    "keeper turn admission busy: "
    ^ Keeper_turn_admission.autonomous_block_to_string block
  | Repair_failed error -> Ledger.repair_error_to_string error
;;

let error_class = function
  | Invalid_request _ -> `Bad_request
  | Admission_busy _ -> `Conflict
  | Repair_failed Ledger.No_pending_publication_to_repair -> `Not_found
  | Repair_failed (Ledger.Pending_repair_marker_invalid _) -> `Conflict
  | Repair_failed
      ( Ledger.Pending_repair_prepared_failed _
      | Ledger.Pending_repair_rewrite_failed _
      | Ledger.Pending_repair_episode_failed _
      | Ledger.Pending_repair_event_failed _
      | Ledger.Pending_repair_terminal_failed _
      | Ledger.Pending_repair_io_failed _ ) ->
    `Unavailable
;;

let error_to_yojson error =
  `Assoc
    ([ "ok", `Bool false; "error", `String (error_to_string error) ]
     @
     match error with
     | Invalid_request _ -> [ "error_code", `String "invalid_request" ]
     | Admission_busy block ->
       [ "error_code", `String "keeper_turn_admission_busy"
       ; "admission", Keeper_turn_admission.autonomous_block_to_yojson block
       ]
     | Repair_failed Ledger.No_pending_publication_to_repair ->
       [ "error_code", `String "no_pending_publication" ]
     | Repair_failed _ ->
       [ "error_code", `String "recognition_repair_failed" ])
;;
