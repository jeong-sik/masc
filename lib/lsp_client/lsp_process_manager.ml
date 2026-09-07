(** LSP Process Manager — spawn and manage language server processes.

    Handles the lifecycle of LSP server child processes:
    - Spawn via [Eio.Process] with stdin/stdout pipes
    - LSP JSON-RPC framing: [Content-Length] header parsing on stdout
    - Structured cleanup via [Eio.Switch]
    - Per-language command resolution *)

type lsp_process =
  { lang_id : string
  ; proc : Eio_unix.Process.ty Eio.Std.r
  ; stdin_w : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Std.r
  ; stdout_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r
  ; stderr_r : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r
  }

type spawn_error =
  | Command_not_found of string
  | Startup_timeout of string
  | Process_error of string

let pp_spawn_error fmt = function
  | Command_not_found cmd -> Fmt.pf fmt "LSP server not found: %s" cmd
  | Startup_timeout lang -> Fmt.pf fmt "LSP server startup timeout for %s" lang
  | Process_error msg -> Fmt.pf fmt "LSP process error: %s" msg
;;

(* One row per language the client knows. A variant rather than string
   matches: adding a language fails to compile until its wire id, its
   command, its extensions and its root rule are all given, where a table
   keyed by string left the others silently answering "unknown". The
   commands are each server's documented stdio invocation; on the host this
   was written on, ocamllsp, rust-analyzer, clangd and sourcekit-lsp were
   present and answered, the rest were not installed (RFC-0429 §1.6, §3.2).
   An operator who runs a different server for a language points at it in
   runtime.toml; this table is what stands when nothing is said. *)
type reference_index =
  { artifact_suffix : string
  ; search_root : string
  ; build_command : string
  }

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
  | Markdown

(* Every variant once, in the order the wire and the error texts list them.
   The compiler cannot check a list against a sum; the language test walks
   this list against the exhaustive functions below and fails when a
   variant is missing here. *)
let all_languages =
  [ Ocaml; Typescript; Javascript; Python; Rust; Go; C; Cpp; Swift; Java; Kotlin
  ; Ruby; Php; Lua; Bash; Json; Yaml; Zig; Haskell; Elixir; Dart; Scala; Csharp
  ; Markdown ]
;;

(* The LSP languageId each server is initialised with. Bash is
   "shellscript" on the wire, the name the protocol registers for it. *)
let lang_id_of_language = function
  | Ocaml -> "ocaml"
  | Typescript -> "typescript"
  | Javascript -> "javascript"
  | Python -> "python"
  | Rust -> "rust"
  | Go -> "go"
  | C -> "c"
  | Cpp -> "cpp"
  | Swift -> "swift"
  | Java -> "java"
  | Kotlin -> "kotlin"
  | Ruby -> "ruby"
  | Php -> "php"
  | Lua -> "lua"
  | Bash -> "shellscript"
  | Json -> "json"
  | Yaml -> "yaml"
  | Zig -> "zig"
  | Haskell -> "haskell"
  | Elixir -> "elixir"
  | Dart -> "dart"
  | Scala -> "scala"
  | Csharp -> "csharp"
  | Markdown -> "markdown"
;;

let language_of_lang_id id =
  List.find_opt (fun language -> String.equal (lang_id_of_language language) id) all_languages
;;

let command_of_language = function
  | Ocaml -> "ocamllsp", [ "ocamllsp" ]
  | Typescript | Javascript ->
    "typescript-language-server", [ "typescript-language-server"; "--stdio" ]
  | Python -> "pyright-langserver", [ "pyright-langserver"; "--stdio" ]
  | Rust -> "rust-analyzer", [ "rust-analyzer" ]
  | Go -> "gopls", [ "gopls" ]
  | C | Cpp -> "clangd", [ "clangd" ]
  | Swift -> "sourcekit-lsp", [ "sourcekit-lsp" ]
  | Java -> "jdtls", [ "jdtls" ]
  | Kotlin -> "kotlin-language-server", [ "kotlin-language-server" ]
  | Ruby -> "ruby-lsp", [ "ruby-lsp" ]
  | Php -> "intelephense", [ "intelephense"; "--stdio" ]
  | Lua -> "lua-language-server", [ "lua-language-server" ]
  | Bash -> "bash-language-server", [ "bash-language-server"; "start" ]
  | Json -> "vscode-json-language-server", [ "vscode-json-language-server"; "--stdio" ]
  | Yaml -> "yaml-language-server", [ "yaml-language-server"; "--stdio" ]
  | Zig -> "zls", [ "zls" ]
  | Haskell -> "haskell-language-server-wrapper", [ "haskell-language-server-wrapper"; "--lsp" ]
  | Elixir -> "elixir-ls", [ "elixir-ls" ]
  | Dart -> "dart", [ "dart"; "language-server" ]
  | Scala -> "metals", [ "metals" ]
  | Csharp -> "csharp-ls", [ "csharp-ls" ]
  | Markdown -> "marksman", [ "marksman"; "server" ]
;;

(* Where a language server for this language is rooted. A file whose
   directory a marker names, nearest first; or the workspace boundary for
   languages that have no project file of their own -- a shell script, a
   JSON or YAML document, a C# solution named by a pattern rather than a
   fixed file -- so the server sees the whole checkout. [dune-workspace]
   sits above [dune-project] in a multi-project tree, so it is listed
   second and only wins where no [dune-project] is nearer. *)
type root_rule =
  | Marker_files of string list
  | Boundary_root

let root_rule_of_language = function
  | Ocaml -> Marker_files [ "dune-project"; "dune-workspace" ]
  | Typescript -> Marker_files [ "tsconfig.json"; "package.json" ]
  | Javascript -> Marker_files [ "jsconfig.json"; "package.json" ]
  | Python -> Marker_files [ "pyproject.toml"; "setup.py"; "setup.cfg" ]
  | Rust -> Marker_files [ "Cargo.toml" ]
  | Go -> Marker_files [ "go.mod" ]
  | C | Cpp -> Marker_files [ "compile_commands.json"; "CMakeLists.txt"; "Makefile" ]
  | Swift -> Marker_files [ "Package.swift" ]
  | Java -> Marker_files [ "pom.xml"; "build.gradle"; "build.gradle.kts" ]
  | Kotlin -> Marker_files [ "build.gradle.kts"; "settings.gradle.kts"; "build.gradle" ]
  | Ruby -> Marker_files [ "Gemfile" ]
  | Php -> Marker_files [ "composer.json" ]
  | Lua -> Marker_files [ ".luarc.json" ]
  | Bash | Json | Yaml | Csharp | Markdown -> Boundary_root
  | Zig -> Marker_files [ "build.zig" ]
  | Haskell -> Marker_files [ "stack.yaml"; "cabal.project" ]
  | Elixir -> Marker_files [ "mix.exs" ]
  | Dart -> Marker_files [ "pubspec.yaml" ]
  | Scala -> Marker_files [ "build.sbt" ]
;;

(* What a language server needs on disk before it can answer about references
   in files other than the one it was given. Measured for OCaml: with no
   .ocaml-index, references on a two-file project answered 1 occurrence where
   the truth was 3; after `dune build @ocaml-index` (0.33 s on that project) it
   answered all 3, across both files.

   Every other language is [None]: their servers hold the index themselves,
   or nobody has measured them here. [None] means "no precondition this
   client checks", not "measured as needing nothing". *)
let reference_index_of_language = function
  | Ocaml ->
    Some
      { artifact_suffix = ".ocaml-index"
      ; search_root = "_build"
      ; build_command = "dune build @ocaml-index"
      }
  | Typescript | Javascript | Python | Rust | Go | C | Cpp | Swift | Java | Kotlin | Ruby
  | Php | Lua | Bash | Json | Yaml | Zig | Haskell | Elixir | Dart | Scala | Csharp
  | Markdown ->
    None
;;

(* Variables that redirect this language's toolchain to a build directory other
   than the one under [~workspace_root]. Inherited from masc they override the
   root the caller asked for, and the symptom is not an error: measured on a
   two-file project with its index built, references answered 3 occurrences
   with a clean environment and 1 with DUNE_BUILD_DIR pointing at another
   tree's build. Same project, same index, same position.

   The working directory was checked the same way and does not do this:
   ocamllsp resolves merlin config from rootUri, and a server started in an
   unrelated directory still answered 3. So the cwd is left alone. *)
let redirecting_variables_of_language = function
  | Ocaml -> [ "DUNE_BUILD_DIR"; "DUNE_WORKSPACE" ]
  | Typescript | Javascript | Python | Rust | Go | C | Cpp | Swift | Java | Kotlin | Ruby
  | Php | Lua | Bash | Json | Yaml | Zig | Haskell | Elixir | Dart | Scala | Csharp
  | Markdown ->
    []
;;

(* The extensions a language owns, lower-case with the dot. One table, read
   both ways: {!language_of_extension} searches it, and the error text that
   names what is covered is built from it. *)
let extensions_of_language = function
  | Ocaml -> [ ".ml"; ".mli" ]
  | Typescript -> [ ".ts"; ".tsx" ]
  | Javascript -> [ ".js"; ".jsx"; ".mjs"; ".cjs" ]
  | Python -> [ ".py"; ".pyi" ]
  | Rust -> [ ".rs" ]
  | Go -> [ ".go" ]
  | C -> [ ".c"; ".h" ]
  | Cpp -> [ ".cc"; ".cpp"; ".cxx"; ".hpp"; ".hh"; ".hxx" ]
  | Swift -> [ ".swift" ]
  | Java -> [ ".java" ]
  | Kotlin -> [ ".kt"; ".kts" ]
  | Ruby -> [ ".rb" ]
  | Php -> [ ".php" ]
  | Lua -> [ ".lua" ]
  | Bash -> [ ".sh"; ".bash"; ".zsh" ]
  | Json -> [ ".json" ]
  | Yaml -> [ ".yml"; ".yaml" ]
  | Zig -> [ ".zig" ]
  | Haskell -> [ ".hs" ]
  | Elixir -> [ ".ex"; ".exs" ]
  | Dart -> [ ".dart" ]
  | Scala -> [ ".scala"; ".sc" ]
  | Csharp -> [ ".cs" ]
  | Markdown -> [ ".md"; ".markdown" ]
;;

let language_of_extension ext =
  List.find_opt (fun language -> List.mem ext (extensions_of_language language)) all_languages
;;

(* How a memo (Ide_memo) is spelled in each language's comment syntax.
   [None] is the one language with no comment syntax at all: a memo cannot
   stand in JSON. *)
let memo_markers_of_language = function
  | Ocaml -> Some (Ide_memo.Block { opens = "(*"; closes = "*)" })
  | Typescript | Javascript | Rust | Go | C | Cpp | Swift | Java | Kotlin | Php | Zig | Dart
  | Scala | Csharp -> Some (Ide_memo.Line "//")
  | Python | Ruby | Bash | Yaml | Elixir -> Some (Ide_memo.Line "#")
  | Lua | Haskell -> Some (Ide_memo.Line "--")
  | Markdown -> Some (Ide_memo.Block { opens = "<!--"; closes = "-->" })
  | Json -> None
;;

type memo_line_refusal =
  | Extension_unknown of string
  | No_comment_syntax of language

let memo_line_refusal_to_string = function
  | Extension_unknown "" -> "the file has no extension, so no language here owns it"
  | Extension_unknown ext -> Printf.sprintf "no language here owns the extension %s" ext
  | No_comment_syntax language ->
    Printf.sprintf "%s has no comment syntax, so a memo cannot stand in it"
      (lang_id_of_language language)
;;

(* The comment line a memo becomes in the file at [path]. One function, so
   the tool that writes the line and the projection that records the call
   spell it the same way. *)
let memo_markers_of_path path =
  let extension = String.lowercase_ascii (Filename.extension path) in
  match language_of_extension extension with
  | None -> Error (Extension_unknown extension)
  | Some language ->
    (match memo_markers_of_language language with
     | None -> Error (No_comment_syntax language)
     | Some markers -> Ok markers)
;;

let memo_line ~path (memo : Ide_memo.t) =
  Result.map (fun markers -> Ide_memo.to_line markers memo) (memo_markers_of_path path)
;;

let covered_extensions () = List.concat_map extensions_of_language all_languages

(* Who answers "which command starts this language's server": the table
   above when nothing is said, the operator's [lsp.servers] entry for a
   language when there is one. Threaded in by the caller rather than read
   here, because this library sits below the module that reads
   runtime.toml. *)
type servers = language -> string * string list

(** Language → command mapping. Returns [(executable, argv)] or [None]. *)
let command_for_lang lang_id =
  Option.map command_of_language (language_of_lang_id lang_id)
;;

(** Detect the language of a file from its extension. [Filename.extension] and
    [String.lowercase_ascii] are total (no extension yields [""]), so no guard
    is needed around them. *)
let language_of_path file_path =
  Filename.extension file_path |> String.lowercase_ascii |> language_of_extension
;;

(** Detect language from file extension, as the wire id the IDE proxy speaks.
    ["unknown"] where {!language_of_path} answers [None]. *)
let lang_of_path file_path =
  match language_of_path file_path with
  | Some language -> lang_id_of_language language
  | None -> "unknown"
;;

(** Check that an executable exists on [PATH]. *)
let command_exists cmd =
  Executable_path.path_has_executable cmd
;;

(** Allocate a fresh JSON-RPC request ID for this process. *)
(** Write a JSON-RPC message to the process stdin with Content-Length framing.

    LSP spec: messages are framed as
    {[ Content-Length: <N>\r\n\r\n<payload> ]} *)
let write_message (proc : lsp_process) (json : string) =
  let payload = Bytes.unsafe_of_string json in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (Bytes.length payload) in
  Eio.Flow.copy_string header proc.stdin_w;
  Eio.Flow.copy_string json proc.stdin_w
;;

(** Read exactly [n] bytes from a flow into a string. *)
let read_exact (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) n =
  let buf = Cstruct.create n in
  Eio.Flow.read_exact flow buf;
  Cstruct.to_string buf
;;

(** Read a single header line (terminated by [\r\n]) from the flow.
    Returns the line content without the trailing [\r\n]. *)
let read_header_line (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) =
  let buf = Buffer.create 64 in
  let rec loop prev =
    let ch = Cstruct.create 1 in
    Eio.Flow.read_exact flow ch;
    let c = Cstruct.get ch 0 in
    if c = '\n' && prev = '\r'
    then (
      let s = Buffer.contents buf in
      let len = String.length s in
      if len > 0 && String.get s (len - 1) = '\r' then String.sub s 0 (len - 1) else s)
    else (
      Buffer.add_char buf c;
      loop c)
  in
  loop '\000'
;;

(** Parse [Content-Length] value from a header line.
    Returns [Some n] if the header matches, [None] otherwise. *)
let parse_content_length line =
  let prefix = "Content-Length: " in
  if String.starts_with ~prefix line
  then (
    let raw =
      String.sub line (String.length prefix) (String.length line - String.length prefix)
    in
    try Some (int_of_string (String.trim raw)) with
    | Failure _ -> None)
  else None
;;

(** Read one complete LSP message from stdout.

    Reads headers until empty line, then reads [Content-Length] bytes.
    Returns the JSON payload string. *)
let read_message (flow : [ Eio.Flow.source_ty | Eio.Resource.close_ty ] Eio.Std.r) =
  let rec read_headers content_length =
    let line = read_header_line flow in
    if String.length line = 0
    then (
      (* Empty line signals end of headers *)
      match content_length with
      | Some n -> read_exact flow n
      | None ->
        (* No Content-Length found; protocol violation.
              Return empty string so caller can detect and handle. *)
        "")
    else (
      let len = parse_content_length line in
      read_headers
        (match len with
         | Some n -> Some n
         | None -> content_length))
  in
  read_headers None
;;

(** Spawn an LSP server process for the given language.

    The process is bound to [sw] — when the switch is turned off,
    the process is terminated automatically via [on_release]. *)
let spawn
    ~sw
    ~(servers : servers)
    ~lang_id
    ~workspace_root
    (proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t)
  : (lsp_process, spawn_error) result
  =
  match language_of_lang_id lang_id with
  | None -> Error (Command_not_found lang_id)
  | Some language ->
    let cmd, argv = servers language in
    if not (command_exists cmd)
    then Error (Command_not_found cmd)
    else (
      try
        let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
        let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
        let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
        let child_env =
          match language_of_lang_id lang_id with
          | None -> Unix.environment ()
          | Some language ->
            (match redirecting_variables_of_language language with
             | [] -> Unix.environment ()
             | redirecting ->
               Array.of_list
                 (List.filter
                    (fun binding ->
                      match String.index_opt binding '=' with
                      | None -> true
                      | Some at ->
                        let name = String.sub binding 0 at in
                        not (List.exists (String.equal name) redirecting))
                    (Array.to_list (Unix.environment ()))))
        in
        let proc =
          Eio.Process.spawn
            ~sw
            proc_mgr
            ~stdin:stdin_r
            ~stdout:stdout_w
            ~stderr:stderr_w
            ~env:child_env
            argv
        in
        Eio.Flow.close stdin_r;
        Eio.Flow.close stdout_w;
        Eio.Flow.close stderr_w;
        Eio.Switch.on_release sw (fun () ->
          try Eio.Process.signal proc Sys.sigterm with
          | exn ->
            Log.Server.debug
              "LSP process signal failed for %s: %s"
              lang_id
              (Printexc.to_string exn));
        (* Drain stderr to a log — prevents pipe stall *)
        Eio.Fiber.fork ~sw (fun () ->
          let buf = Buffer.create 256 in
          try
            while true do
              let line = read_header_line stderr_r in
              Buffer.add_string buf line;
              Buffer.add_char buf '\n';
              if Buffer.length buf > 4096
              then (
                Log.Server.debug "LSP %s stderr: %s" lang_id (Buffer.contents buf);
                Buffer.clear buf)
            done
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Server.debug
              "LSP %s stderr reader ended: %s"
              lang_id
              (Printexc.to_string exn));
        Ok { lang_id; proc; stdin_w; stdout_r; stderr_r }
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Process_error (Printexc.to_string exn)))
;;

(** Tear down a spawned LSP process whose initialization failed or that is
    being evicted. [spawn] binds the child, its 3 pipe FDs ([stdin_w],
    [stdout_r], [stderr_r]), the stderr-drain fiber, and (via
    [Lsp_message_router.start_response_reader]) the response-reader fiber to the
    caller's [~sw] — which the gRPC proxy scopes to the SERVER lifetime. Without
    this teardown a failed [initialize] orphans the proc + 3 pipe FDs + 2 reader
    fibers on that switch until server shutdown, and the next request re-spawns
    (RFC-0261 / issue #21546).

    Mechanism: closing [stdin_w], [stdout_r], and [stderr_r] releases all three
    FDs the record holds — every pipe FD bound to the switch. (Fiber exit on EOF
    is NOT FD release: signalling the child makes the drain fiber reach EOF and
    exit, but its [stderr_r] FD stays bound to the switch until explicitly
    closed.) Closing [stdout_r] also makes [Lsp_message_router.read_message]
    raise so the response-reader fiber exits; closing [stderr_r] ends the
    stderr-drain fiber's read. [Eio.Process.signal ... sigterm] stops the child.
    All operations are non-blocking, so this is safe to call while holding the
    spawn mutex. Each is best-effort and logs at debug on failure;
    [Eio.Cancel.Cancelled] is re-raised so cancellation still propagates. *)
let shutdown (proc : lsp_process) =
  let quietly what f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.debug
        "LSP shutdown for %s: %s failed: %s"
        proc.lang_id
        what
        (Printexc.to_string exn)
  in
  quietly "signal" (fun () -> Eio.Process.signal proc.proc Sys.sigterm);
  quietly "stdin_w close" (fun () -> Eio.Flow.close proc.stdin_w);
  quietly "stdout_r close" (fun () -> Eio.Flow.close proc.stdout_r);
  quietly "stderr_r close" (fun () -> Eio.Flow.close proc.stderr_r)
;;
