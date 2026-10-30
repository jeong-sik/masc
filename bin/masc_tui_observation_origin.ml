type instance = { id : string; client_version : string }
let create_instance ~id ~client_version = {id;client_version}
type t = { instance_id : string; payload : Yojson.Safe.t }
let capture instance ~expected_workspace : t =
  let server=expected_workspace in
  {instance_id=instance.id;payload=`Assoc [
    "tui_instance_id",`String instance.id;
    "client",`Assoc ["reported_version",`String instance.client_version];
    "workspace",`Assoc ["base_path",`String (Masc.Tui_decode.Canonical_path.to_string server.Masc.Tui_decode.sid_base_path);
      "masc_root",`String (Masc.Tui_decode.Canonical_path.to_string server.sid_masc_root)];
    "server_identity_at_admission",`Assoc ["reported_version",`String server.sid_version;
      "reported_binary_commit",`String server.sid_binary_commit]]}
let instance_id t = t.instance_id
let to_json t = t.payload
