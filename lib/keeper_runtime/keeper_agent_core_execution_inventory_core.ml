type terminal_record = Agent_core.Agent.execution_terminal_disposition

type locator_observation =
  | Locator_missing
  | Locator_valid
  | Locator_invalid

type terminal_observation =
  | Terminal_missing
  | Terminal_valid of terminal_record
  | Terminal_invalid

type ambiguity =
  | Scope_without_records
  | Retired_terminal_with_locator
  | Repair_terminal_without_locator

type corruption =
  | Unrecognized_operation_directory
  | Scope_not_directory
  | Scope_unreadable
  | Locator_record_invalid
  | Terminal_record_invalid
  | Both_records_invalid

type state =
  | Active
  | Terminal of terminal_record
  | Operator_repair_required of terminal_record
  | Ambiguous of ambiguity
  | Corrupt of corruption

type entry_fingerprint = string

type entry_key =
  | Operation_id of Keeper_agent_core_execution_identity.operation_id
  | Redacted_entry of entry_fingerprint

type entry =
  { key : entry_key
  ; state : state
  }

type t = { entries : entry list }

let classify ~locator ~terminal =
  match locator, terminal with
  | Locator_invalid, Terminal_invalid -> Corrupt Both_records_invalid
  | Locator_invalid, _ -> Corrupt Locator_record_invalid
  | _, Terminal_invalid -> Corrupt Terminal_record_invalid
  | Locator_missing, Terminal_missing -> Ambiguous Scope_without_records
  | Locator_valid, Terminal_missing -> Active
  | Locator_missing, Terminal_valid terminal ->
    (match terminal.Agent_core.Agent.recovery with
     | Agent_core.Agent.Retire -> Terminal terminal
     | Agent_core.Agent.Operator_repair_required
         Agent_core.Agent.Effect_outcome_unknown ->
       Ambiguous Repair_terminal_without_locator)
  | Locator_valid, Terminal_valid terminal ->
    (match terminal.Agent_core.Agent.recovery with
     | Agent_core.Agent.Retire -> Ambiguous Retired_terminal_with_locator
     | Agent_core.Agent.Operator_repair_required
         Agent_core.Agent.Effect_outcome_unknown ->
       Operator_repair_required terminal)
;;

let operation_entry operation_id state = { key = Operation_id operation_id; state }

let unrecognized_entry ~entry_name =
  let fingerprint =
    "execution-entry-v1-"
    ^ Digestif.SHA256.(digest_string entry_name |> to_hex)
  in
  { key = Redacted_entry fingerprint; state = Corrupt Unrecognized_operation_directory }
;;

let create entries = { entries }
let entry_fingerprint_to_string fingerprint = fingerprint

let terminal_outcome_to_string = function
  | Agent_core.Agent.Terminal_succeeded -> "succeeded"
  | Agent_core.Agent.Terminal_failed -> "failed"
  | Agent_core.Agent.Terminal_cancelled -> "cancelled"
;;

let recovery_action_to_string = function
  | Agent_core.Agent.Retire -> "retire"
  | Agent_core.Agent.Operator_repair_required Agent_core.Agent.Effect_outcome_unknown ->
    "operator_repair_required_effect_outcome_unknown"
;;

let terminal_to_yojson (terminal : terminal_record) =
  `Assoc
    [ "outcome", `String (terminal_outcome_to_string terminal.outcome)
    ; "recovery", `String (recovery_action_to_string terminal.recovery)
    ]
;;

let ambiguity_to_string = function
  | Scope_without_records -> "scope_without_records"
  | Retired_terminal_with_locator -> "retired_terminal_with_locator"
  | Repair_terminal_without_locator -> "repair_terminal_without_locator"
;;

let corruption_to_string = function
  | Unrecognized_operation_directory -> "unrecognized_operation_directory"
  | Scope_not_directory -> "scope_not_directory"
  | Scope_unreadable -> "scope_unreadable"
  | Locator_record_invalid -> "locator_record_invalid"
  | Terminal_record_invalid -> "terminal_record_invalid"
  | Both_records_invalid -> "both_records_invalid"
;;

let state_to_yojson = function
  | Active -> `Assoc [ "kind", `String "active" ]
  | Terminal terminal ->
    `Assoc [ "kind", `String "terminal"; "terminal", terminal_to_yojson terminal ]
  | Operator_repair_required terminal ->
    `Assoc
      [ "kind", `String "operator_repair_required"
      ; "terminal", terminal_to_yojson terminal
      ]
  | Ambiguous ambiguity ->
    `Assoc
      [ "kind", `String "ambiguous"
      ; "reason", `String (ambiguity_to_string ambiguity)
      ]
  | Corrupt corruption ->
    `Assoc
      [ "kind", `String "corrupt"
      ; "reason", `String (corruption_to_string corruption)
      ]
;;

let entry_to_yojson entry =
  let key =
    match entry.key with
    | Operation_id operation_id ->
      `Assoc
        [ "kind", `String "operation_id"
        ; ( "operation_id"
          , `String
              (Keeper_agent_core_execution_identity.operation_id_to_string
                 operation_id) )
        ]
    | Redacted_entry fingerprint ->
      `Assoc
        [ "kind", `String "redacted_entry"
        ; "fingerprint", `String fingerprint
        ]
  in
  `Assoc [ "key", key; "state", state_to_yojson entry.state ]
;;

let to_yojson inventory =
  `Assoc
    [ "schema", `String "masc.keeper.agent_core.execution_inventory.v1"
    ; "entries", `List (List.map entry_to_yojson inventory.entries)
    ]
;;
