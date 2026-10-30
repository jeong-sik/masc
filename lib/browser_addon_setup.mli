(** Declare the browser Lane Add-ons for a workspace, one per browser source,
    from the packages this build carries.

    Each browser source has its own package and worker (RFC
    browser-backends-end-alone): [browser-automation], [browser-stagehand],
    [browser-firefox], [browser-ego] and [browser-external]. For each source it
    is given, {!apply} does the two steps that used to be by hand:

    - It writes the package this binary was built with to
      [<base>/.masc/packages/browser-<source>/] and removes the files there
      that this build does not carry. A later {!apply} from an upgraded build
      rewrites the files, so the declaration that names them does not change.
    - When no declaration of that source exists in the workspace's Lane
      directory, it creates [browser-<source>.toml] there. An existing
      declaration of the source is left as it is, whatever package path it
      names.

    It never attaches or starts anything. The server reads declarations at
    start and on its maintenance pass. An instance attached by hand without a
    declaration is not seen here; with it and a declaration attached, the
    server uses neither for that source. *)

type declaration =
  | Created of { path : string }
  | Present of { path : string; manifest_path : string; this_build : bool; enabled : bool }
      (** A declaration of the browser package already existed. [this_build]
          is whether its [manifest_path] is the package {!apply} wrote;
          [enabled] is its desired activity. *)

type installed =
  { backend : Browser_lane.Backend.t  (** The source this package serves. *)
  ; package_directory : string
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
  | Declared_more_than_once of { backend : Browser_lane.Backend.t; paths : string list }
      (** Several enabled declarations serve [backend]; the server would
          attach them all and use none of them for it. Disabled declarations
          are not counted, as the server does not attach them. *)
  | Declaration_unloadable of { path : string; reason : string }
      (** [browser-<source>.toml], or a declaration with that package's id,
          does not load even with the package in place. It is left as it is. *)
  | Declaration_refused of string

val error_message : error -> string

val package_name : Browser_lane.Backend.t -> string
(** [browser-<source>]: the package id, declaration id and folder name. *)

val package_directory : base_path:string -> Browser_lane.Backend.t -> string
(** [<base>/.masc/packages/browser-<source>]. *)

type plan

val plan : base_path:string -> sources:Browser_lane.Backend.t list -> (plan, error) result
(** Read what [apply] needs for each of [sources] and refuse, before any
    write, a relative [base_path], an invalid or missing config root, an
    unreadable Lane directory, more than one enabled declaration of one of
    [sources] and an embedded package that lists a file without bytes.
    Nothing is written. *)

(** What {!apply} completed: the packages written and declared, in source
    order, and the refusal that stopped it, if any. *)
type applied = { installed : installed list; refusal : error option }

val apply : plan -> applied
(** For each source in turn, write its package, then read the Lane directory
    again and declare it when no declaration of the source loads. The
    declaration is created only if the file is still absent, through the
    same writer as the dashboard editor. A refusal stops there and leaves the
    packages before it written and declared, which [installed] lists.
    Refusals here come after the refused source's package was written: [Package_unwritable], [Package_unloadable],
    [Embedded_package_invalid] for a manifest that is not the source's
    package, [Inventory_unreadable], [Declared_more_than_once],
    [Declaration_unloadable] and [Declaration_refused]. *)

(** [plan] without the packages of [sources]: setup leaves out a source
    whose table this run was to write and did not, since its worker fails
    without that table. *)
val without : Browser_lane.Backend.t list -> plan -> plan
