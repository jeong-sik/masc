(** Cancellation — client-side cancellation token store.

    MCP 2025-11-25 Spec: client request cancellation for long-running operations.
    Token state uses [Atomic.t] for fiber-safe cross-fiber visibility in OCaml 5.

    @since 0.1.0 *)

(** {1 Types} *)

type token = {
  id : string;
  cancelled : bool Atomic.t;
  mutable reason : string option;
  mutable callbacks : (unit -> unit) list;
  created_at : float;
}

(** {1 Token Store} *)

module TokenStore : sig
  val init : unit -> unit
  val create : unit -> token
  val get : string -> token option
  val remove : string -> unit
  val list_all : unit -> token list
  val cleanup : max_age:float -> int
  val create_with_id : string -> unit
  val is_cancelled : string -> bool
  val cancel : string -> unit
end

(** {1 Token Operations} *)

val is_cancelled : token -> bool
val cancel : ?reason:string option -> token -> unit
val on_cancel : token -> (unit -> unit) -> unit
val cancel_by_id : ?reason:string option -> string -> bool
val create_for_task : task_id:string -> token
val token_to_json : token -> Yojson.Safe.t

(** {1 MCP Tool Handler} *)

val handle_cancellation_tool : Yojson.Safe.t -> (bool * string)
