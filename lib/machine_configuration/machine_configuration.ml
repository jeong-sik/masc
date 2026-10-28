type t = { msx_enabled : bool; dos_enabled : bool }
[@@deriving show, eq]
type activity = Enabled | Disabled | Unobserved
let default = { msx_enabled = true; dos_enabled = true }
let activity_to_wire = function Enabled -> "on" | Disabled -> "off" | Unobserved -> "unobserved"
open Result.Syntax
let table ~path ~keys = function
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    (match List.find_opt (fun (key, _) -> not (List.mem key keys)) entries with
     | None -> Ok entries
     | Some (key, _) -> Error (path ^ "." ^ key ^ " is not a supported setting"))
  | Some
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    Error (path ^ " must be a TOML table")
let enabled ~path value =
  let* entries = table ~path ~keys:["enabled"] value in
  match List.assoc_opt "enabled" entries with
  | None -> Ok true
  | Some (Otoml.TomlBoolean enabled) -> Ok enabled
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
  | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
  | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) -> Error (path ^ ".enabled must be a boolean")
let parse toml =
  let path = Runtime_toml_namespace.(key Machines) in
  let* entries = table ~path ~keys:["msx"; "dos"] (Otoml.find_opt toml Fun.id [path]) in
  let* msx_enabled = enabled ~path:(path ^ ".msx") (List.assoc_opt "msx" entries) in
  let* dos_enabled = enabled ~path:(path ^ ".dos") (List.assoc_opt "dos" entries) in
  Ok { msx_enabled; dos_enabled }
