(** A checkpoint held as one small head and content-addressed objects
    (RFC-0476 §3.2-3.5).

    Every message is written once as a {e message object}: the validated bytes
    {!Checkpoint.to_string} would write for it. A closed Keeper turn is written
    once as a {e bundle}: its messages' bytes in order behind a header that
    names each one's digest and length. The header's system prompt and tools
    are {e header objects}. Closed turns past a few dozen go into {e turn
    segments}, each naming the one before it. The {e head} holds the rest of
    the header, the header objects' digests, the last segment, the turns after
    it as [(bundle, message count, chain)] and the digests of the open turn's
    messages, so a save writes what it has not written before and a head
    whose size does not follow the header's or the history's.

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

(** The last turn segment: its digest, the messages the segments up to it
    hold, and [chain] over them. *)
type segment_ref =
  { segment : digest
  ; segment_messages : int
  ; segment_chain : chain
  }

type history =
  { segment : segment_ref option
  ; turns : turn list  (** After the segments, oldest first; fewer than {!turns_per_segment}. *)
  ; open_messages : digest list  (** The open turn's messages, in order. *)
  }

(** A turn segment object: {!turns_per_segment} closed turns, oldest first,
    and the segment before them. *)
type segment =
  { previous : digest option
  ; segment_turns : turn list
  }

(** What a reader needs from the header without an object read. *)
type header =
  { session_id : string
  ; turn_count : int
  ; created_at : float
  }

(** The objects that hold the header's system prompt and tools, each the
    compact JSON of that field's value. *)
type header_objects =
  { system_prompt : digest
  ; tools : digest
  }

(** [header_json] is the rest of the header as the head writes it, with an
    empty message list; [history] says where the messages are. *)
type head = private
  { header : header
  ; header_json : Yojson.Safe.t
  ; header_objects : header_objects
  ; history : history
  }

val turns_per_segment : int
val message_count : history -> int

(** The objects [head] names itself: the header objects, the last segment,
    the turns' bundles, then the open messages. A segment names the rest
    ({!segment_objects}). *)
val head_objects : head -> digest list

(** The segment before it and its turns' bundles. *)
val segment_objects : segment -> digest list

(** {1 Content digest}

    The SHA-256 of a fixed tag, the head's checkpoint and header object
    fields as written and the chain over every message. It names what a
    checkpoint holds whatever turns its messages are split into, so a value
    and every head written for it have the same content digest, and neither
    needs an object read. *)

val head_content_digest : head -> digest

(** {1 Saving} *)

(** Whether the save ends a Keeper turn. [Turn_closes] writes the messages
    after the last kept turn as one bundle and leaves no open message. *)
type boundary =
  | Turn_continues
  | Turn_closes

(** The encoded messages of earlier saves and loads, by message identity
    ([==]), so a save encodes only messages it has not seen; and the chain
    values over the messages of the last save or load, so a save whose
    messages begin with those values hashes only what follows them. One memo
    serves one sequence of saves of one checkpoint. *)
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

(** [plan_save memo ?previous boundary checkpoint]. The segments and turns of
    [previous] whose messages are still the first messages of [checkpoint]
    (their chain values match) are kept as they are; the segments are kept
    whole or not at all, and turns after segments that are not kept are not
    kept either. Every message after the kept turns is open, or one new
    bundle when [boundary] is [Turn_closes]; then closed turns past
    {!turns_per_segment} - 1 become a new segment. An open message or header
    object that [previous] already names is not written again. [absent] names
    objects of [previous] that are not stored: an absent last segment is not
    kept, a kept turn whose bundle is absent has its bundle written again from
    [checkpoint]'s messages, and an absent open message or header object is
    written again. After a success, [memo] holds [checkpoint]'s messages.
    Fails when a message or the fields around them do not pass the checkpoint
    codec's checks. *)
val plan_save
  :  memo
  -> ?previous:head
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
  | Segment_invalid of
      { segment : digest
      ; detail : string
      }
      (** The segment does not parse, or its turns do not give the message
          count and chain the head names for it. *)
  | Header_object_invalid of
      { digest : digest
      ; detail : string
      }

val load_error_to_string : load_error -> string

val head_of_string : string -> (head, load_error) result

(** A segment object's bytes, read under [digest]. *)
val segment_of_string : digest:digest -> string -> (segment, load_error) result

(** [read_object digest] returns the object's bytes, [None] when there is no
    such object, or why it could not be read. Every object is checked against
    its digest, every bundle against its turn's count and chain, the segments
    against the count and chain the head names. [memo] then holds the loaded
    messages, so a save that follows writes none of them. *)
val load
  :  memo
  -> read_object:(digest -> (string option, string) result)
  -> head
  -> (Checkpoint_types.t, load_error) result

(** The header's system prompt, read from its header object alone. *)
val system_prompt
  :  read_object:(digest -> (string option, string) result)
  -> head
  -> (string option, load_error) result

(** The first [Some] that [find] gives for [head]'s messages, last message
    first. Objects are read only as far back as needed: the open messages,
    then each turn's bundle from the last, then each segment and its turns.
    Every object read is checked against its digest and every bundle against
    its turn's message count; the chains are not, since they run from the
    first message. So this is for showing a checkpoint, not for using it:
    {!load} is. *)
val find_last
  :  read_object:(digest -> (string option, string) result)
  -> head
  -> (Types.message -> 'a option)
  -> ('a option, load_error) result
