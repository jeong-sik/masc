(** What a Keeper tool's answer is, read from its own output (RFC
    a-tool-declares-what-its-answer-is).

    The repeat guard treats an unchanged output as proof that a call made no
    progress. A receipt field that changes on every call -- a clock, a store
    revision, an execution time -- breaks that proof for calls whose result
    did not move, so the guard compares answers instead of whole outputs.

    Every {!Keeper_tool_descriptor.runtime_handler} names how its answer is
    read, by an exhaustive match: a new handler does not compile until it
    chooses. The answer depends only on the tool name and the output text, so
    the live hooks, the official-client host, the call ledger and a history
    replay all reach the same fingerprint for the same bytes. *)

type reader =
  | Whole_output  (** The whole output is the answer. *)
  | Reads_answer of (string -> Yojson.Safe.t option)
      (** Reads the answer out of the output text; [None] when the text is not
          in the shape the tool writes (a failure rewritten by the bridge),
          and the whole output stands. *)

val reader : Keeper_tool_descriptor.runtime_handler -> reader

(** How a tool name found its handler. A name no descriptor owns -- an
    external MCP tool -- has none. *)
type resolution =
  | Keeper_handler of Keeper_tool_descriptor.runtime_handler
  | Outside_keeper_descriptors

(** The descriptor {!Keeper_tool_descriptor_resolution.descriptor_for_tool_name}
    finds, so a transport-prefixed name ([mcp__masc__...]) resolves the way
    receipts and tool-call evidence resolve it. *)
val resolve : string -> resolution

(** The answer the tool reads from [output_text], or [None] when the whole
    output is the answer: the handler reads [Whole_output], the name resolves
    to no handler, or the text is not in the tool's shape. *)
val answer : tool_name:string -> output_text:string -> Yojson.Safe.t option

(** Recompute a declared stored answer from integrity-checked original bytes
    in the caller-owned blob store. Missing, corrupt, mismatched or unsupported
    evidence returns [None]; marker paths and declarations are never authority.
    A closed manifest with the declared manifest MIME is unwrapped only when
    its JSON content equals its structured data. Child blobs are never read. *)
val verified_stored_answer :
  base_path:string -> tool_name:string -> output_text:string -> Yojson.Safe.t option
