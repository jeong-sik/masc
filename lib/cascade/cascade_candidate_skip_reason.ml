(** Routing-affecting pre-dispatch skip reasons. *)

type t =
  | Required_tool_unsupported of { missing : string list }

let to_manifest_tag = function
  | Required_tool_unsupported _ -> "required_tool_unsupported"

let to_yojson ~candidate reason =
  match reason with
  | Required_tool_unsupported { missing } ->
    `Assoc
      [
        ("kind", `String (to_manifest_tag reason));
        ("candidate", `String candidate);
        ("missing", Json_util.json_string_list missing);
      ]
