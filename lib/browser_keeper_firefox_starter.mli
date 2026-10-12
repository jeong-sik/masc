(** How a Keeper's request for work only a BiDi connection serves reaches the
    server's start of the Keeper Firefox and its BiDi host
    (RFC-browser-keeper-firefox §3.5). The server installs it while it runs;
    the request is answered from what it says. *)

(** What was started for the connection now listed. *)
type started =
  | Firefox_and_host
  | Host_only  (** Firefox's port already answered. *)
  | Nothing
      (** A host was running already, or the connection was listed before
          a start was needed. *)

(** Why no BiDi connection is listed, by what a retry of the same request
    does. *)
type not_attached =
  | Operator_needed of string
      (** Nothing is started until the operator acts, as this says: the
          browser lane is not installed, another host or an earlier Keeper
          Firefox holds the workspace. A retry gets the same answer. *)
  | Start_failed of string
      (** A start was tried and did not bring the host up, as this says. A
          retry tries again. *)
  | Not_listed_in_time of string
      (** The host was started or was running, and its connection was not
          listed within the wait. A retry may find it listed. *)

type outcome =
  | Attached of { client : Browser_lane.client_info; started : started }
  | Not_attached of not_attached
  | Not_asked_for
      (** The workspace's [runtime.toml] has no [\[browser.live.bidi\]], or
          its live lane is off, or no server here starts one. *)

(** [None] withdraws it, as the server does when it stops. *)
val install : (unit -> outcome) option -> unit

(** Asks the installed start and waits for its answer: until a BiDi
    connection is listed, or the start says why none is. *)
val bring_up : unit -> outcome
