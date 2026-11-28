(** Keeper_same_turn_result_stub — a tool result whose text repeats an earlier
    result of the same turn leaves as a short pointer to that turn's first one
    (RFC-0510).

    This is a function of the message list alone. It reads no file, holds no
    state and stores nothing, so the same list gives the same output, and
    appending messages never changes the output for the messages before them:
    a result is decided from the messages in front of it only. A result is
    therefore a stub while the request still carries its target (RFC-0510 D5).

    The request assembly ([Keeper_turn_driver_try_provider]) calls it and
    owns three things this module does not: which tools are on ([enabled],
    from each tool file's [same_turn_result_stub] key), running it off the
    main domain (it hashes every eligible body with sha256), and where it
    sits: after the range start is chosen from the checkpoint history and
    before {!Keeper_model_input_demotion.plan}. *)

val encode : first_tool_use_id:string -> bytes:int -> sha256:string -> string
(** The stub text:
    [[masc:same-result first_tool_use_id="…" bytes=N sha256=…]]. It states
    which result of the turn holds the text, how many bytes that text is, and
    its sha256. It carries no instruction (RFC-0510 D3). It does not start
    with the blob marker prefix, so {!Tool_output.decode_from_agent_core}
    reads it as [Not_marker]. *)

val apply
  :  ?is_transmitted:(int -> bool)
  -> enabled:(string -> bool)
  -> min_bytes:int
  -> Agent_core.Types.message list
  -> Agent_core.Types.message list
(** Walk the messages once, front to back.

    A turn starts at each [User] message whose origin is [Conversation]; the
    messages before the first such message are one turn of their own. Within
    a turn, the first result with a given text stays as it is and every later
    result with byte-equal text has its [content] replaced by {!encode}
    pointing at that first result. [is_transmitted], when provided, selects
    candidate results by their zero-based message index. Only selected results
    can be stubs or serve as their targets. Turn boundaries and tool names
    still come from the original messages. A result never points into another turn.

    A result is left exactly as it is when any of these hold:

    - no earlier [ToolUse] block carries its [tool_use_id], so its tool is
      unknown, or [enabled] is false for that tool's name;
    - its [content] is shorter than [min_bytes];
    - its [content_blocks] is [Some], or its message carries an image,
      document or audio block;
    - the stub would not be shorter than its [content].

    A stubbed result keeps its [tool_use_id] and [outcome]; its [json] becomes
    [None], because the parsed payload is the text the stub replaces.

    Untouched messages are returned physically, and the input list itself is
    returned when no result changed. *)
