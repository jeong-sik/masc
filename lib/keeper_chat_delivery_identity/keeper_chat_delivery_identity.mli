(** Typed immutable identity shared by Keeper operations, Fusion runs,
    durable delivery journals, and transcript idempotency slots. *)

module Request_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type delivery_key =
  | Operation of Request_id.t
  | Fusion_run of Request_id.t
  | Workspace_message of Request_id.t
  | Approval_lifecycle of Request_id.t

(** [Workspace_message] identifies one producer-minted workspace broadcast.
    It lets a mentioned Keeper append that exact broadcast to its durable
    transcript once without treating the broadcast as a chat operation. *)

type transcript_slot =
  | Accepted_user
  | Tool_call of
      { execution_id : Ids.Execution_id.t
      ; ordinal : int
      }
  | Tool_delivery of { ordinal : int }
  | Terminal_assistant
  | Approval_resolution
  | Approval_replay
  | Approval_replay_correction
  | Approval_continuation

(** [Tool_call] identifies a row by the canonical execution committed by the
    tool log. [Tool_delivery] is the store-owned ordinal used only when no
    canonical execution exists. It deliberately carries no provider id: a
    provider id may be absent or reused and is not execution authority. *)

(** The persisted provenance pair. A durable row carries both halves or
    neither: a delivery key without its transcript slot cannot answer
    "was this exact row already appended?", and a slot without its key
    belongs to no delivery. Constructing the pair is the only way to
    persist either half. *)
type delivery_provenance =
  { delivery_key : delivery_key
  ; transcript_slot : transcript_slot
  }

val delivery_key_to_yojson : delivery_key -> Yojson.Safe.t
val delivery_key_of_yojson : Yojson.Safe.t -> (delivery_key, string) result
val delivery_key_equal : delivery_key -> delivery_key -> bool
val transcript_slot_to_yojson : transcript_slot -> Yojson.Safe.t
val transcript_slot_of_yojson : Yojson.Safe.t -> (transcript_slot, string) result
val transcript_slot_equal : transcript_slot -> transcript_slot -> bool

(** The two JSON fields a row carries for {!delivery_provenance}, written
    together. *)
val delivery_provenance_fields :
  delivery_provenance -> (string * Yojson.Safe.t) list

(** Reads the pair back out of a row's fields. [Ok None] when neither field
    is present; [Error] when only one is present or either fails to decode.
    Both durable readers decode through this function, so the pair
    invariant cannot drift between them; they differ only in what they do
    with [Error] — see {!Keeper_chat_store.chat_message} and the
    append-once paths. *)
val delivery_provenance_of_fields :
  (string * Yojson.Safe.t) list -> (delivery_provenance option, string) result

val delivery_provenance_equal :
  delivery_provenance -> delivery_provenance -> bool
