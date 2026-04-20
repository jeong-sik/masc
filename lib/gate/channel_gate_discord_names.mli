(** Discord name_map side-store.

    Names (guild/channel id → human-readable names) are cosmetic
    data owned by the sidecar: the bot enumerates guilds/channels
    every heartbeat and atomically writes {!names_write_path}.
    Bindings are immutable authority records; names can be renamed
    at any time. The two concerns have separate lifecycles, so
    they live in separate files. *)

(** {1 Types} *)

type name_map = {
  guild_names : (string * string) list;
  channel_names : (string * string) list;
  channel_to_guild : (string * string) list;
  updated_at : string;
}

(** {1 Path configuration} *)

val default_names_path : string

(** [configured_write_path env_name ~default] — env override
    resolved against [Env_config_core.base_path ()] when relative. *)
val configured_write_path : string -> default:string -> string

(** [configured_read_path env_name ~default ~legacy] — env override,
    else [default], else [legacy] fallback (for pre-v0.9.0 layout). *)
val configured_read_path :
  string -> default:string -> legacy:string -> string

(** Default write path (env [MASC_DISCORD_NAMES_PATH] →
    {!default_names_path}). *)
val names_write_path : unit -> string

(** Default read path with pre-v0.9.0 legacy fallback. *)
val names_read_path : unit -> string

(** {1 State I/O} *)

(** Empty [name_map] with [updated_at = ""]. *)
val empty : name_map

(** Read {!names_read_path}. Missing file or malformed JSON returns
    {!empty}. *)
val read : unit -> name_map

val save : name_map -> unit

val to_json : name_map -> Yojson.Safe.t

(** {1 Lookups} *)

(** Return the guild id that owns [channel_id], using the cached
    [channel_to_guild] map from {!read}. [None] when [channel_id]
    is empty/whitespace or unknown. *)
val resolve_guild_id_for_channel :
  channel_id:string -> string option
