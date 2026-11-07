(** The [\[browser\]] table of [runtime.toml]. No process is started and no
    file is read while parsing.

    [live_ego] ([\[browser.live.ego\]], RFC-browser-live-ego §7): the ego
    lite task space the browser Add-on serves as a live connection.
    [command] is the absolute path of [ego-browser]; [space] is a name to
    create/resume, or an existing numeric Space ID to resume exactly.
    Both are required. Neither grants takeover or claim authority. *)

type ego_space = Named_space of string | Existing_space of int
[@@deriving show, eq]
val validate_ego_space : ego_space -> (unit, string) result
(** Nonblank names and nonnegative JavaScript-safe IDs only. A numeric-looking
    string remains a name; only a TOML integer selects an existing Space. *)
type live_ego = { command : string; space : ego_space }
[@@deriving show, eq]
type t = {
  live_ego : live_ego option;
}
[@@deriving show, eq]

(** How each source starts, never whether it runs: a source runs while its
    Lane Add-on declaration is switched on. *)

(** No backend configured. *)
val none : t

val parse : Otoml.t -> (t, string) result

(** {!parse} of the runtime.toml at [path], for a reader with no runtime
    configuration loaded, such as [masc doctor]. [Error] says why the file
    cannot be read or its tables do not parse. *)
val of_file : string -> (t, string) result

val of_text : string -> (t, string) result
(** {!of_file} of a runtime.toml text, for one read from the workspace's
    running server. *)

(** A source that starts from a runtime.toml table, with what that table
    parses to. *)
type _ source =
  | Live_ego : live_ego source

(** Where runtime.toml writes [source]'s table. *)
val source_path : _ source -> string

(** [source]'s table as parsed, [None] when runtime.toml has none. *)
val source_table : 'a source -> t -> 'a option
