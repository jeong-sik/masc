val tool_input_file_path : Yojson.Safe.t -> string option
(** Extract the edited file path from a tool input payload.

    Key priority is shared across IDE tool events, IDE cursor attribution, and
    keeper observation attribution. Caller-specific base-path or cwd fallback
    remains outside this helper. *)
