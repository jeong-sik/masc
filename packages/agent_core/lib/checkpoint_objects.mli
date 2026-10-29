(** A checkpoint held as one small head and content-addressed objects
    (RFC-0476 §3.2-3.5).

    Every message is written once as a {e message object}: the validated bytes
    {!Checkpoint.to_string} would write for it. A closed Keeper turn is written
    once as a {e bundle}: its messages' bytes in order behind a header that
    names each one's digest and length. The {e head} holds the checkpoint
    without its messages, the turns as [(bundle, message count, chain)] and
    the digests of the open turn's messages, so a save writes the messages it
    has not written before and the head, not the whole history.

    This module plans and decodes; it does no I/O. The store writes the
    planned objects before the head, so a head names only objects that are
    already durable. *)

(** {1 Digests and the hash chain} *)

(** The SHA-256 of an object's bytes, 64 lowercase hex characters. It names
    the object. *)
type digest = private string

val digest_of_hex : string -> (digest, string) result
val digest_of_bytes : string -> digest

(** [chain_start] is the SHA-256 of a fixed tag; [chain_step chain d] is the
    SHA-256 of [chain]'s hex followed by [d]'s hex, in hex. [chain k] over a
    history is [chain_start] stepped by its first [k] message digests, so two
    histories with the same [chain k] share their first [k] messages. *)
type chain = private string

val chain_start : chain
val chain_step : chain -> digest -> chain
val chain_of_hex : string -> (chain, string) result

(** {1 Head} *)

type turn =
  { bundle : digest
  ; messages : int  (** At least one. *)
  ; chain : chain  (** [chain k] where [k] counts every message up to this turn's last. *)
  }

type history =
  { turns : turn list  (** Oldest first. *)
  ; open_messages : digest list  (** The open turn's messages, in order. *)
  }

(** [checkpoint] has no messages; [history] says where they are. *)
type head =
  { checkpoint : Checkpoint_types.t
  ; history : history
  }

val message_count : history -> int

(** Every object [history] names: the turns' bundles in order, then the open
    messages. *)
val history_objects : history -> digest list

(** {1 Content digest}

    The SHA-256 of a fixed tag, the head's checkpoint field and the chain over
    every message. It names what a checkpoint holds whatever turns its
    messages are split into, so a value and every head written for it have the
    same content digest, and neither needs a message object read. *)

val head_content_digest : head -> digest

(** {1 Saving} *)

(** Whether the save ends a Keeper turn. [Turn_closes] writes the messages
    after the last kept turn as one bundle and leaves no open message. *)
type boundary =
  | Turn_continues
  | Turn_closes

(** The encoded messages of earlier saves and loads, by message identity
    ([==]), so a save encodes and hashes only messages it has not seen. One
    memo serves one sequence of saves of one checkpoint. *)
type memo

val create_memo : unit -> memo

(** What a save writes: [objects] first, in order, each named by its digest,
    then [head_bytes] in place of the head. [content] is the checkpoint's
    content digest. [decoded] is what a load of the written head and objects
    gives. *)
type plan =
  { objects : (digest * string) list
  ; head_bytes : string
  ; head : head
  ; content : digest
  ; decoded : Checkpoint_types.t
  }

(** [plan_save memo ?previous boundary checkpoint]. Turns of [previous] whose
    messages are still the first messages of [checkpoint] (their chain values
    match) are kept as they are; every message after them is open, or one new
    bundle when [boundary] is [Turn_closes]. An open message that [previous]
    already listed as open is not written again. [absent] names objects of
    [previous] that are not stored: a kept turn whose bundle is absent has its
    bundle written again from [checkpoint]'s messages, and an absent open
    message is written again. After a success, [memo] holds [checkpoint]'s
    messages. Fails when a message or the fields around them do not pass the
    checkpoint codec's checks. *)
val plan_save
  :  memo
  -> ?previous:history
  -> ?absent:digest list
  -> boundary
  -> Checkpoint_types.t
  -> (plan, Error.t) result

(** The content digest of a value, encoding only the messages [memo] does not
    hold. [memo] is left as it was. Fails as {!plan_save} does. *)
val content_digest : memo -> Checkpoint_types.t -> (digest, Error.t) result

(** {1 Loading} *)

type load_error =
  | Head_invalid of string
  | Checkpoint_invalid of Error.t
      (** The head's checkpoint field does not decode, or the document names
          another [checkpoint_version] ([Serialization (VersionMismatch _)]): a
          head in its checkpoint field, any other document at its top. The
          version is read before the head's shape. *)
  | Object_missing of digest
  | Object_unreadable of
      { digest : digest
      ; detail : string
      }
  | Object_digest_mismatch of
      { expected : digest
      ; actual : digest
      }
  | Bundle_invalid of
      { bundle : digest
      ; detail : string
      }
  | Turn_mismatch of
      { bundle : digest
      ; detail : string
      }
      (** The bundle's messages do not give the count or chain its turn names. *)
  | Message_invalid of
      { digest : digest
      ; detail : string
      }

val load_error_to_string : load_error -> string

val head_of_string : string -> (head, load_error) result

(** [read_object digest] returns the object's bytes, [None] when there is no
    such object, or why it could not be read. Every object is checked against
    its digest, every bundle against its turn's count and chain. [memo] then
    holds the loaded messages, so a save that follows writes none of them. *)
val load
  :  memo
  -> read_object:(digest -> (string option, string) result)
  -> head
  -> (Checkpoint_types.t, load_error) result
