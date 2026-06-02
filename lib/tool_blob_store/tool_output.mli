(** Typed wrapper for tool outputs that may be inline or externally stored.

    Used by [tool_bridge] to externalize large outputs and by the keeper
    artifact hydrator to lazily resolve refs at LLM-call time.

    OAS [Agent_sdk.Types.ToolResult.content] is a fixed [string] field; we
    embed [Stored] refs as a sentinel-prefixed marker inside that string so
    the OAS type surface stays untouched. *)

type t =
  | Inline of string
  | Stored of {
      sha256 : string;  (** lowercase hex, 64 chars *)
      bytes : int;
      preview : string;
      mime : string;
    }

val sentinel_prefix : string
(** ["[masc:blob "] — the 11-byte discriminator at offset 0 of an encoded
    [Stored] value. Distinct from the existing [tool:] mask prefix used by
    [Context_compact_oas]; real tool outputs do not start with this prefix. *)

val is_sentinel : string -> bool
(** True iff [s] starts with [sentinel_prefix]. *)

val encode_for_oas : t -> string
(** Encode for embedding in OAS [Agent_sdk.Types.ToolResult.content].

    [Inline s] -> [s].
    [Stored {...}] -> sentinel marker, e.g.
      [["[masc:blob sha256=ab12... bytes=128934 mime=text/plain preview=\"...\"]"]].

    Round-trip property: [decode_from_oas (encode_for_oas x) = x]. *)

val decode_from_oas : string -> t
(** Decode a string from OAS [ToolResult.content].

    Returns [Inline s] for any string not starting with [sentinel_prefix]
    (backward compatibility with old checkpoints) or for malformed sentinels
    (fail-safe — never raises). *)
