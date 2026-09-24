(** Who said a User message in a Keeper's conversation (RFC-0468 §3.2).

    The speaker is decided where the message is created and travels as
    AGENT_CORE message metadata under {!Agent_core.Types.Input_speaker.key}.
    It is never read back out of the message text, never sent to a provider,
    and never added to or removed from a message after it was created: replay
    prefixes compare the whole message. The approval admission digest leaves
    the speaker out ({!Keeper_approval_input_admission}).

    A message created before this attribution existed has no entry. Readers
    report that as unknown and do not guess a kind. *)

type external_speaker =
  { channel : string
  ; user_id : string option
  ; user_name : string option
  }

(** A person or agent outside the host. [Keeper] is only for a sender that
    was matched exactly against the Keeper registry where the message was
    created; the shape of an id proves nothing (RFC-0468 §3.2). [Owner] is
    what a request without a connector speaker or a sender Keeper is, not an
    authentication fact. *)
type person =
  | Owner
  | Keeper of Keeper_identity.Keeper_id.t
  | External of external_speaker

(** Text the host wrote. The kind is fixed where the host creates the message,
    never recovered from the wording, which an operator can change. *)
type host_prompt =
  | Autonomous_wake of { answered_asks : person list }
      (** The autonomous-turn cue. An answered Ask is quoted in the same
          message as a board row; [answered_asks] names who answered each
          quoted row, in the order the rows appear. The rows stay in the one
          message so the provider request keeps its shape. *)
  | Official_client_resume
      (** The host's cue that resumes an official-client turn from its
          checkpoint ({!Keeper_direct_checkpoint_continuation.official_resume_message}).
          The requester did not write it. *)

type t =
  | Host_prompt of host_prompt
  | Person of person

type classification =
  | Absent
  | Present of t
  | Invalid of string
  | Duplicate

val equal : t -> t -> bool
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

(** The one-entry metadata to stamp on a message when it is created. *)
val metadata : t -> Agent_core.Types.metadata

val classify : Agent_core.Types.metadata -> classification

(** The person who answered an Ask, from the surface the answer arrived on.
    Only the dashboard is the operator. Every other surface is external,
    including [Agent]: an Ask answer carries no registry-matched sender. *)
val of_ask_responder : Keeper_ask.responder -> person

(** The value of a Librarian conversation header's [speaker=] field, e.g.
    [host:autonomous_wake], [owner], [keeper:"beta"]. Free text is quoted with
    OCaml string syntax so the header stays one line of space-separated
    fields. [Absent] renders [unknown]. [Invalid] renders [invalid("<reason>")]
    and [Duplicate] renders [duplicate]: the entry is shown as broken rather
    than guessed or dropped, and the Librarian keeps reading the conversation
    instead of stopping on one message. *)
val header_value : classification -> string
