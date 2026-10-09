(** Shared chat data and closed wire vocabularies. No storage or runtime effects. *)

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
  (** Pixel dimensions measured before externalizing the attachment payload.
      [None] when the supported image headers do not provide dimensions.
      Persisted [data] is a canonical blob marker; the retained blob contains
      the original wire payload (base64 or data URI). *)
  width : int option;
  height : int option;
}

(** One executed tool call within a turn. [args] holds the accumulated
    argument JSON; empty arguments are persisted as ["{}"]. *)
type tool_call = {
  call_id : string;
  execution_id : Ids.Execution_id.t option;
      (** Canonical execution identity after the tool-call log commit. [None]
          when the producer cannot prove an exact join, including malformed or
          ambiguous provider streams. Distinct from provider [call_id]. *)
  call_name : string;
  args : string;
}

(** Lane line role as a closed sum (RFC-0232 P1). Parsed once at the
    read boundary; a line whose persisted label is none of
    ["user"] / ["assistant"] / ["system"] / ["tool"] is reported as a persistence
    read drop and excluded — it can participate in no lane semantics
    (watermark, pending, rendering). On-disk labels are unchanged. *)
module Role : sig
  type t =
    | User
    | Assistant
    | System
    | Tool

  val to_label : t -> string
  val of_label : string -> t option
  val equal : t -> t -> bool
end

(** What an assistant line {e is}, declared by the writer at append.
    [Utterance] is something the keeper actually said.
    [Transport_failure] is the server persisting a failed request
    terminal (["Keeper request failed: ..."]) so the operator still sees
    the failure after a reload — it is {e not} a self reply: it does not
    advance the lane watermark, so the user line it failed to answer
    stays pending until the keeper's next real utterance, and
    observation never quotes it back as the keeper's own words.
    Persisted as ["kind"]; the field is absent for utterances, so rows
    written before it existed read unchanged. *)
module Row_kind : sig
  type t =
    | Utterance
    | Transport_failure

  val to_label : t -> string
  val of_label : string -> t option
  val equal : t -> t -> bool
end

(** Closed, durable names for AG-UI lifecycle events recorded by the direct
    Keeper chat stream. This is server lifecycle provenance, not a
    client-delivery receipt. *)
type stream_lifecycle_event =
  | Run_started
  | Text_message_start
  | Text_message_end
  | Run_finished
  | Run_error

(** One durable row of an approval's lifecycle
    ({!Keeper_approval_lifecycle.approval_lifecycle_phase}). The store keeps
    and reads these rows; the phase vocabulary and its labels live in the
    HITL contract. *)
type approval_lifecycle =
  { approval_id : string
  ; tool_name : string option
  ; phase : Keeper_approval_lifecycle.approval_lifecycle_phase
  ; artifact_ref : Tool_output.artifact_ref option
  ; call_summary : string option
        (** The one line the producing tool stated for its call, from its
            typed input ({!Keeper_gate.request.call_summary}), whole: fitting
            it to a pane is the renderer's decision. About the approval, not
            the phase, so the request row carries the statement and every
            later phase row copies it ([approval_request_call_summary]); a
            row then reads on its own when the pane loads a history window
            that does not include the request. [None] when the tool stated
            nothing or no request row exists to copy from. *)
  }

type append_once_result =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

(** Exact ownership of the accepted user transcript row. This provenance is
    shared by direct and queued delivery, while lifecycle authority remains in
    the owning request or queue store. *)
type user_row_origin =
  | Needs_append
  | Already_persisted_upstream

(** Authority class of the human (or agent) whose message opened a
    turn. Derived structurally from the arrival route, never from
    message content: the authenticated dashboard route is [Owner];
    anything carrying connector context is [External]; a sender that the
    producing site matched exactly against the Keeper registry is [Keeper],
    with the Keeper's id in [speaker_id] (RFC-0468 §3.2). Persisted as
    ["owner"] / ["external"] / ["keeper"] in [speaker_authority]
    (RFC-0223 §3). *)
type speaker_authority =
  | Owner
  | External
  | Keeper

val authority_label : speaker_authority -> string
val authority_of_label : string -> speaker_authority option

(** Rich chat block produced by the backend parser. Mirrors the dashboard's
    [ChatBlock] union so the server can own parsing and the dashboard can
    render server-provided blocks verbatim. *)
type chat_block = Keeper_chat_blocks.chat_block

(** Identity of the user-line author. [speaker_id] / [speaker_name] are
    absent when the route supplies none (the dashboard is a single
    authenticated operator and carries no per-user identity). *)
type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}
(** Persistable audio clip (RFC-0235 P1). Written on an assistant line
    when the keeper synthesized a voice utterance; [token] is the
    [/api/v1/voice/audio/:token] capability, [message_text] doubles as
    the caption. [audio_url] and [device_id] carry transport routing hints
    so the dashboard can fetch and route the clip. [expired] is true when
    the clip has been reaped; the history endpoint stamps it by
    checking the audio directory. Same shape as
    {!Keeper_chat_broadcast}'s SSE payload so the two never drift. *)

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

val keeper_speaker : Keeper_identity.Keeper_id.t -> speaker
(** The speaker of a line another registered Keeper sent. The caller has
    already matched the sender against the Keeper registry; the id is not
    read back from the shape of any string here. [speaker_id] and
    [speaker_name] both carry the Keeper id, since a Keeper has exactly one
    name (RFC-0393). *)

type chat_message = {
  id : string;
      (** R3: producer-assigned stable message id, minted once at append by
          the sole writer ([encode_line]) and read back verbatim, so the
          dashboard keys off a server identity rather than synthesising an
          index-derived id at render. Rows without a nonblank persisted id
          are rejected at the read boundary. *)
  role : Role.t;
  content : string;
  ts : float;
  attachments : attachment list option;
  tool_call_id : string option;
  execution_id : Ids.Execution_id.t option;
  tool_call_name : string option;
  surface : Surface_ref.t option;
      (** The typed surface (RFC-0232 §3.6).  [None] on rows written
          before P5 and on rows whose persisted surface payload fails
          to decode (reported as a persistence read drop, row kept). *)
  conversation_id : string option;
  external_message_id : string option;
  workspace_id : string option;
      (** The connector workspace (guild/team) identity from the typed
          delivery. Written on connector-intake user lines; [None] on
          workspace-less deliveries (e.g. Discord DM), rows written before
          this field existed, and non-connector lines. *)
  speaker : speaker option;
      (** Present on user lines written since RFC-0223 P1; [None] on
          older lines, tool/assistant lines, and lines whose persisted
          [speaker_authority] label fails to parse (reported as a
          persistence read drop, row otherwise kept). *)
  audio : audio_clip option;
      (** RFC-0235 P1: present when this assistant line was a synthesized
          voice utterance (keeper_voice_speak). [None] on every other
          line and on rows written before voice transport; the dashboard
          renders a play button when present. *)
  blocks : chat_block list option;
      (** RFC-0235 P3: rich chat blocks parsed from assistant reply text.
          Persisted server-side so the dashboard can prefer backend blocks
          over its local parser. [None] on rows written before this field
          and on non-assistant rows. *)
  mentions : Keeper_identity.Keeper_id.t list;
      (** RFC-0232 §3.3: mention ids parsed once at append from the
          persisted user content (plus connector-supplied explicit
          mentions), unless the writer explicitly selected passive context.
          [[]] on passive context, tool/assistant lines, mention-free lines,
          and rows written before P4 (the offline backfill tool stamps
          those).  Malformed persisted entries are reported as
          persistence read drops and skipped; the row stays valid. *)
  kind : Row_kind.t;
      (** Absent persisted kind means [Utterance]. A present field must
          name a known kind; malformed values are reported and the row is
          rejected, so unknown input cannot acknowledge keeper speech. *)
  turn_ref : Ids.Turn_ref.t option;
      (** RFC-0233 §7: ["<trace_id>#<absolute_turn>"] join key for the turn
          that produced this row.  Stamped by [append_turn] /
          [append_assistant_message] when the caller supplies it; [None]
          on inbound user lines (no turn yet) and rows written before §7.
          A malformed persisted value is reported as a persistence read
          drop and reads as [None]; the row stays valid. *)
  stream_lifecycle : stream_lifecycle_event list option;
      (** K1f: durable server lifecycle replay for the chat stream response
          represented by this row. [None] means the row predates this field or
          the writer could not prove lifecycle events. Malformed persisted
          values are reported as persistence read drops and read as [None];
          the row stays valid. *)
  approval_lifecycle : approval_lifecycle option;
      (** Present only on system-owned Gate lifecycle rows. The typed phase
          keeps "approved" separate from "effect applied" and carries the
          exact replay artifact reference when an effect has settled. *)
  delivery_provenance :
    Keeper_chat_delivery_identity.delivery_provenance option;
      (** The exact delivery identity and transcript slot persisted atomically
          by the idempotent append-once paths ([append_user_message_once] /
          [append_assistant_message_once]).  [None] on rows written by the
          plain append paths and on rows written before this pair existed.

          A malformed persisted value is reported as a persistence read drop
          and reads as [None] here; the row stays valid. That leniency is
          local to reading rows out. The append-once paths decode the same
          persisted pair to answer "is this delivery already on disk?", and
          there an undecodable row fails the whole append instead — skipping
          it would append a duplicate. So a row this field cannot decode is
          not merely cosmetic: it blocks every later append to that keeper's
          file until the row is repaired or removed. *)
}


val stream_lifecycle_event_to_label : stream_lifecycle_event -> string
val stream_lifecycle_event_of_label : string -> stream_lifecycle_event option
