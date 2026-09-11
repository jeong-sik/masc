(** Desired HTTP endpoint per workspace, never server or model readiness. *)
type port = private int
type error = Invalid_port | Invalid_configuration | Configuration_unavailable | Write_failed
val error_message : error -> string
val port : int -> (port, error) result
val to_int : port -> int
val is_ephemeral : port -> bool
(** True if the port falls in the IANA dynamic/ephemeral range [49152..65535].
    Ephemeral ports assigned by the OS or chosen during fallback takeovers
    must not overwrite a workspace's durable connection contract (#35270). *)
val read : base_path:string -> (port option, error) result
val resolve : base_path:string option -> cli:int option -> environment:string option -> (port, error) result
(** Explicit CLI, then nonempty existing environment, then workspace, then default. *)
val save : base_path:string -> port:port -> (unit, error) result
(** Preserves unrelated TOML fields, validates before replacing and uses the
    shared durable writer lock. A failed save is not a server failure. *)
