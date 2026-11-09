(** JSONL reads of [Fs_compat]: line parsing and numbering, [load_jsonl] with
    its diagnostics, [read_slice], the appended-line and whole-file folds, the
    cached writer hooks, and [read_fd_chunks]. [Fs_compat] includes this
    module. *)

val parse_jsonl_line : source:string -> line_no:int -> string -> Yojson.Safe.t option

val number_jsonl_lines : string list -> (int * string) list

val parse_jsonl_lines : source:string -> string list -> Yojson.Safe.t list * int

val load_jsonl_diagnostics : string -> Yojson.Safe.t list * int

val load_jsonl : string -> Yojson.Safe.t list

val read_slice : path:string -> from:int -> len:int -> string

val fold_appended_lines :
  path:string -> from:int -> init:'a -> f:('a -> string -> 'a) -> 'a * int

val fold_jsonl_lines :
  init:'a -> f:('a -> line_no:int -> Yojson.Safe.t -> 'a) -> string -> 'a

val invalidate_cached_writer : string -> unit

val reset_fd_cache_for_testing : unit -> unit

val with_cached_writer_for_testing : string -> (out_channel -> 'a) -> 'a

val read_fd_chunks : Unix.file_descr -> string
