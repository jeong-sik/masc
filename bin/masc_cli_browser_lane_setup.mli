(** [masc browser-lane-setup]: install this workspace's browser lane host, and
    connect it to Firefox by the extension, by a Firefox MASC starts, or by
    neither (a browser attached by hand).

    Without a mode it writes nothing and says what is installed. [--mode
    extension] installs the native host, its launcher and manifest, and writes
    the extension for Firefox to load. [--mode bidi] installs the host and its
    launcher and writes the [\[browser.live.bidi\]] table of runtime.toml, so
    the MASC server starts a Firefox of its own. [--mode host] installs the host
    and its launcher and nothing else: no browser is connected, and no
    runtime.toml is needed or written. [--mode automation] writes the
    geckodriver of the automation lane ([\[browser.automation\]]) and installs
    no host: that lane needs none. It starts no browser and loads no
    extension.

    [--mode addon] writes the browser Add-on package this masc carries to
    [.masc/packages/browser] and declares it when the workspace has no
    declaration of it ({!Masc.Browser_addon_setup}). Every other mode does the
    same after its host step, but there a refusal of that step is reported and
    the mode's own steps go on; only [--mode addon] fails on it. [--no-addon]
    skips the step for the other modes and contradicts [--mode addon].

    An option that the chosen modes do not use is refused, not ignored. *)

type mode = Addon | Extension | Bidi | Host | Automation

val all_modes : mode list

(** The value [--mode] takes. *)
val mode_name : mode -> string

val run
  :  base_path:string
  -> runtime_config_path:string
  -> modes:mode list
  -> no_addon:bool
  -> binary:string option
  -> token_file:string option
  -> manifest_dir:string option
  -> host_name:string option
  -> firefox:string option
  -> profile:string option
  -> port:int option
  -> geckodriver:string option
  -> browser:string option
  -> int
(** The process exit code: [0] when it printed the state or finished the
    install, [1] when it refused and said why on stderr. *)
