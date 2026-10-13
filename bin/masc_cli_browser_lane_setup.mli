(** [masc browser-lane-setup]: connect this workspace's browser lane to
    Firefox through the MASC extension.

    Without a mode it writes nothing and says what is installed. With
    [--mode extension] it installs the native host, its launcher and manifest,
    and writes the extension for Firefox to load. It starts no browser and
    edits no runtime.toml. *)

type mode = Extension

val run
  :  base_path:string
  -> mode:mode option
  -> binary:string option
  -> token_file:string option
  -> manifest_dir:string option
  -> host_name:string option
  -> int
(** The process exit code: [0] when it printed the state or finished the
    install, [1] when it refused and said why on stderr. *)
