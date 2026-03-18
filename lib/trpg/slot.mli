(** TRPG Slot Architecture

    Slot-based state management for TRPG engine. Each slot encapsulates
    a specific domain (rules, world, narrative, metrics) with uniform
    state transition interface.

    @since 2.68.0
*)

(** {1 Slot Type Classification}

    Each slot has a unique type identifier and category.
*)
type slot_category =
  | Rule    (** Game rules and mechanics (dice, combat, skill checks) *)
  | World   (** World state (actors, locations, items, flags) *)
  | Narrative (** Narrative flow (scenes, quests, story state) *)
  | Metrics  (** Metrics and analytics (session stats, performance) *)

type slot_info = {
  slot_id : string;           (** Unique identifier, e.g., "dnd5e_lite" *)
  category : slot_category;   (** Domain category for routing *)
  version : string;           (** Slot implementation version *)
  description : string;       (** Human-readable description *)
}

val string_of_slot_category : slot_category -> string
val slot_category_of_string : string -> (slot_category, string) result

val slot_info_to_yojson : slot_info -> Yojson.Safe.t
val slot_info_of_yojson : Yojson.Safe.t -> (slot_info, string) result

(** {1 Core Slot Signature}

    The base interface that all slots must implement. Provides:
    - Identity via [slot_info]
    - Synchronous state initialization
    - Event application for state transitions
    - Derived state computation (read-only projections)
*)
module type TRPG_SLOT = sig
  (** Slot metadata *)
  val slot_info : slot_info

  (** Initialize slot state from configuration.

      @param config Slot-specific configuration JSON
      @return Initial state as JSON
  *)
  val init_state : config:Yojson.Safe.t -> Yojson.Safe.t

  (** Apply an event to produce new state.

      Pure function: [state] is not modified.

      @param state Current state
      @param event Engine event to apply
      @return New state after event application
  *)
  val apply_event :
    state:Yojson.Safe.t ->
    event:Engine_event.t ->
    Yojson.Safe.t

  (** Compute derived state from current state.

      Read-only projection that may:
      - Filter sensitive data
      - Compute aggregates
      - Transform for client consumption

      @param state Current state
      @return Derived view of state
  *)
  val derive_state : state:Yojson.Safe.t -> Yojson.Safe.t
end

(** {1 Extended Slot Signature with Async Support}

    For slots requiring async initialization (e.g., database reads,
    external API calls). Provides Eio-compatible async init.
*)
module type TRPG_SLOT_ASYNC = sig
  include TRPG_SLOT

  (** Async state initialization with Eio switch.

      Spawns a fiber for initialization. The result is stored
      in a ref cell or delivered via callback pattern.

      @param config Slot-specific configuration
      @param sw Eio switch for resource management
      @param on_result Callback receiving the initialized state
  *)
  val init_state_async :
    config:Yojson.Safe.t ->
    sw:Eio.Switch.t ->
    on_result:(Yojson.Safe.t -> unit) ->
    unit
end

(** {1 Slot Registry}

    Dynamic slot loading and lifecycle management.
    First-class modules allow runtime slot registration.
*)
module Registry : sig
  (** Register a slot implementation.

       Duplicate slot_id replaces existing slot.
  *)
  val register : (module TRPG_SLOT) -> unit

  (** Register an async slot implementation. *)
  val register_async : (module TRPG_SLOT_ASYNC) -> unit

  (** Lookup slot by slot_id.

       @return Some module if found, None otherwise
  *)
  val find : slot_id:string -> (module TRPG_SLOT) option

  (** List all registered slot info. *)
  val list_all : unit -> slot_info list

  (** List slots by category. *)
  val list_by_category : slot_category -> slot_info list

  (** Clear all registered slots (mainly for testing). *)
  val clear : unit -> unit
end

(** {1 Legacy Compatibility}

    [S] signature for backwards compatibility with existing
    rule implementations like [Rule_dnd5e_lite].
*)
module type S = sig
  val id : string
  val init_state : config:Yojson.Safe.t -> Yojson.Safe.t
  val apply_event : state:Yojson.Safe.t -> event:Engine_event.t -> Yojson.Safe.t
  val derive_state : state:Yojson.Safe.t -> Yojson.Safe.t
end

(** Convert legacy [S] module to [TRPG_SLOT].

    Usage:
    {[ module My_rule = struct
         let id = "my_rule"
         let init_state ~config = ...
         let apply_event ~state ~event = ...
         let derive_state ~state = ...
       end

       module My_slot = Lift_legacy (My_rule) ]}
*)
module Lift_legacy (Legacy : S) : TRPG_SLOT
[@@warning "-67"]
