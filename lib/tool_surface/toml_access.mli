(** Toml_access — typed reads of [Otoml.t] values for the declaration files
    under [config/].

    Every reader takes [~context], the dotted path of the value being read
    (for example ["tool masc_status.params.limit"]), and fails with
    ["<context> must be <expected>, got <found>"], so a bad declaration names
    the key and what the file held instead. [Tool_definition_toml] and
    [Mcp_surface_toml] decode through these readers. *)

val shape : Otoml.t -> string
(** The article-prefixed name of a value's kind, as it appears after [got] in
    those messages: ["a string"], ["an integer"], ["an inline table"]. *)

val as_string : context:string -> Otoml.t -> (string, string) result

val as_non_empty_string : context:string -> Otoml.t -> (string, string) result
(** A string that is not blank after trimming. A blank one fails with
    ["<context> must not be empty"]. *)

val as_bool : context:string -> Otoml.t -> (bool, string) result
val as_int : context:string -> Otoml.t -> (int, string) result

val as_float : context:string -> Otoml.t -> (float, string) result
(** Only a TOML float. An integer is refused, because [0] and [0.0] serialize
    differently in the tool schema. *)

val as_table_pairs : context:string -> Otoml.t -> ((string * Otoml.t) list, string) result
(** A [\[table\]] or an inline table, with the members in document order. *)

val as_table_array : context:string -> Otoml.t -> (Otoml.t list, string) result
(** An array of tables, the [\[\[name\]\]] form. *)

val as_string_list : context:string -> Otoml.t -> (string list, string) result
(** An array of strings. A failing element is named ["<context>[<index>]"]. *)

val as_int_list : context:string -> Otoml.t -> (int list, string) result
(** An array of integers, with the elements named as in {!as_string_list}. *)
