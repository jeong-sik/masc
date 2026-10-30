(** An explicit tool requirement for one named-runtime invocation. Optional
    preserves ordinary tool-free calls; Required refuses an unavailable offered
    tool surface before dispatch and lets the driver try another declared
    candidate. It does not infer tool support from runtime/provider names. *)
type t = Optional | Required
type reason = Model_tools_disabled | Binding_tools_unsupported | No_tools_supplied
  | Native_tools_cannot_be_disabled
[@@deriving yojson]
type failure = { runtime_id : string; reason : reason } [@@deriving yojson]
val check_surface
  : t -> runtime_id:string -> surface_enabled:bool -> has_tools:bool
  -> (unit, failure) result
(** [surface_enabled] is the execution owner's actual tool-delivery policy,
    not a claim about provider capabilities. Provider bindings are checked
    separately after materialization. *)
val check_provider
  : t -> runtime_id:string -> Llm_provider.Provider_config.t
  -> (unit, failure) result
(** Read the actual materialized provider binding, after any transform. *)
val to_core_error : failure -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> failure option
(** Uses the existing process-local typed carrier. Persist [failure_to_yojson]
    explicitly when retaining machine-readable capability evidence; a rendered
    error message cannot reconstitute this carrier. *)
val should_try_next : Agent_core.Error.t -> bool
