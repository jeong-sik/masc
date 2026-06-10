(** Failure classification for {!Keeper_sandbox_factory}.

    Separates sandbox factory failure modes into typed classes so callers
    can handle each path independently instead of catching undifferentiated
    exceptions from {!Keeper_sandbox_factory.resolve}, {!container_cwd_of_host},
    and {!cleanup}. *)

type t =
  | Registry_lookup of string
    (** Keeper not found in registry; contains the keeper name. *)
  | Sandbox_profile_resolution of string
    (** Could not determine effective sandbox profile; contains detail. *)
  | Runtime_image_missing of string
    (** No sandbox image configured and no default available. *)
  | Runtime_creation of string
    (** {!Keeper_turn_sandbox_runtime.create} failed; contains stderr. *)
  | Cwd_normalization of string
    (** Path normalisation or host-root resolution failed. *)
  | Cwd_projection of string
    (** {!Keeper_cwd_response.profile_independent_cwd} failed. *)
  | Cache_cleanup of string
    (** Runtime teardown during {!cleanup} raised an error. *)
  | Internal of string
    (** Unexpected internal invariant violation. *)

val to_string : t -> string
(** Human-readable failure class label. *)

val classify_error : exn -> t
(** Translate a caught [exn] from factory operations to the most
    specific {!t} variant by inspecting the exception message and
    context-preserving metadata. *)