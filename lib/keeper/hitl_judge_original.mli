(** The immutable original of one HITL Auto Judge request.

    An approval's judgment is requested from its prompt, its output contract and
    the context bundle the host observed. This module names that input as data:
    identifiers and the three pieces that make the request, nothing that
    authorises an effect and nothing that restores a closure or an AgentCore
    receipt. The decision stays with the host, so a worker given this value can
    only answer it.

    {!messages} is the one place the three messages of the judgment request are
    spelled; the worker's own request builder reads it, so a prepared original and
    the request the worker sends cannot drift apart. *)

type t

val schema : string
(** The wire schema name carried by {!to_json}. *)

val system_prompt : unit -> (string, string) result
(** The judgment system prompt as the template renders it now. *)

val canonical_output_contract : unit -> string
(** The output-contract sentence with the canonical schema. A template that does
    not render is logged and falls back to the bare schema JSON. *)

val messages_of
  :  system_prompt:string
  -> output_contract:string
  -> context_bundle:Yojson.Safe.t
  -> Llm_provider.Types.message list
(** The system message, the output contract and the context bundle, in that
    order. The original and worker preparation supply a canonical context
    bundle so persistence cannot reorder its serialized message bytes. *)

val prepare
  :  entry:Keeper_approval_queue_rules_types.pending_approval
  -> (t, string) result
(** Capture the original of [entry]'s judgment request. The context bundle is
    acquired first and the prompt after, as the worker does. This does not
    mutate the approval, bind a lane or call a model. Context objects and
    numbers use the original-request store canonical form; invalid JSON is an
    error, and array order and text bytes remain significant. *)

val approval_id : t -> string
val input_hash : t -> string
val sequence : t -> int
val system_prompt_text : t -> string
val output_contract : t -> string
val context_bundle : t -> Yojson.Safe.t

val messages : t -> Llm_provider.Types.message list
(** {!messages_of} over the captured pieces. *)

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
(** Strict inverse of {!to_json}: the schema name, the exact field set and the
    field types must match. Unknown or missing fields are errors. The context
    bundle is canonicalized with the same rules as {!prepare}; duplicate keys
    and non-finite numbers are errors. *)

val digest : t -> (string, string) result
(** SHA-256 of the canonical JSON of {!to_json}. Equal originals have equal
    digests whatever the key order they were read in. *)
