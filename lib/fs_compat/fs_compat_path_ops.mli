(** Path operations of [Fs_compat]: the optional loads, [file_size], the
    publish, exchange, rename and clone entry points, unlink and tree removal,
    subdirectory names, [realpath], and [mkdir_p] with its memo. [Fs_compat]
    includes this module. *)

val load_file_opt : string -> string option

module Optional_read_for_testing :
  sig
    val load_file_opt : before_read:(unit -> 'a) -> string -> string option
  end

val file_size : string -> int option

val exchange_paths : string -> string -> unit

val rename_noreplace : string -> string -> unit

val clone_file : string -> string -> unit

val rename : string -> string -> unit

val rename_if_exists : src:string -> dst:string -> bool

val unlink_if_exists : string -> bool

val remove_tree : string -> unit

val subdirectory_names : string -> string list

val realpath : string -> string

val realpath_lenient : string -> string

val mkdir_p : string -> unit

val mkdir_p_memoized : string -> unit

val invalidate_mkdir_memo : string -> unit

val reset_mkdir_memo_for_testing : unit -> unit
