(** [masc browser-lane-setup]: connect this workspace's browser lane to
    Firefox, by either route or both.

    Without a mode it writes nothing and says what is installed. [--mode
    extension] installs the native host, its launcher and manifest, and writes
    the extension for Firefox to load. [--mode bidi] installs the host and its
    launcher and writes the [\[browser.live.bidi\]] table of runtime.toml, so
    the MASC server starts a Firefox of its own. [--mode host] installs the host
    and its launcher and nothing else: no browser is connected, and no
    runtime.toml is needed or written. It starts no browser and loads no
    extension.

    An option that the chosen modes do not use is refused, not ignored. *)

type mode = Masc.Browser_lane_launcher.route

val run
  :  base_path:string
  -> runtime_config_path:string
  -> modes:mode list
  -> binary:string option
  -> token_file:string option
  -> manifest_dir:string option
  -> host_name:string option
  -> firefox:string option
  -> profile:string option
  -> port:int option
  -> int
(** The process exit code: [0] when it printed the state or finished the
    install, [1] when it refused and said why on stderr. *)
