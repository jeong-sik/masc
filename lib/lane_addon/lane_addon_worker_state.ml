type owner = { workspace : string; installation : string; package : string }

let create_owner ~workspace_root ~installation_id ~package_id =
  if String.trim installation_id = "" || String.trim package_id = "" then
    Error "persistent state requires installation and package identities"
  else
    try Ok { workspace = Unix.realpath workspace_root;
             installation = installation_id; package = package_id }
    with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)

let belongs_to owner ~package_id = String.equal owner.package package_id

let identity owner =
  Yojson.Safe.to_string (`List [ `String owner.workspace;
    `String owner.installation; `String owner.package ])

let volume_name ?(runtime = Lane_addon_types.Docker) owner =
  match runtime with
  | Lane_addon_types.Docker ->
      "masc-lane-state-" ^ Agent_core_sha256.(to_hex (digest_string (identity owner)))
  | Apple_container -> Agent_core_sha256.(to_hex (digest_string ("volume:" ^ identity owner)))

(* The engine reserves the container name before start. All writers
   of one logical volume use this slot; worker incarnations still have distinct
   labels so a losing attach cannot remove the winning worker. *)
let container_name ?(runtime = Lane_addon_types.Docker) owner =
  match runtime with
  | Lane_addon_types.Docker -> volume_name owner ^ "-writer"
  | Apple_container -> Agent_core_sha256.(to_hex (digest_string ("writer:" ^ identity owner)))

(* The writer name a state owner label stands for, recomputed from the label's
   own text. A container whose name this does not explain was not named for
   its labels. *)
let container_name_of_identity ?(runtime = Lane_addon_types.Docker) text =
  match Yojson.Safe.from_string text with
  | `List [`String workspace; `String installation; `String package] ->
      Ok (container_name ~runtime { workspace; installation; package })
  | _ -> Error "state owner label is not an installation identity"
  | exception Yojson.Json_error detail -> Error ("state owner label is not JSON: " ^ detail)

let label = Lane_addon_engine.state_owner_label
open Result.Syntax

let inspect ~runtime ~run owner =
  let name = volume_name ~runtime owner in
  let* raw = run ~operation:"inspect persistent state" ["volume"; "inspect"; name] in
  Lane_addon_engine.verify_volume runtime ~name ~owner:(identity owner) raw

let ensure ?(runtime = Lane_addon_types.Docker) ~run owner =
  let name = volume_name ~runtime owner in
  let* raw = run ~operation:"find persistent state"
      (Lane_addon_engine.volume_list_arguments runtime name) in
  let* exists = Lane_addon_engine.listed_volume runtime ~name raw in
  let* () =
    if not exists then
      let* _ = run ~operation:"create persistent state"
          ["volume"; "create"; "--label"; label ^ "=" ^ identity owner; name] in
      Ok ()
    else Ok ()
  in
  (* Create may race with another owner. Neither its exit status nor a
     deterministic name grants ownership; inspect before granting a mount. *)
  let* () = inspect ~runtime ~run owner in
  Ok (Lane_addon_engine.state_mount runtime name)
