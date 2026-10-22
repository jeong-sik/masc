(** Declare the browser Lane Add-on for a workspace, from the package this
    build carries.

    Since the browser Add-on owns every browser route, a native browser
    host's polls, results and disconnects go to an attached browser Add-on,
    and a workspace without one has no browser. {!apply} does the two steps
    that used to be by hand:

    - It writes the package this binary was built with to
      [<base>/.masc/packages/browser/] and removes the files there that this
      build does not carry. A later {!apply} from an upgraded build rewrites
      the files, so the declaration that names them does not change.
    - When no declaration of that package exists in the workspace's Lane
      directory, it creates [browser.toml] there. An existing declaration of
      the package is left as it is, whatever package path it names.

    It never attaches or starts anything. The server reads declarations at
    start and on its maintenance pass. An instance attached by hand without a
    declaration is not seen here; with it and a declaration attached, the
    server refuses host polls as ambiguous. *)

type declaration =
  | Created of { path : string }
  | Present of { path : string; manifest_path : string; this_build : bool; enabled : bool }
      (** A declaration of the browser package already existed. [this_build]
          is whether its [manifest_path] is the package {!apply} wrote;
          [enabled] is its desired activity. *)

type installed =
  { package_directory : string
  ; manifest_path : string  (** The package's [lane.toml] in [package_directory]. *)
  ; files_written : int  (** 0 when every file already held these bytes. *)
  ; files_removed : string list
        (** Paths of files an earlier build wrote that this one does not carry. *)
  ; declaration : declaration
  ; missing_programs : string list
        (** Programs the browser Add-on runs that this process cannot find:
            its worker command, looked up on [PATH], and every
            {!Native_addon_program.t}, looked up beside this MASC and then on
            [PATH]. The server looks the same way with its own [PATH], so the
            answer can differ for a server started with another environment. *)
  }

type error =
  | Base_path_not_absolute of string
  | Embedded_package_invalid of string
  | Package_unwritable of { path : string; reason : string }
  | Package_unloadable of { path : string; reason : string }
      (** The written manifest does not load with this build. *)
  | Config_root_invalid of string
  | Config_root_missing of string
      (** The workspace has no config root yet; setup does not create one. *)
  | Inventory_unreadable of { directory : string }
  | Declared_more_than_once of string list
      (** Several enabled declarations name the browser package; the server
          would attach them all and refuse every host poll as ambiguous.
          Disabled declarations are not counted, as the server does not
          attach them. *)
  | Declaration_unloadable of { path : string; reason : string }
      (** [browser.toml], or a declaration with the id [browser], does not
          load even with the package in place. It is left as it is. *)
  | Declaration_refused of string

val error_message : error -> string

val package_directory : base_path:string -> string
(** [<base>/.masc/packages/browser]. *)

type plan

val plan : base_path:string -> (plan, error) result
(** Read what [apply] needs and refuse, before any write, a relative
    [base_path], an invalid or missing config root, an unreadable Lane
    directory, more than one enabled declaration of the browser package and an
    embedded package that lists a file without bytes. Nothing is written. *)

val apply : plan -> (installed, error) result
(** Write the package, then read the Lane directory again and declare the
    package when no declaration of it loads. The declaration is created only
    if the file is still absent, through the same writer as the dashboard
    editor. Refusals here come after the package was written:
    [Package_unwritable], [Package_unloadable], [Embedded_package_invalid] for
    a manifest id other than [browser], [Inventory_unreadable],
    [Declared_more_than_once], [Declaration_unloadable] and
    [Declaration_refused]. *)
