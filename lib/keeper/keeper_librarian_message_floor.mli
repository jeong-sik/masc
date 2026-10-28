(** Shared volatile inference for an exact message boundary. Producers retain
    source serialization, publication and cursor ownership. *)

(** The floor's rules, apart from how a question gets answered. The machine
    asks one question at a time, takes the outcome of each, and finishes with
    the ordered Memory program. It does no storage, provider call or clock
    read, so a caller that keeps every outcome can rebuild the machine after a
    restart and be asked the same next question. {!infer} drives it with
    Runtime calls. *)
module Machine : sig
  type t

  type read
  (** A frozen manifest bound to the one input it describes: one source per
      message in order with matching hashes, the Keeper the Memory store
      belongs to, and the unread messages already on record. *)

  val read :
    keeper_name:string ->
    sources:Keeper_librarian_unread.source list ->
    unread_messages:Keeper_librarian_unread.t list ->
    previous_state:string option ->
    Keeper_librarian.input -> (read, string) result
  (** Refuse an empty manifest, duplicate coordinates, a source whose hash
      differs from its message, a task attribution outside the input, and an
      input that belongs to another Keeper than [keeper_name]. *)

  val start :
    transaction_id:string -> plan:Keeper_librarian_memory_plan.t -> read ->
    (t, string) result
  (** [plan] is empty and holds the Memory the floor starts from. The plan's
      current facts are the first message's staged facts and the program's
      initial facts. *)

  type question = private
    { position : int
        (** Messages already decided. Host observations asked alone keep the
            position after the last message. *)
    ; input : Keeper_librarian.input
        (** One message with its attribution and the staged facts, or no
            message when [sources = []]. Host observations no accepted step has
            taken yet ride along. *)
    ; sources : Keeper_librarian_unread.source list
        (** The message's source, or [[]] for host observations alone. *)
    ; previous_state : string option
    ; unread_messages : Keeper_librarian_unread.t list
    }

  type finished = private
    { program : Keeper_memory_os_program.t
    ; working_state : string option
    ; served_by : Keeper_librarian_runtime.served_slot option
    }
  (** [working_state] and [served_by] are the last accepted step's, or the
      caller's [previous_state] and [None] when no step was accepted. *)

  type next = Ask of question | Finished of finished

  val next : t -> (next, string) result
  (** The same value until an outcome is applied. Finishing validates the
      ordered program against the frozen manifest. *)

  val answered :
    t -> served_by:Keeper_librarian_runtime.served_slot ->
    Keeper_librarian_runtime.memory_step -> (t, string) result
  (** The gated decision for the pending question. It stages its facts for the
      next message, hands on its working state, and takes the host
      observations that rode with the question. *)

  val unreadable :
    t -> reasons:Keeper_librarian_input_refusal.t list ->
    hole:Keeper_librarian_unread.t -> (t, string) result
  (** Every slot named an input refusal for the pending message. [hole] must
      name that message's source and exactly these causes. The message is
      recorded as unread and the floor moves on; host observations stay
      pending. Host observations asked alone cannot become unread. *)
end

type prepared = private
  { anchor : Keeper_memory_os_current.program_anchor
  ; program : Keeper_memory_os_program.t
  ; working_state : string option
  ; served_by : Keeper_librarian_runtime.served_slot option
  }
(** [working_state=None] means no step was accepted and no previous state was
    supplied. A producer that needs a continuation must infer one separately.
    [served_by=None] means no Memory decision was accepted in this walk. *)

type error = private
  { detail : string
  ; reports : Keeper_librarian_runtime.not_committed list
  }
(** Runtime failures preserve their actual reports in callback order.
    Structural, anchor and staging errors have no fabricated Runtime reports. *)

val infer :
  ?cli_runner:Keeper_lane_cli_oneshot.runner ->
  base_path:string -> keepers_dir:string -> keeper_name:string ->
  sources:Keeper_librarian_unread.source list ->
  unread_message:(Keeper_librarian_unread.source ->
    reasons:Keeper_librarian_input_refusal.t list ->
    (Keeper_librarian_unread.t, string) result) ->
  previous_state:string option ->
  unread_messages:Keeper_librarian_unread.t list ->
  Keeper_librarian.input -> (prepared, error) result
(** Bind the frozen manifest to every input message before dispatch, capture
    Memory once, and thread accepted private Runtime decisions through the
    staged facts in original source order. Only Runtime's actual exhausted
    API-walk evidence may become an unread message; verify the producer's
    returned source and refusal causes exactly.

    Preserve joined tool and counterpart observations until one Memory step
    accepts them. If every source is unread but observations remain, require
    a real observation-only Memory step. Its empty source list accounts for
    no conversation message. All final sources are partitioned exactly once
    between accepted steps and unread records.

    Apart from the initial Memory anchor capture and ordinary Runtime
    telemetry, this performs no storage, recovery, publication or cursor
    operation. Cancellation propagates. The caller must validate and serialize
    its source again while publishing the returned program. *)
