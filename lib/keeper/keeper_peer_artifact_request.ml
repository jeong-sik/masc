open Result.Syntax

type t =
  | Export of { path : string }
  | Materialize of {
      path : string;
      artifact : Keeper_peer_artifact_ref.t;
    }

let relative_path path =
  path <> ""
  && Filename.is_relative path
  && List.for_all
       (fun part -> part <> ".." && part <> "" && part <> ".")
       (String.split_on_char '/' path)
;;

let of_json = function
  | `Assoc fields -> (
      match List.assoc_opt "path" fields with
      | Some (`String path) when relative_path path -> (
          match List.assoc_opt "action" fields with
          | Some (`String "export") -> (
              match List.assoc_opt "artifact" fields with
              | None -> Ok (Export { path })
              | Some _ -> Error "Export takes a path and no artifact")
          | Some (`String "materialize") -> (
              match List.assoc_opt "artifact" fields with
              | Some json ->
                let* artifact = Keeper_peer_artifact_ref.of_json json in
                Ok (Materialize { path; artifact })
              | None -> Error "Materialize requires an artifact")
          | _ -> Error "action must be export or materialize")
      | _ -> Error "path must be a nonempty relative sandbox path")
  | _ -> Error "Artifact request must be an object"
;;
