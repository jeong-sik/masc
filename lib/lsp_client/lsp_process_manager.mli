(** LSP Process Manager — spawn and manage language server processes.

    Public interface for [Lsp_process_manager]. Internal helpers
    ([read_exact], [read_header_line], [parse_content_length]) are
    intentionally not exposed. *)

type lsp_process = {
  lang_id : string;
  proc : Eio_unix.Process.ty Eio.Std.r;
  stdin_w : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Std.r;
  stdout_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r;
  stderr_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r;
}

type spawn_error =
  | Command_not_found of string
  | Startup_timeout of string
  | Process_error of string

val pp_spawn_error : Format.formatter -> spawn_error -> unit

(** The languages this client knows. One variant rather than one string match
    per question, so a language cannot have a command and no project markers:
    every per-language function below is an exhaustive match. *)
type language =
  | Ocaml
  | Typescript
  | Javascript
  | Python
  | Rust
  | Go

val lang_id_of_language : language -> string
val language_of_lang_id : string -> language option

(** The executable and argv that start this language's server. *)
val command_of_language : language -> string * string list

(** Files whose directory is a project root for this language, nearest first.
    {!Lsp_project_root} walks a file's ancestors looking for these. *)
val project_markers_of_language : language -> string list

(** The language of a file, by extension. [None] for a file no server here
    covers. *)
val language_of_path : string -> language option

(** Language → command mapping. Returns [(executable, argv)] or [None]. *)
val command_for_lang : string -> (string * string list) option

(** Detect language from file extension, as the wire id the IDE proxy speaks.
    ["unknown"] where {!language_of_path} answers [None]. *)
val lang_of_path : string -> string

(** Allocate a fresh JSON-RPC request ID for this process. *)
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

(** Tear down a spawned LSP process whose [initialize] failed or that is being
    evicted: signals the child and closes all three held pipe FDs ([stdin_w],
    [stdout_r], [stderr_r]). The stderr-drain and response-reader fibers exit on
    the resulting close. Non-blocking — safe to call while holding the spawn
    mutex. Without it, a proc bound to the server-lifetime switch leaks until
    shutdown (RFC-0261 / #21546). *)
val shutdown : lsp_process -> unit
