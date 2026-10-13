(** Installs the browser lane for one workspace: the lane token, the native
    host and the launcher Firefox runs, and the native messaging manifest that
    lets the MASC extension start it. [masc browser-lane-setup] is this
    module's command.

    Installing writes only files: it starts no browser, edits no
    [runtime.toml] and loads no extension, because Firefox loads a temporary
    add-on only from [about:debugging]. What the operator does in the browser
    is the last thing {!install} tells them. *)

module Host_name : sig
  (** The native messaging host's name: lowercase letters, digits and
      underscores, in nonempty segments separated by single dots. It becomes a
      file name in the manifest directory and the manifest's [name]. *)
  type t

  val default : t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end

type request =
  { base_path : string
        (** The workspace root, absolute. The lane lives under
            [<base_path>/.masc/browser-lane]. *)
  ; binary : string option
        (** The built [masc-browser-host] to copy. When absent, the one beside
            the running [masc], then the first on [PATH]. *)
  ; token_file : string option
        (** A lane token already provisioned. It must exist, hold something,
            and equal the workspace's canonical token when that exists. A
            relative path is taken from [base_path]. *)
  ; manifest_dir : string
        (** Where Firefox looks for native messaging manifests. *)
  ; host_name : Host_name.t
  }

type installed =
  { host : string  (** The copied host executable. *)
  ; launcher : string  (** The [launch] script Firefox runs. *)
  ; declaration : string  (** The [launch.json] beside it. *)
  ; manifest : string  (** The native messaging manifest. *)
  ; token : string  (** The workspace's canonical lane token file. *)
  ; extension_directory : string  (** Where the extension files were written. *)
  ; extension_manifest : string  (** The file to choose in [about:debugging]. *)
  }

type error =
  | Base_path_not_absolute of string
  | Host_binary_not_found
  | Host_binary_not_executable of string
  | Token_file_unusable of string
      (** [--token-file] names nothing, or an empty file. *)
  | Lane_token_unusable of string
      (** The workspace's own token file exists and is empty or not a regular
          file. It is left as it is: replacing a token is the operator's call. *)
  | Token_file_differs of { given : string; canonical : string }
  | Embedded_extension_invalid of string
  | Io of { step : string; path : string; reason : string }

val error_message : error -> string

val default_manifest_directory : home:string -> Sandbox_readiness.host -> string option
(** Firefox's per-user native messaging directory: under
    [Library/Application Support/Mozilla] on macOS and [.mozilla] on Linux.
    [None] on a host this installer does not support. *)

val install : request -> (installed, error) result
(** Creates what is missing and rewrites the rest: the token is created once
    (mode [0600]) and never replaced; the host, the launcher, the declaration,
    the manifest and the extension files are replaced whole, each through a
    temporary file in its own directory, so Firefox never reads half of one.
    The launcher names no server: the host reads the workspace connection when
    it starts. *)
