(** Reading a field off a JSON value that may not be an object.

    [Yojson.Safe.Util.member] raises on a non-object, so every caller that
    reads provider or store JSON has to guard the shape first. This answers
    the same question totally: absent field and wrong shape are both [None].

    It lived as an identical private copy in masc_tui_render.ml and
    masc_tui.ml. One implementation, so the two cannot drift. *)

val member_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
