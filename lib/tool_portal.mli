open Base

(** Portal tools — agent-to-agent direct messaging.
    Tool handlers removed (deprecated #4999).
    Only filter_visible_tool_names retained for keeper agent run. *)

type context = {
  config: Coord.config;
  agent_name: string;
}

val filter_visible_tool_names : context -> string list -> string list
