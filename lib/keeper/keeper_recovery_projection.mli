(** Pure source indexing and structural validation for recovery proposals.
    This module neither runs a model nor installs a Keeper transmission view. *)

type required_reason = User_instruction | Task_contract | Pending_continuation
[@@deriving yojson]
type requirement = { message_index : int; reason : required_reason }
[@@deriving yojson]
type atom =
  { atom_id : int
  ; first_message : int
  ; last_message : int
  ; requirements : requirement list
  ; pending_tool_cycle : bool
  }
[@@deriving yojson]
type source

type error =
  | Required_message_missing of int
  | Invalid_transcript of Keeper_transcript_unit.structural_error
  | Source_changed
  | Atom_order_mismatch of { expected : int; actual : int }
  | Invalid_atom_range of { first : int; last : int }
  | Protected_atom of int
  | Empty_summary
  | Incomplete_partition of int

val error_to_string : error -> string
val index
  : source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> required:requirement list
  -> (source, error) result
(** Reuses [Keeper_transcript_unit.partition] and its existing strict protocol
    contract. Closed tool exchanges are indivisible atoms; the entire open tail
    is protected. No second ID matcher or protocol repair is introduced.
    Required source positions are authored by the Keeper Owner, never by the
    proposing model; this module validates membership, not whether the owner
    identified every obligation. *)

val source_reference : source -> Keeper_checkpoint_ref.t
val atoms : source -> atom list

type step =
  | Retain of int
  | Summarize of { first_atom : int; last_atom : int; text : string }
[@@deriving yojson]
type proposal = { source_sha256 : string; steps : step list }
[@@deriving yojson]
type derived =
  { text : string
  ; source_sha256 : string
  ; first_message : int
  ; last_message : int
  }
type segment = Original of Agent_core.Types.message list | Derived of derived
type validated

val validate : source:source -> proposal -> (validated, error) result
(** Every source atom appears exactly once, in order. Required and pending
    atoms cannot be summarized. Summaries are explicitly derived text citing
    their exact source range, never synthetic assistant or ToolResult records.
    This proves structural coverage only, not truth, faithfulness, read coverage,
    provider fit or successful Keeper recovery. *)
val segments : validated -> segment list
val bind_exact
  : current_source:Keeper_checkpoint_store.exact_checkpoint_snapshot
  -> validated -> (segment list, error) result
(** Refuses any checkpoint revision change, including append. A later owner
    integration must additionally bind pending stimuli and transmission config;
    this pure exact-source check does not CAS or mutate the live checkpoint. *)
