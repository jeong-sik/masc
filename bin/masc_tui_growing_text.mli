(** One streamed stretch of a reply's text, which only grows at its end.

    The screen draws a stretch through
    {!Masc_tui_keeper_chat_projection.terminal_safe_text} with newlines kept.
    That conversion splits at a newline: when [a] ends with ['\n'],
    [safe (a ^ b) = safe a ^ safe b]. So each finished line is converted, and
    its MD5 fed, once when it arrives; a snapshot converts only the line that
    has not ended yet. *)

type t

val create : stretch:int -> t
(** An empty stretch; [stretch] names it among the reply's stretches. *)

val append : t -> string -> unit
(** The next bytes of the stretch as they arrived. A delta may end inside a
    UTF-8 sequence; its bytes wait in the open line until that line ends. *)

type snapshot = private {
  text : string;
      (** [terminal_safe_text ~preserve_newlines:true] of every byte appended. *)
  closed : int;
      (** The first [closed] bytes of [text] are the same in every later
          snapshot of this stretch. *)
  identity : Digest.t;  (** [Digest.string text]. *)
  stretch : int;
}

val snapshot : t -> snapshot

module For_testing : sig
  val bytes_converted : unit -> int
  (** Bytes handed to the safe-text conversion so far, finished lines and
      open lines alike. *)
end
