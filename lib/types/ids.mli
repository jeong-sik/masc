(** MASC MCP Types — newtype IDs that prevent accidental string mixups.

    Each module wraps [string] in an abstract type so the type system
    rejects passing an [Agent_id.t] where a [Task_id.t] is expected
    (and vice versa). All modules expose [of_string]/[to_string] and
    [Yojson] round-trips so JSON boundaries can lift/lower without
    leaking the underlying representation. *)

(** Agent identifier — random UUIDv4. *)
module Agent_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Task identifier — timestamp-prefixed sequence. *)
module Task_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Tool execution identifier — RFC-0233. Minted exactly once at the
    dispatch boundary for each tool execution and stamped into every
    store that records that execution (tool_calls JSONL, trajectory;
    oas-event join lands in RFC-0233 PR-2), so one physical execution
    renders as one logical row regardless of how many stores observed
    it. Timestamp-prefixed ([exec-<ms>-<seq>]) — lexicographic order
    within a process tracks mint order. *)
module Execution_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Turn reference — RFC-0233 §7. Canonical per-turn join key derived from
    [(trace_id, absolute_turn)]; serializes as ["<trace_id>#<absolute_turn>"].
    The identity keeper chat rows and board posts join on. [of_string]
    returns [None] on malformed input rather than repairing it. Distinct
    from {!Turn_id}. *)
module Turn_ref : sig
  type t
  val make : trace_id:string -> absolute_turn:int -> t
  val to_string : t -> string
  val of_string : string -> t option
  val trace_id : t -> string
  val absolute_turn : t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Conversation thread identifier — timestamp-prefixed sequence. *)
module Thread_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Turn identifier — individual turn within a thread. *)
module Turn_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : thread_id:string -> seq:int -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end

(** Keeper identifier — deterministic UUIDv5 derived from
    [keeper:<name>:<path>]. Nested {!Keeper_id.Trace_id} and
    {!Keeper_id.Task_id} modules carry validated string newtypes used
    on tracing/auth boundaries. *)
module Keeper_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : name:string -> path:string -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
  module Trace_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
  module Task_id : sig
    type t
    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end
end

(** Credential identifier — random UUIDv4. *)
module Credential_id : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val generate : unit -> t
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
