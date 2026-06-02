(** Payload — multimodal artifact payload representation.

    Cycle 24 / Tier B8.

    Three variants:
    - {!Lazy_payload}: deferred string materialisation. The closure
      captures whatever computation the producer wants delayed (e.g.
      reading from disk, decoding, decompression). Round-tripping
      through {!of_json} loses the original closure — see below.
    - {!Blob_ref}: an opaque reference into an external blob store.
      The string is treated as an arbitrary identifier; this module
      does not interpret its structure.
    - {!Streaming}: byte-count-only handle for in-progress streams.
      The integer is the bytes-so-far counter at the moment of
      capture; consumers should treat it as a hint, not authoritative.

    Tier B9 (Multimodal_hydrator) will wrap these with the existing
    [keeper_artifact_hydrator] so its consumers see a uniform surface.

    @stability Evolving
    @since 0.18.10 *)

type t =
  | Lazy_payload of (unit -> string)
  | Blob_ref of string
  | Streaming of int

val to_json : t -> Yojson.Safe.t
(** JSON encoding:
    - [Lazy_payload _ → \{ "kind": "lazy" \}]. The closure is not
      serialised — only the discriminator survives.
    - [Blob_ref s → \{ "kind": "blob_ref", "ref": s \}].
    - [Streaming n → \{ "kind": "streaming", "bytes": n \}]. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Parse the {!to_json} shape.

    [Lazy_payload] reconstructs a closure that always returns the
    empty string ([fun () -> ""]) — the original closure cannot be
    serialised, so deserialisation is lossy by construction.
    Callers needing the original payload must keep the in-memory
    artifact value, not round-trip through JSON. *)
