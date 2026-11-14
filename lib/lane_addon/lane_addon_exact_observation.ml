open Result.Syntax
module Observation = Exact_lane_slot_observation
let instance_id declaration_id =
  Yojson.Safe.to_string (`List [`String "exact-slot-observations";`String declaration_id])
let directory ~declaration_id = Lane_addon_store.host_result_directory ~instance_id:(instance_id declaration_id)
let store_root_field="store_root"
let store_root = function
  | `Assoc fields -> (match List.assoc_opt store_root_field fields with
      | Some (`String root) -> Some root
      | Some _ | None -> None)
  | _ -> None
let identity_for_digest ~store ~declaration_id ~request_id ~attempt_ordinal ~proof_digest =
  let instance_id=instance_id declaration_id in
  let key=Yojson.Safe.to_string (`List [`String request_id;`Int attempt_ordinal;`String proof_digest]) in
  let fields=["version",`Int 1;store_root_field,`String (Lane_addon_store.root store);
    "declaration_id",`String declaration_id;"request_id",`String request_id;
    "attempt_ordinal",`Int attempt_ordinal;"proof_sha256",`String proof_digest] in
  Ok (instance_id,key,fields)
let identity ~store ~declaration_id ~request_id ~attempt_ordinal ~proof =
  let* proof=Lane_addon_action.canonical proof in
  let proof_digest=Lane_addon_store.digest (Yojson.Safe.to_string proof) in
  identity_for_digest ~store ~declaration_id ~request_id ~attempt_ordinal ~proof_digest
let json fields observations =
  `Assoc (fields @ ["observations",`List (List.map Observation.to_yojson observations)])
let request_id ~store ~declaration_id ~file_name raw =
  let* fields=match raw with `Assoc fields -> Ok fields | _ -> Error "slot companion object required" in
  let text name=match List.assoc_opt name fields with
    | Some (`String value) when String.trim value<>"" -> Ok value
    | Some _ | None -> Error ("invalid slot companion "^name) in
  let* request_id=text "request_id" in
  let* proof_digest=text "proof_sha256" in
  let* attempt_ordinal=match List.assoc_opt "attempt_ordinal" fields with
    | Some (`Int ordinal) when ordinal>0 -> Ok ordinal
    | Some _ | None -> Error "invalid slot companion ordinal" in
  let* observations=Option.to_result ~none:"missing slot observations" (List.assoc_opt "observations" fields) in
  let* instance_id,key,expected=identity_for_digest ~store ~declaration_id ~request_id ~attempt_ordinal ~proof_digest in
  let* expected=Lane_addon_action.canonical (`Assoc (expected@["observations",observations])) in
  let* actual=Lane_addon_action.canonical raw in
  if Yojson.Safe.equal actual expected
     && file_name=Filename.basename (Lane_addon_store.host_result_path ~instance_id ~request_id:key)
  then Ok request_id else Error "slot companion does not own this file"
let read ~store ~declaration_id ~request_id ~attempt_ordinal ~proof =
  let* instance_id,request_id,fields=identity ~store ~declaration_id ~request_id ~attempt_ordinal ~proof in
  let* retained=Lane_addon_store.load_host_result store ~instance_id ~request_id in
  match retained with
  | None -> Ok None
  | Some raw ->
    let* values=match raw with
      | `Assoc fields -> (match List.assoc_opt "observations" fields with
          | Some (`List values) -> Ok values
          | Some _ | None -> Error "missing original slot observations")
      | _ -> Error "original slot observations must be an object" in
    let rec decode acc = function
      | [] -> Ok (List.rev acc)
      | value::rest -> let* value=Observation.of_yojson value in decode (value::acc) rest in
    let* observations=decode [] values in
    let* expected=Lane_addon_action.canonical (json fields observations) in
    let* actual=Lane_addon_action.canonical raw in
    if Yojson.Safe.equal actual expected then Ok (Some observations)
    else Error "original slot observations have conflicting proof identity"
let retain ~store ~declaration_id ~request_id ~attempt_ordinal ~proof observations =
  let* instance_id,key,fields=identity ~store ~declaration_id ~request_id ~attempt_ordinal ~proof in
  let* previous=read ~store ~declaration_id ~request_id ~attempt_ordinal ~proof in
  let* ()=match previous with
    | None -> Lane_addon_store.save_host_result store ~instance_id ~request_id:key (json fields observations)
    | Some previous -> if List.map Observation.to_yojson previous=List.map Observation.to_yojson observations
      then Ok () else Error "conflicting original slot observations" in
  let* confirmed=read ~store ~declaration_id ~request_id ~attempt_ordinal ~proof in
  if confirmed=Some observations then Ok () else Error "original slot observations were not confirmed"
