(** Names seen on connector people and channels, kept across restarts.

    Live connector answers always win. Stored names are used only when the
    current event has no name. Connector and scope keep unrelated id spaces
    separate. *)

type scope =
  | Person
  | Channel

val remember :
  base_dir:string ->
  connector:string ->
  scope:scope ->
  id:string ->
  name:string ->
  unit ->
  unit
(** Record a non-blank name for a non-blank id. Repeating the current name does
    not append another durable row. *)

val recall :
  base_dir:string -> connector:string -> scope:scope -> id:string -> string option
(** Recall the most recently observed name. Each scoped connector file is
    loaded once per process, so fallback cost does not grow per message. *)

val entries :
  base_dir:string -> connector:string -> scope:scope -> (string * string) list
(** Current ID-to-name projection, sorted by ID. Name changes replace the
    projected value while the JSONL retains their append-only history. *)

val path : base_dir:string -> connector:string -> scope:scope -> string
(** Durable JSONL path for this connector/scope mapping. *)
