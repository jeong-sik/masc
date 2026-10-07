(** Historical evidence for resuming work, not an open-work registry. *)
type t =
  { conversation : (Keeper_turn_fragments.observed_message list, string) result
  ; autonomous_reply : (Keeper_turn_fragments.observed_message list, string) result
  }

val empty : t
val collect : config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> t
(** Reads the recent direct conversation and latest internal assistant message
    independently, so a busy autonomous history cannot displace the user's
    request. Uses the trace from [meta], never a host-global history. *)
