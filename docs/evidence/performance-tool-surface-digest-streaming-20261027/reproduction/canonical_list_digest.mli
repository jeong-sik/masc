(** Private, unexecuted prototype. No MASC product interface is changed.

    This preserves the bytes of [Yojson.Safe.to_string (Yojson.Safe.sort
    (`List (List.map to_json rows)))] for finite inputs and the same writer
    defaults. List order, duplicate object-key stability and all JSON fields
    remain meaningful. [to_json] must be the pure schema/source projection.

    The prototype serializes each row before projecting the next row. The old
    function projects the entire list before sorting/serialization. Arbitrary
    effectful callbacks and resource-failure precedence are not equivalent. *)

val iter_canonical_chunks
  :  to_json:('a -> Yojson.Safe.t)
  -> 'a list
  -> string Digestif.iter
(** Emit the exact list punctuation and canonical per-row strings. One local
    buffer is reused only within this invocation. It does not retain the full
    serialized list. The consumer must not publish a partial prefix as a
    complete digest; exceptions propagate without retry. *)

val digest
  :  to_json:('a -> Yojson.Safe.t)
  -> 'a list
  -> Digestif.SHA256.t
(** A digest is returned only after the complete iterator succeeds. The
    partially fed context remains private when projection/serialization fails.
    No cache, global buffer, threshold, validation skip or writer flag exists. *)
