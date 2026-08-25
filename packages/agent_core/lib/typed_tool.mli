(** Type-safe constructors for canonical {!Tool.t} values.

    Each constructor connects the JSON parser, typed handler, and output
    encoder at compile time. No second runtime tool representation or erasure
    bridge is created.

    @stability Evolving
    @since 0.120.0 *)

(** Create a canonical tool with a typed parser and handler.

    Parse errors are recoverable tool failures. Handler errors are
    non-recoverable domain failures. *)
val create
  :  name:string
  -> description:string
  -> params:Types.tool_param list
  -> parse:(Yojson.Safe.t -> ('input, string) result)
  -> handler:('input -> ('output, string) result)
  -> encode:('output -> Yojson.Safe.t)
  -> ?descriptor:Tool.descriptor
  -> ?strict:bool
  -> unit
  -> Tool.t

(** Create a canonical context-aware tool with the same typed parse/encode
    contract as {!create}. *)
val create_with_context
  :  name:string
  -> description:string
  -> params:Types.tool_param list
  -> parse:(Yojson.Safe.t -> ('input, string) result)
  -> handler:(Context.t -> 'input -> ('output, string) result)
  -> encode:('output -> Yojson.Safe.t)
  -> ?descriptor:Tool.descriptor
  -> ?strict:bool
  -> unit
  -> Tool.t
