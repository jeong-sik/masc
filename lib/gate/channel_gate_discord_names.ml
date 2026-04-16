(** Discord name_map side-store.

    Names (guild/channel id -> human-readable names) are cosmetic data
    owned by the sidecar: the bot enumerates guilds/channels every
    heartbeat and atomically writes {!names_write_path}. Bindings are
    immutable authority records; names can be renamed at any time. The
    two concerns have separate lifecycles, so they live in separate
    files. *)

module U = Yojson.Safe.Util

type name_map = {
  guild_names : (string * string) list;
  channel_names : (string * string) list;
  channel_to_guild : (string * string) list;
  updated_at : string;
}

let default_names_path = ".gate/runtime/discord/names.json"
(* Legacy path from the pre-v0.9.0 layout. Read-fallback still honours it so
   that operators who have data there see a transparent migration on the next
   write. `sidecars/discord-bot/.gate/discord_names.json` (even older layout)
   is no longer auto-discovered; set MASC_DISCORD_NAMES_PATH if still in use. *)
let legacy_names_path = ".masc/connectors/discord/names.json"

let resolve_path raw_path =
  if Filename.is_relative raw_path then
    Filename.concat (Env_config_core.base_path ()) raw_path
  else
    raw_path

let configured_write_path env_name ~default =
  match Sys.getenv_opt env_name |> Env_config_core.trim_opt with
  | Some raw -> resolve_path raw
  | None -> resolve_path default

let configured_read_path env_name ~default ~legacy =
  match Sys.getenv_opt env_name |> Env_config_core.trim_opt with
  | Some raw -> resolve_path raw
  | None ->
      let preferred = resolve_path default in
      let legacy = resolve_path legacy in
      if Sys.file_exists preferred then preferred
      else if Sys.file_exists legacy then legacy
      else preferred

let names_write_path () =
  configured_write_path "MASC_DISCORD_NAMES_PATH" ~default:default_names_path

let names_read_path () =
  configured_read_path "MASC_DISCORD_NAMES_PATH"
    ~default:default_names_path ~legacy:legacy_names_path

let read_json_file_opt path =
  try Some (Yojson.Safe.from_file path) with
  | _ -> None

let string_member json key =
  match json |> U.member key with
  | `String s -> s
  | _ -> ""

let string_assoc_of_member key json =
  match json |> U.member key with
  | `Assoc items ->
      List.filter_map (fun (k, v) ->
        match v with
        | `String s -> Some (k, s)
        | _ -> None)
        items
  | _ -> []

let empty =
  {
    guild_names = [];
    channel_names = [];
    channel_to_guild = [];
    updated_at = "";
  }

let read () =
  match read_json_file_opt (names_read_path ()) with
  | None -> empty
  | Some json ->
      {
        guild_names = string_assoc_of_member "guild_names" json;
        channel_names = string_assoc_of_member "channel_names" json;
        channel_to_guild = string_assoc_of_member "channel_to_guild" json;
        updated_at = string_member json "updated_at";
      }

let to_json nm =
  let to_assoc items =
    `Assoc (List.map (fun (k, v) -> (k, `String v)) items)
  in
  `Assoc
    [
      ("guild_names", to_assoc nm.guild_names);
      ("channel_names", to_assoc nm.channel_names);
      ("channel_to_guild", to_assoc nm.channel_to_guild);
      ("updated_at", `String nm.updated_at);
    ]

let save nm =
  let path = names_write_path () in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        (Yojson.Safe.pretty_to_string (to_json nm) ^ "\n"));
  Sys.rename tmp path

let resolve_guild_id_for_channel ~channel_id =
  let channel_id = String.trim channel_id in
  if channel_id = "" then None
  else
    let nm = read () in
    List.assoc_opt channel_id nm.channel_to_guild
