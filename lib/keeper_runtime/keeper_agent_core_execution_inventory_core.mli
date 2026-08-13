(** Pure operator projection for durable Keeper Agent Core execution journals.

    This module receives only typed record observations.  It never reads the
    filesystem and never exposes journal payloads, prompts, responses, or
    reasoning content. *)

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

type entry_fingerprint = private string

type entry_key =
  | Operation_id of Keeper_agent_core_execution_identity.operation_id
  | Redacted_entry of entry_fingerprint

type entry =
  { key : entry_key
  ; state : state
  }

type t = private { entries : entry list }

val classify
  :  locator:locator_observation
  -> terminal:terminal_observation
  -> state

val operation_entry
  :  Keeper_agent_core_execution_identity.operation_id
  -> state
  -> entry

val unrecognized_entry : entry_name:string -> entry
(** Return a corrupt entry keyed only by a one-way fingerprint. *)

val create : entry list -> t
val entry_fingerprint_to_string : entry_fingerprint -> string
val to_yojson : t -> Yojson.Safe.t
