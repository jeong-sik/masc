(** Historical evidence for resuming work, not an open-work registry. *)
type t =
  { conversation : (Keeper_turn_fragments.recent_messages, string) result
  ; autonomous_reply : (Keeper_turn_fragments.recent_messages, string) result
  }

val collect : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> t
(** Reads the recent direct conversation and latest internal assistant message
    independently, so a busy autonomous history cannot displace the user's
    request. Physical window omission remains explicit; it is not absence of
    conversation. Uses the trace from [meta], never a host-global history. *)

type transmission = Absent | Evidence of string | Preview of string | Unavailable of string
val transmit : base_path:string -> tools:Agent_core.Tool.t list -> t -> transmission
(** A bounded pinned-context view. Larger excerpts are content-addressed only
    when the actual tool surface offers the canonical reader. Failed storage
    or an unavailable reader never puts the oversized excerpt back inline. *)

val preview : base_path:string -> t -> transmission
(** An operator inspection of the current history excerpt, explicitly marked
    [Preview]. It can store a retrievable artifact without claiming that an
    as-yet-unselected runtime offers its reader. Storage failure remains
    [Unavailable], and [Absent] still means neither source yielded context. *)
