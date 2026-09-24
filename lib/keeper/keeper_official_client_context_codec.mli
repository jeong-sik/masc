(** Lossless framing for canonical Keeper messages carried over official-client
    text-only history surfaces. *)

val schema : string

val message_to_json : Agent_core.Types.message -> Yojson.Safe.t
(** Preserve role, every typed content block, message identity, metadata,
    structured ToolResult content, and typed failure provenance. The one
    exception is the {!Agent_core.Types.Input_speaker} entry: it is host
    attribution for the Librarian, never text an official client reads. *)

val to_json : Agent_core.Types.message -> Yojson.Safe.t
(** Wrap one exact message in the current context schema. *)

val encode : Agent_core.Types.message -> string
(** Encode every role through the same versioned envelope. Raw user bytes never
    occupy the framing layer. *)
