(** Typed LLM-rewrite boundary over structurally partitioned Keeper history.

    Only ordinary User/Assistant text messages without provider metadata or a
    Tool call identity become {!eligible_unit}s. System messages, Tool
    messages, non-text content, closed Tool cycles, and the open-cycle suffix
    remain exact. This boundary does not decide semantic value; it only makes
    protected history impossible to target with a compaction decision. *)

module Summary : sig
  type t
  type error = Empty

  val create : string -> (t, error) result
  val to_string : t -> string
end

type t
type eligible_unit

type eligible_role =
  | User
  | Assistant

type decision

type apply_error =
  | Unknown_unit of int
  | Unit_source_mismatch of int
  | Duplicate_decision of int
  | Missing_decisions of int list

type outcome =
  | No_compaction of Agent_sdk.Types.message list
  | Compacted of Agent_sdk.Types.message list

val of_messages :
  Agent_sdk.Types.message list ->
  (t, Keeper_compaction_unit.structural_error) result

val eligible_units : t -> eligible_unit list
val unit_index : eligible_unit -> int
val unit_role : eligible_unit -> eligible_role
val unit_message : eligible_unit -> Agent_sdk.Types.message
val unit_text_blocks : eligible_unit -> string list

val keep : eligible_unit -> decision
val drop : eligible_unit -> decision
val summarize : eligible_unit -> Summary.t -> decision

(** Every eligible unit must have exactly one decision. Protected history is
    reinserted value- and constructor-exact. A summary replaces only the source
    message's content and preserves its role, name, Tool-call identity, and
    metadata. *)
val apply : t -> decision list -> (outcome, apply_error) result
