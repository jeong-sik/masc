(** Audit trail — append-only log of policy decisions and agent actions.

    Records every decision point evaluation, providing accountability
    and transparency for agent behavior in a society.

    @since 0.76.0

    @stability Evolving
    @since 0.93.1 *)

(** {1 Audit entries} *)

type entry =
  { id : string
  ; timestamp : float
  ; agent_name : string
  ; action : string
  ; decision_point : Policy.decision_point option
  ; verdict : Policy.verdict option
  ; detail : Yojson.Safe.t
  }

(** {1 Audit log} *)

type t

(** Create an audit log with optional max capacity.
    When capacity is exceeded, oldest entries are evicted. *)
val create : ?max_entries:int -> unit -> t

(** Record an entry. *)
val record : t -> entry -> unit

(** Record a structured [Policy.decision] as an audit entry.
    The decision's lineage is stored in the [detail] field as JSON.
    @since 0.99.2 *)
val record_decision
  :  t
  -> id:string
  -> agent_name:string
  -> action:string
  -> decision_point:Policy.decision_point
  -> Policy.decision
  -> unit

(** {1 Queries} *)

val query : t -> ?agent:string -> ?action:string -> ?since:float -> unit -> entry list
val count : t -> int
val latest : t -> int -> entry list

(** {1 Export} *)

val to_json : t -> Yojson.Safe.t
val entries_to_json : entry list -> Yojson.Safe.t
