(** Whether a Keeper's sandbox profile can start a process that outlives the
    call. The capability surface and the spawn handler decide with this one
    function, so a Keeper is never offered a [keeper_spawn] its lane refuses on
    every call. *)

type t =
  | Starts_in_container
      (** A Docker guest: the command becomes a container argv the host can
          background. *)
  | Refuses_start of { detail : string }
      (** The Keeper's tree lives on an endpoint reached through the framed
          exec shim, one command per connection, so there is no argv to
          background. [detail] is the refusal the handler returns. *)

val of_sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile -> t
