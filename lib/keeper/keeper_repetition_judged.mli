(** The repetition boundary has two independent coordinates: matched pairs
    in one generation of Agent Core history and authoritative append positions
    in the tool-call ledger. A sliding row count is never a ledger position.

    The record rides the Session context through Agent Core checkpoints and
    lives in the shared loop context on official-client lanes. A repetition yield advances its positions; an authoritative history rewrite
    replaces its history generation and resets that count. A cold process restores the durable record;
    observations held only in the loop context are replayed from the ledger. *)

type history_generation = Initial | Rewritten of string

type t =
  { history_generation : history_generation
  ; history_pairs : int
  ; ledger_frontier : Keeper_tool_call_index.frontier
  }

type error = Invalid_record of string

val error_to_string : error -> string

val context_key : string

val read : Agent_core.Context.t -> (t, error) result
(** Missing record means neither source has been judged. Malformed records
    are errors, not an empty boundary. *)

val restore
  : source:Agent_core.Context.t -> target:Agent_core.Context.t -> (t, error) result
(** Merge the independent positions from durable and loop-lived contexts.
    A present source checkpoint owns its history generation: a changed generation
    replaces the live history count, while equal generations preserve the larger
    count. An absent source record preserves live progress. Ledger positions
    are merged independently within their physical file identities. *)

val reset_history : Agent_core.Context.t -> (Agent_core.Context.t, error) result
(** Copy a checkpoint context and reset only its history coordinate with a
    fresh durable generation. Call alongside an authoritative history rewrite;
    the source context remains unchanged until its checkpoint is installed. *)

val record : Agent_core.Context.t -> t -> unit

(** [seed_beyond ~judged pairs] keeps the newest [length pairs - judged] of
    [pairs] (newest first): everything a previous yield has not judged.
    [judged] at or past the length keeps nothing. *)
val seed_beyond
  :  judged:int
  -> Keeper_agent_result.tool_call_detail list
  -> Keeper_agent_result.tool_call_detail list
