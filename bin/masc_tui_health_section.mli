(** The server health section an operator action names.

    The server rolls these sections up into the actions the Overview lists
    under "조치가 필요한 이유" and sends each one's section name as a string.
    The Overview matched three of those strings and drew every other one as
    it arrived, so [keeper_fleet_safety] and [keeper_reaction_ledger] sat on
    the operator's screen as wire identifiers (RFC tui-one-screen-grammar
    §7.1). The name is decoded here once, and each section has its label. *)

type t =
  | Fd_observation
  | Fd_accountant
  | Provider_connection_cache
  | Disk_observation
  | Keeper_fleet_safety
  | Keeper_identity_drift
  | Keeper_memory_execution
  | Keeper_memory_attention
  | Publication_recovery_activation
  | Keeper_reaction_ledger
  | Keeper_owner
  | Keeper_board_event_collection
  | Keeper_hitl_gate
  | Keeper_event_queue
  | Keeper_waiting_inventory
  | Typesafeai
  | Keeper_terminal_effect_policy
  | Keeper_observability_artifacts
  | Skill_catalog
  | Tla_source_observation
  | Auxiliary_startup
  | Paused_keepers
  | Runtime_startup_degradation
  | Keeper_config_schema

val of_wire : string -> (t, string) result
(** The section a wire name stands for. A name this build does not know is
    [Error] with the name as received, so the screen can draw it as
    received rather than guess a section for it. *)

val wire_name : t -> string
(** The name the server sends for the section. *)

val label : ko:bool -> t -> string
(** The section's name on the screen. Where another screen already names
    the section, the label is that name ([이벤트 큐], [대기 목록],
    [기억 처리]). The others keep the words their server name is made of,
    in both languages, until the screen-language layer gives them Korean
    words: this module does not coin them. *)
