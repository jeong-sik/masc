(** Foreground owner for a browser child whose inherited descriptors are not
    trusted to preserve a native Add-on lease. The owner keeps its own inherited
    lease descriptors while the child receives only its standard streams. *)
type ready = { instance_id : string; owner_pid : int; child_pid : int }
val ready_to_json : ready -> Yojson.Safe.t
val ready_of_json : Yojson.Safe.t -> (ready, string) result
(** Strict bootstrap receipt, not execution authority or browser readiness. The
    host must independently check the original native lease owner. *)

type error = Invalid_instance | Invalid_command | Invalid_grace
  | Not_group_leader | Group_unavailable of string
val error_to_string : error -> string
val run : env:Eio_unix.Stdenv.base -> instance_id:string -> command:string list ->
  grace_seconds:float -> on_ready:(ready -> unit) -> (unit, error) result
(** Must run in a dedicated process group, normally through the native launcher.
    Returns only on preflight refusal. Once child startup is attempted, every
    exit path kills the owner's own group, including itself, before its PID can
    be reused. SIGTERM/SIGINT or closure of the stdin keepalive pipe requests
    group TERM and grants the supplied resource-cleanup grace; normal child exit
    ends the group promptly. Any input byte also closes that keepalive contract.
    Child output goes to stderr; on_ready is the sole stdout producer.
    [on_ready] must use cooperative Eio I/O. It runs concurrently with shutdown
    observation and is cancelled on stop/child exit, so bootstrap backpressure
    cannot hold resource cleanup. A partial bootstrap reply proves no outcome.

    This is trusted native ownership, not a sandbox. Descendants that deliberately
    leave this group need separate ownership and cannot be counted as settled by
    this receipt. The caller owns profile/artifact cleanup and must confirm the
    original native claim's settlement before reusing those resources. *)
