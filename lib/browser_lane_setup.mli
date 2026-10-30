(** Installs the browser lane for one workspace: the lane token, the native
    host and the launcher, and, for the MASC extension route, the extension
    and the native messaging manifest that lets Firefox start the host for it.
    [masc browser-lane-setup] is this module's command.

    Installing writes only files: it starts no browser, edits no
    [runtime.toml] and loads no extension, because Firefox loads a temporary
    add-on only from [about:debugging]. The BiDi route's table in
    [runtime.toml] is {!Browser_lane_bidi_setup}'s. *)

module Host_name : sig
  (** The native messaging host's name: lowercase letters, digits and
      underscores, in nonempty segments separated by single dots. It becomes a
      file name in the manifest directory and the manifest's [name]. *)
  type t

  val default : t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end

(** What only the extension route needs. *)
type extension_route =
  { manifest_dir : string
        (** Where Firefox looks for native messaging manifests. *)
  ; host_name : Host_name.t
  }

type request =
  { base_path : string
        (** The workspace root, absolute. The lane lives under
            [<base_path>/.masc/browser-lane]. *)
  ; binary : string option
        (** The built [masc-browser-host] to copy. When absent, the one beside
            the running [masc], then the first on [PATH]. *)
  ; token_file : string option
        (** A lane token already provisioned. It must exist and hold a token
            ({!Browser_lane.Lane_token}), and equal the workspace's own token
            when that exists. A relative path is taken from [base_path]. *)
  ; extension : extension_route option
        (** [Some] also writes the extension and the manifest for it. [None]
            writes the host and the launcher alone, which is all the BiDi
            route starts. *)
  }

type extension_installed =
  { native_manifest : string  (** The native messaging manifest. *)
  ; directory : string  (** Where the extension files were written. *)
  ; load : string  (** The file to choose in [about:debugging]. *)
  }

type installed =
  { host : string  (** The copied host executable. *)
  ; host_source : string  (** The executable that was copied. *)
  ; launcher : string  (** The [launch] script Firefox runs. *)
  ; declaration : string  (** The [launch.json] beside it. *)
  ; token : string  (** The workspace's canonical lane token file. *)
  ; extension : extension_installed option
  }

type error =
  | Base_path_not_absolute of string
  | Host_binary_not_found
  | Host_binary_not_executable of string
  | Token_file_unusable of { path : string; reason : string }
      (** [--token-file] names nothing readable, or something that is not a
          lane token. *)
  | Lane_token_unusable of { path : string; reason : string }
      (** The workspace's own token file exists and is not a lane token. It is
          left as it is: replacing a token is the operator's call. *)
  | Token_file_differs of { given : string; canonical : string }
  | Embedded_extension_invalid of string
  | Io of { step : string; path : string; reason : string }

val error_message : error -> string

type platform = Macos | Linux

val current_platform : unit -> platform option
(** The host this runs on, as Firefox's native messaging directory depends on
    it. [None] on anything else. *)

val default_manifest_directory : home:string -> platform -> string
(** Firefox's per-user native messaging directory: under
    [Library/Application Support/Mozilla] on macOS and [.mozilla] on Linux. *)

val install : request -> (installed, error) result
(** Everything that can be refused is refused before the first file is
    written: the request, the host to copy, the extension this build carries,
    the token, and each directory (it must exist as a directory and be
    writable). Then it writes, in this order: the token (once, mode [0600],
    published whole and never replaced), the host, the launcher, the extension
    files and the manifest when the extension route is asked for, and last
    [launch.json]. [launch.json] is what makes
    the launcher count as installed, so an install that stops part way reads
    as not installed, not as installed.

    The host, the launcher, the manifest and the extension files are replaced
    whole, each through a temporary file in its own directory, so Firefox
    never reads half of one, and a write that fails when the file is closed
    is an error, not a published truncated file. The launcher names no
    server: the host reads the workspace connection when it starts. *)
