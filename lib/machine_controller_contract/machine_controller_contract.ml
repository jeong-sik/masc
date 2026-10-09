type holder_departure =
  | Keeper_stopped
  | Credential_expired
  | No_credential

type admission = {
  observed_holder : string option;
  release : holder_departure option;
  handoff_target : string option;
}
let snapshot_tool = "lane_controller_snapshot"
let release_tool = "lane_controller_release"
let nullable_name = function None -> `Null | Some name -> `String name
let admission_to_json admission =
  `Assoc ["observed_holder", nullable_name admission.observed_holder;
    "release", (match admission.release with
      | None -> `Null | Some Keeper_stopped -> `String "keeper_stopped"
      | Some Credential_expired -> `String "credential_expired"
      | Some No_credential -> `String "no_credential");
    "handoff_target", nullable_name admission.handoff_target]
let ( let* ) = Result.bind
let name = function
  | `Null -> Ok None
  | `String name when name <> "" && String.equal name (String.trim name) -> Ok (Some name)
  | _ -> Error "invalid controller name"
let admission_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["handoff_target"; "observed_holder"; "release"] ->
      let* observed_holder = name (List.assoc "observed_holder" fields) in
      let* handoff_target = name (List.assoc "handoff_target" fields) in
      let* release = match List.assoc "release" fields with
        | `Null -> Ok None
        | `String "keeper_stopped" -> Ok (Some Keeper_stopped)
        | `String "credential_expired" -> Ok (Some Credential_expired)
        | `String "no_credential" -> Ok (Some No_credential)
        | _ -> Error "invalid controller departure" in
      if release <> None && observed_holder = None then
        Error "controller release requires an observed holder"
      else Ok { observed_holder; release; handoff_target }
  | _ -> Error "invalid or duplicate controller admission fields"
let admission_schema = `Assoc [
  "type", `String "object"; "additionalProperties", `Bool false;
  "required", `List (List.map (fun s -> `String s)
    ["observed_holder"; "release"; "handoff_target"]);
  "properties", `Assoc [
    "observed_holder", `Assoc ["type", `List [`String "string"; `String "null"]];
    "handoff_target", `Assoc ["type", `List [`String "string"; `String "null"]];
    "release", `Assoc ["enum", `List [`Null; `String "keeper_stopped";
      `String "credential_expired"; `String "no_credential"]]]]
