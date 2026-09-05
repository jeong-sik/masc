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
    per question, so a language cannot have a command and no root rule: every
    per-language function below is an exhaustive match. *)
type language =
  | Ocaml
  | Typescript
  | Javascript
  | Python
  | Rust
  | Go
  | C
  | Cpp
  | Swift
  | Java
  | Kotlin
  | Ruby
  | Php
  | Lua
  | Bash
  | Json
  | Yaml
  | Zig
  | Haskell
  | Elixir
  | Dart
  | Scala
  | Csharp

(** Every variant once. The language test walks it against the exhaustive
    functions and fails when a variant is missing. *)
val all_languages : language list

(** The LSP languageId the server is initialised with; Bash is
    ["shellscript"] on the wire. *)
val lang_id_of_language : language -> string

val language_of_lang_id : string -> language option

(** The executable and argv that start this language's server: each
    server's documented stdio invocation, standing where the operator has
    not named another. *)
val command_of_language : language -> string * string list

(** Who answers "which command starts this language's server". The caller
    passes {!command_of_language} where nothing is configured, or the
    runtime's resolver where an operator named a server for a language. *)
type servers = language -> string * string list

(** What has to exist on disk before a language server answers about
    references outside the file it was given. *)
type reference_index =
  { artifact_suffix : string  (** e.g. [".ocaml-index"] *)
  ; search_root : string  (** directory under the project root to look in *)
  ; build_command : string  (** what a caller runs to produce it *)
  }

(** [None] where the server holds its own index and needs nothing on disk.

    Measured for OCaml: with no [.ocaml-index], [textDocument/references] on a
    two-file project answered one occurrence where the truth was three; after
    [dune build @ocaml-index] it answered all three, in both files. Every other
    language answers [None] because nobody has measured it here -- a statement
    about what this client checks, not a measurement. *)
val reference_index_of_language : language -> reference_index option

(** Where a server for this language is rooted: the nearest ancestor holding
    one of the marker files, or the workspace boundary itself for languages
    with no project file of their own. {!Lsp_project_root} applies it. *)
type root_rule =
  | Marker_files of string list  (** nearest first *)
  | Boundary_root

val root_rule_of_language : language -> root_rule

(** The extensions a language owns, lower-case with the dot. *)
val extensions_of_language : language -> string list

(** Every extension a server here covers, in language order. *)
val covered_extensions : unit -> string list

(** The language of a file, by extension. [None] for a file no server here
    covers. *)
val language_of_path : string -> language option

(** Language → command mapping. Returns [(executable, argv)] or [None]. *)
val command_for_lang : string -> (string * string list) option

(** Detect language from file extension, as the wire id the IDE proxy speaks.
    ["unknown"] for a file no server here covers. *)
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
  servers:servers ->
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
