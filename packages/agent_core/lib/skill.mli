(** Markdown skill loading with lightweight frontmatter support.

    Parses YAML-like frontmatter (---/--- delimited) into key-value pairs
    and extracts the body for prompt composition.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Types} *)

type scope =
  | Project
  | User
  | Local
  | Custom of string
[@@deriving show]

type t =
  { name : string
  ; description : string option
  ; body : string
  ; path : string option
  ; scope : scope option
  ; allowed_tools : string list
  ; argument_hint : string option
  ; model : string option
  ; supporting_files : string list
  ; metadata : (string * string list) list
  }
[@@deriving show]

(** {1 String helpers} *)

val strip_quotes : string -> string
val split_csv : string -> string list
val replace_all : pattern:string -> replacement:string -> string -> string

(** {1 Frontmatter parsing} *)

val parse_frontmatter : string -> (string * string list) list * string
val frontmatter_value : (string * string list) list -> string -> string option
val frontmatter_values : (string * string list) list -> string -> string list

(** {1 Constructors} *)

val scope_of_string : string -> scope
val of_markdown : ?path:string -> ?scope:scope -> string -> t
val load : ?scope:scope -> string -> (t, Error.sdk_error) result
val load_dir : ?scope:scope -> string -> t list

(** {1 Prompt composition} *)

val render_prompt : ?arguments:string -> t -> string
val supporting_file_paths : t -> string list
