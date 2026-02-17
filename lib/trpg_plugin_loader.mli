(** TRPG Plugin Loader

    Dynamic slot loading and lifecycle management for TRPG engine.
    Manages slot activation, configuration, and event broadcasting.

    @since 2.68.0
*)

(** {1 Plugin Configuration Types} *)

type plugin_config = {
  mutable enabled_slots : string list;               (** Active slot IDs *)
  slot_configs : (string * Yojson.Safe.t) list;  (** Per-slot config *)
}

(** Empty configuration with no slots enabled *)
val empty_plugin_config : plugin_config

(** Convert plugin config to/from JSON *)
val plugin_config_to_yojson : plugin_config -> Yojson.Safe.t
val plugin_config_of_yojson : Yojson.Safe.t -> (plugin_config, string) result

(** {1 Config File Loading} *)

(** Default path for plugin configuration file *)
val default_config_path : string

(** Load plugin configuration from JSON file

    @param path File path (default: [default_config_path])
    @return Ok config or Error with message
*)
val load_config_file : ?path:string -> unit -> (plugin_config, string) result

(** {1 Core Loader Operations} *)

(** Load and initialize all enabled slots

    Replaces any currently active slots. Each slot is initialized
    with its configuration from [slot_configs].

    @param config Plugin configuration
    @return Ok () or Error with messages (multiple errors concatenated)
*)
val load : ?config:plugin_config -> unit -> (unit, string) result

(** Reload from default config file

    Equivalent to [load ~config:(load_config_file ())].

    @return Ok () or Error with message
*)
val reload : unit -> (unit, string) result

(** {1 Event Broadcasting} *)

(** Broadcast event to all active slots

    Each slot's [apply_event] is called with its current state.
    Errors are logged but don't stop other slots from processing.

    @param event Engine event to broadcast
    @return List of (slot_id, new_state) pairs (Null on error)
*)
val broadcast_event : event:Trpg_engine_event.t -> (string * Yojson.Safe.t) list

(** {1 State Queries} *)

(** Get derived state from all active slots

    Each slot's [derive_state] is called with its current state.

    @return List of (slot_id, derived_state) pairs
*)
val get_states : unit -> (string * Yojson.Safe.t) list

(** Get derived state from a specific slot

    @param slot_id Slot identifier
    @return Ok derived_state or Error if slot not active
*)
val get_slot_state : slot_id:string -> (Yojson.Safe.t, string) result

(** {1 Slot Management} *)

(** List all currently active slots

    Returns slot_info for each active slot.
*)
val list_active_slots : unit -> Trpg_slot.slot_info list

(** List all registered slots in the registry

    Includes both active and inactive slots.
*)
val list_available_slots : unit -> Trpg_slot.slot_info list

(** Enable a slot at runtime

    Initializes the slot with optional configuration.
    If slot is already active, returns Error.

    @param slot_id Slot to enable
    @param config Optional slot configuration
    @return Ok () or Error with message
*)
val enable_slot : slot_id:string -> ?config:Yojson.Safe.t -> unit -> (unit, string) result

(** Disable a slot at runtime

    Removes slot from active list. State is discarded.

    @param slot_id Slot to disable
    @return Ok () (no-op if slot not active)
*)
val disable_slot : slot_id:string -> (unit, string) result

(** {1 Configuration Persistence} *)

(** Save current configuration to file

    Writes [enabled_slots] and [slot_configs] to JSON file.

    @param path File path (default: [default_config_path])
    @return Ok () or Error with message
*)
val save_config : ?path:string -> unit -> (unit, string) result

(** {1 Validation} *)

(** Validate configuration before loading

    Checks that all [enabled_slots] exist in the registry.

    @param config Configuration to validate
    @return Ok () or Error with comma-separated error messages
*)
val validate_config : config:plugin_config -> (unit, string) result
