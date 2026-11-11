(** Backend_types — shared types for Backend modules.

    Single source of truth for error types, config, and shared utilities
    used by all [_eio] backend implementations. *)

(** {1 Error Types — no silent failures} *)

type error =
  | NotFound of string
  | AlreadyExists of string
  | IOError of string
  | InvalidKey of string
[@@deriving show]

(** Result alias pinned to [error]. *)
type 'a result = ('a, error) Stdlib.result

(** {1 Health} *)

type health_result = {
  latency_ms : float;
  is_healthy : bool;
}

(** {1 Config} *)

type config = {
  base_path : string;
  node_id : string;
}

(** Generate a node identifier of the form
    ["<hostname>-<pid>-<rand4hex>"], suitable for
    single-instance disambiguation in logs. *)
val node_id_suffix_bytes : int
(** Entropy bytes in the suffix of {!generate_node_id}. Exposed so a test
    states the width against this value instead of copying the number. *)

val generate_node_id : unit -> string

(** Default config rooted at [".masc"]. Node id is generated fresh on each
    call. *)
val default_config : unit -> config

(** {1 In-Memory Pub/Sub}

    Shared by the Memory and FileSystem backends. *)
module Pubsub_mem : sig
  type t

  val create : unit -> t

  (** [publish t ~channel ~message] invokes every subscriber callback on
      [channel] with [message]. Returns the number of subscribers notified
      ([Ok 0] when no subscribers). Subscriber exceptions are logged;
      [Eio.Cancel.Cancelled] is re-raised. *)
  val publish : t -> channel:string -> message:string -> int result

  (** Append [callback] to the subscriber list for [channel]. *)
  val subscribe :
    t -> channel:string -> callback:(string -> unit) -> unit result
end
