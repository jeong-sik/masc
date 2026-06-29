(** Operator-remote tool-name SSOT.

    This list is the externally advertised operator tool surface used by
    remote MCP profiles and dashboard governance recommendations. *)

type t =
  | Operator_snapshot
  | Operator_digest
  | Operator_action
  | Operator_confirm
  | Surface_audit

val to_string : t -> string
val all : t list
val all_strings : string list
