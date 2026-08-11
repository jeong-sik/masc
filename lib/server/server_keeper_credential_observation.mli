(** Production boundary for observing one keeper's projected GitHub CLI
    credential surface. The decoder stays in [Gh_auth_status]; this module owns
    the bounded process call and the keeper secret projection. *)

val observe :
  ?timeout_sec:float ->
  base_path:string ->
  keeper_name:string ->
  hostname:string ->
  unit ->
  Gh_auth_status.t
(** Run [gh auth status --hostname HOST --json hosts] with the keeper's local
    projected environment. The process exit status is not used as the
    authentication verdict; the parser decides from the returned JSON. *)

val surface_json :
  hostname:string ->
  probed_at:float ->
  Gh_auth_status.t ->
  Yojson.Safe.t
(** Render the redacted dashboard projection. Credential values never appear. *)

module For_testing : sig
  val observe_with_runner :
    run:(string array -> (string, string) result) ->
    hostname:string ->
    Gh_auth_status.t
  (** Exercise the same parser boundary as [observe] without spawning [gh]. *)
end
