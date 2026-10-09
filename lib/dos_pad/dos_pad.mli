include module type of Machine_pad_layout
  with type button = Machine_pad_layout.button
   and type binding = Machine_pad_layout.binding
   and type layout = Machine_pad_layout.layout
   and type source = Machine_pad_layout.source

val parse : string -> (layout, string) result
(** A layout file: one table per bound button, named as {!button_to_string}
    names it, each with [keys] (a non-empty array of key names) and [label]
    (a non-empty string). An unknown table, field or key name is an error,
    not an unbound button: a typo would otherwise leave a button that
    silently does nothing. *)

val pads_dir : base_path:string -> string
(** [<.masc>/dos/pads], beside the DOS checkpoints. Not inside a program's
    directory: [masc_dos_load] mounts what sits beside the executable into
    DOS, so a layout there would show up inside the game. *)

val load : base_path:string -> saves_name:string -> ((source * layout) option, string) result
(** The layout for the program loaded under [saves_name]: the workspace file
    when there is one, else the embedded [config/pads/*.toml] asset whose
    basename is [saves_name], else [None]. Only a genuinely
    absent workspace path permits fallback. An unreadable path, dangling link,
    non-regular file or malformed layout is an error. A symlink to a readable
    regular file remains a workspace override. The opened descriptor is checked
    before reading; a FIFO is never accepted as layout contents. *)
