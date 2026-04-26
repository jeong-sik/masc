(** Per-endpoint admission throttle table.

    Shared throttle table mapping endpoint URLs to {!Llm_provider.Provider_throttle.t}.
    Populated lazily from {!Discovery} slot data.

    @since 0.91.0
    @since 0.92.0 extracted from Cascade_config

    @stability Internal
    @since 0.93.1 *)

(** Update the throttle table from discovery probe results.
    Creates entries for healthy endpoints with slot data.
    Evicts entries for unhealthy endpoints. *)
val populate : Llm_provider.Discovery.endpoint_status list -> unit

(** Lookup the throttle for a given endpoint URL. *)
val lookup : string -> Llm_provider.Provider_throttle.t option

(** Clear all throttle entries (for testing). *)
val clear : unit -> unit

(** Number of throttle entries (for testing). *)
val length : unit -> int

(** {2 Capacity Query} *)

(** Point-in-time capacity for a single endpoint.
    All [process_*] counts reflect this OAS process only —
    other clients sharing the same server are not visible.
    @since 0.97.0 *)
type capacity_info =
  { total : int (** Server slot count from discovery. *)
  ; process_active : int (** Slots held by this process. *)
  ; process_available : int
    (** [total - process_active]. May overestimate if other consumers exist. *)
  ; process_queue_length : int (** Fibers waiting for a slot in this process. *)
  ; source : Llm_provider.Provider_throttle.capacity_source
    (** How the slot count was determined. *)
  }

(** Capacity for a given endpoint URL. Returns [None] if not in throttle table.
    @since 0.97.0 *)
val capacity : string -> capacity_info option
