(** Explicit upgrade preparation for an existing owner, including older servers
    without the model-setup resume endpoint. No process starts or forced kills. *)
type t
type error = Invalid_health | Different_workspace | Admin_required | Owner_unavailable
  | Incumbent_changed | Already_requested | Closed | Port_unavailable
type incumbent = { base_path : string; version : string }
val prepare :
  sw:Eio.Switch.t -> clock:[> float Eio.Time.clock_ty] Eio.Resource.t -> headers:(string * string) list ->
  run_dir:string -> base_path:string -> port:int -> (t, error) result
val incumbent : t -> incumbent
val request_termination : t -> (unit, error) result
(** Call only after the user selects replacement. Rechecks workspace/version and
    admin authentication immediately before identity-bound SIGTERM. Success is
    a request, not proof of drain. Caller waits for lease/port release and starts
    the replacement with the same workspace and existing authentication. *)
val close : t -> unit
val suggest_loopback_port : unit -> (int, error) result
(** OS-selected candidate, not a reserved port. Recheck conflicts at startup. *)
module For_testing : sig
  val prepare : sw:Eio.Switch.t -> base_path:string -> observe:(unit -> (string, error) result) ->
    authorize:(unit -> bool) ->
    capture:(unit -> (((unit -> (unit, error) result) * (unit -> unit)), error) result) ->
    (t, error) result
end
