(** Keeper_context_window — the Keeper's transmission window, declared in
    tokens, and the byte capacity one request cuts its history to.

    RFC keeper-context-window-in-tokens. The window says how much of a turn's
    request the keeper sends per provider request: fixed prompt (system
    prompt, tool schemas, pinned context) and recent verbatim history
    together. It is a target the cut aims at, not a limit anything refuses
    on. The request-body cap judges whether the provider accepts the bytes,
    and the provider judges its own context; neither shapes this window.

    The cut measures bytes, because MASC encodes messages and cannot count a
    chat-completions provider's tokens before sending. The bridge is a
    density: the tokens the provider reported for a request, over the bytes
    MASC measured for that same request with the cut's own encoder. Nothing
    here guesses a bytes-per-token figure. A runtime with no observation yet
    is [Unmeasured], and the caller sends the smallest request that still
    carries the turn until the first response reports usage. *)

type source =
  | Declared
      (** The window the operator declared ([turn.context_window_tokens]). *)
  | Shrunk_after_overflow of { declared_tokens : int }
      (** A provider reported a context overflow at a larger window and the
          same-runtime retry halved it, or a remembered smaller window was
          reused. [declared_tokens] is what the operator declared, so the
          shrink stays visible next to the window it replaced. *)

type t =
  { window_tokens : int
  ; source : source
  }

val declared : window_tokens:int -> t

val with_tokens : t -> window_tokens:int -> t
(** The same declaration at another size. The declared size restores
    [Declared]; any other size is [Shrunk_after_overflow] of the declared
    one. *)

val declared_tokens : t -> int

val source_to_string : source -> string
val to_json : t -> Yojson.Safe.t

type density = private
  { input_tokens : int
        (** The provider's inclusive prompt total for one request. *)
  ; measured_bytes : int
        (** The bytes MASC measured for that same request: the reservation
            (tool schemas, system prompt) plus the transmitted history, with
            the encoder the cut uses. *)
  }
(** Readable everywhere, made only by {!density_of}, so every density the
    arithmetic below divides by has two positive sides. *)

val density_of : input_tokens:int -> measured_bytes:int -> density option
(** [None] unless both sides are positive. A report of zero prompt tokens,
    or a request that measured nothing, is not an observation: a density
    made from it would divide by zero or read every window as empty. *)

type capacity =
  | Measured of
      { window_tokens : int
      ; density : density
      ; capacity_bytes : int
      }
  | Unmeasured of { window_tokens : int }

val capacity : t -> density option -> capacity
(** [capacity_bytes = window_tokens * measured_bytes / input_tokens]. *)

val tokens_of_bytes : density -> int -> int
(** Bytes measured with the cut's encoder, read as tokens through this
    density. *)

val bytes_of_tokens : density -> int -> int
(** Tokens read as bytes of the cut's encoder through this density: the
    inverse of {!tokens_of_bytes}, up to integer rounding. *)

val share_bytes
  :  window_tokens:int
  -> share_percent:int
  -> density option
  -> int option
(** [share_percent] of a [window_tokens] window, as bytes through the
    runtime's observed density: the ceiling a pinned block the cut cannot
    remove, such as the world-state briefing, may occupy. [None] while the
    runtime's density is unobserved, because no byte figure stands for the
    window yet. *)

val capacity_to_json : capacity -> Yojson.Safe.t

(** Process-local density observations, keyed by runtime id. The tokenizer
    is the runtime's, so every keeper on a runtime shares what any of them
    observed. Not durable: a restart starts every runtime [Unmeasured] again,
    and the first response re-observes it. *)
module Density : sig
  val observe : runtime_id:string -> measured_bytes:int -> input_tokens:int -> unit
  (** Records the newest observation for [runtime_id]. A non-positive value
      on either side is not an observation and is ignored. *)

  val lookup : runtime_id:string -> density option

  module For_testing : sig
    val reset : unit -> unit
  end
end
