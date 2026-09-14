(** What a tool handler can say about its own call beside the result: that the
    call moved the world it acts on. The keeper's repeat guards drop the output
    fingerprint to catch a clock -- identical input, a different result every
    time, nothing advancing -- and a tool that advances an emulator by a fixed
    number of frames has the same shape while being the opposite thing. The
    declaration is the handler's typed word for that difference; it rides the
    result's metadata ([Tool_result.make_ok ~metadata]) under {!key}, the
    bridge carries it to the keeper as the agent-core output's [_meta], and the
    keeper maps it onto its own outcome type. A tool that says nothing is read
    as having said nothing, never as the opposite. *)

type t = Progress  (** The call advanced the world it acts on. *)

val key : string
(** ["masc.tool_outcome"]. *)

val to_metadata : t -> Yojson.Safe.t
(** The metadata object carrying the declaration under {!key}, for a handler
    with no other metadata to merge. *)

val of_metadata : Yojson.Safe.t option -> t option
(** The declaration in a result's metadata: [None] for absent metadata, an
    absent key, or a value this module did not write. *)
