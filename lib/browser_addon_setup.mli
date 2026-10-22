(** Declare the browser Lane Add-on for a workspace, from the package this
    build carries.

    Since the browser Add-on owns every browser route, a native browser
    host's polls, results and disconnects go to an attached browser Add-on,
    and a workspace without one has no browser. {!apply} does the two steps
    that used to be by hand:

    - It writes the package this binary was built with to
      [<base>/.masc/packages/browser/]. A later {!apply} from an upgraded
      build rewrites the files there, so the declaration that names them does
      not change.
    - When no declaration of that package exists in the workspace's Lane
      directory, it creates [browser.toml] there. An existing declaration of
      the package is left as it is, whatever package path it names.

    It never attaches or starts anything. The server reads declarations at
    start and on its maintenance pass. *)

type declaration =
  | Created of { path : string }
  | Present of { path : string; manifest_path : string; this_build : bool }
      (** A declaration of the browser package already existed. [this_build]
          is whether its [manifest_path] is the package {!apply} wrote. *)

type installed =
  { package_directory : string
  ; files_written : int  (** 0 when every file already held these bytes. *)
  ; declaration : declaration
  ; missing_programs : string list
        (** Programs the browser Add-on runs that are neither beside this MASC
            nor on this process's [PATH]: its worker command and every
            {!Native_addon_program.t}. The server looks the same way with its
            own [PATH], so the answer can differ for a server started with
            another environment. *)
  }

type error =
  | Base_path_not_absolute of string
  | Embedded_package_invalid of string
  | Package_unwritable of { path : string; reason : string }
  | Package_unloadable of { path : string; reason : string }
      (** The written manifest does not load with this build. *)
  | Config_root_invalid of string
  | Inventory_unreadable of { directory : string }
  | Declared_more_than_once of string list
      (** Several declarations name the browser package; the server would
          attach both and refuse every host poll as ambiguous. *)
  | Declaration_refused of string

val error_message : error -> string

val package_directory : base_path:string -> string
(** [<base>/.masc/packages/browser]. *)

type plan

val plan : base_path:string -> (plan, error) result
(** Read what [apply] needs and refuse what can be refused before a write: a
    relative [base_path], an unusable embedded package, an invalid config
    root, an unreadable Lane directory and more than one declaration of the
    browser package. Nothing is written. *)

val apply : plan -> (installed, error) result
(** Write the package, then declare it when [plan] found no declaration of
    it. The declaration is created only if the file is still absent, through
    the same writer as the dashboard editor. *)
