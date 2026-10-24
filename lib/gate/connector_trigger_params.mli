(** Canonical live trigger-policy handles shared by ingress and observations. *)

val discord : Discord_gateway_state.trigger_policy Runtime_params.param
(** Effective Discord policy: persisted override, or the value resolved at
    gateway startup when no override is present. *)

val slack : Slack_gateway_state.trigger_policy Runtime_params.param
(** Effective Slack policy, with the same override/default contract. *)

val set_discord_configured : Discord_gateway_state.trigger_policy -> unit
(** Install the successfully resolved startup value before transport credential
    admission. Clearing an override returns to this value. *)

val set_slack_configured : Slack_gateway_state.trigger_policy -> unit
(** Install the successfully resolved Slack startup value. *)
