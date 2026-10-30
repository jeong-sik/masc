(** Read-only composition outcome, separate from activation delivery and actions.
    Only the original producer-owned canonical execution can supply a
    disposition. Missing, conflicting and unreadable evidence never proves success. *)
type t = private
  | Recorded of
      { execution_id : string
      ; disposition : (unit, unit, unit) Tool_result.disposition
      }
  | Unrecorded
  | Unavailable of string

val of_rows :
  keeper_name:string ->
  rows:(Yojson.Safe.t list, string) result ->
  Keeper_skill_activation_ledger.activation -> t
(** Match keeper, trace/session, absolute turn, SDK turn, call and tool.
    Duplicate execution rows or conflicting source coordinates are unavailable.
    Runtime profile is an assignment, not the actual attempt runtime, so it
    is not compared with the activation runtime. The producer-owned physical
    execution ID supplies that invocation authority across failover.
    Instruction and nested activations return Unrecorded. Child logical
    executions do not inherit the parent's physical completion. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
