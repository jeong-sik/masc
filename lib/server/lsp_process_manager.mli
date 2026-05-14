(** LSP Process Manager — spawn and manage language server processes.

    Public interface for [Lsp_process_manager]. Internal helpers
    ([read_exact], [read_header_line], [parse_content_length]) are
    intentionally not exposed. *)

type lsp_process = {
  lang_id : string;
  proc : Eio_unix.Process.ty Eio.Std.r;
  stdin_w : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Std.r;
  stdout_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r;
  mutable next_id : int;
}

type spawn_error =
  | Command_not_found of string
  | Startup_timeout of string
  | Process_error of string

val pp_spawn_error : Format.formatter -> spawn_error -> unit

(** Language → command mapping. Returns [(executable, argv)] or [None]. *)
val command_for_lang : string -> (string * string list) option

(** Detect language from file extension. *)
val lang_of_path : string -> string

(** Allocate a fresh JSON-RPC request ID for this process. *)
val alloc_id : lsp_process -> int

(** Write a JSON-RPC message to the process stdin with Content-Length framing. *)
val write_message : lsp_process -> string -> unit

(** Read one complete LSP message from stdout. Returns the JSON payload string. *)
val read_message : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r -> string

(** Spawn an LSP server process for the given language.

    The process is bound to [sw] — when the switch is turned off,
    the process is terminated automatically via [on_release]. *)
val spawn :
  sw:Eio.Switch.t ->
  lang_id:string ->
  workspace_root:string ->
  Eio_unix.Process.mgr_ty Eio.Resource.t ->
  (lsp_process, spawn_error) result
