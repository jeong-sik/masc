type platform = { architecture : string; os : string; variant : string option }
type identity = { descriptor_digest : string; platform : platform }
type t = { reference : string; identity : identity; entrypoint : string list }
type error =
  | Invalid_inspect of string
  | Reference_mismatch
  | Descriptor_mismatch
  | Platform_absent
  | Platform_ambiguous

let error_message = function
  | Invalid_inspect field -> "image inspect has invalid or missing " ^ field
  | Reference_mismatch -> "image inspect belongs to another requested reference"
  | Descriptor_mismatch -> "image inspect descriptor differs from the guest image"
  | Platform_absent -> "image inspect has no configuration for the guest platform"
  | Platform_ambiguous -> "image inspect has multiple configurations for the guest platform"

let command t ~arguments = t.entrypoint @ arguments

let validate_binding t ~reference ~identity =
  if t.reference <> reference then Error Reference_mismatch
  else if t.identity.descriptor_digest <> identity.descriptor_digest then Error Descriptor_mismatch
  else if t.identity.platform <> identity.platform then Error Platform_absent
  else Ok ()

let of_apple_inspect ~reference ~(identity : identity) raw =
  let open Result.Syntax in
  let invalid field = Error (Invalid_inspect field) in
  let object_fields field = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields else invalid (field ^ " duplicate keys")
    | _ -> invalid field in
  let member key fields = match List.assoc_opt key fields with
    | Some value -> Ok value | None -> invalid key in
  let nonempty field = function
    | `String value when value <> "" && not (String.contains value '\000') -> Ok value
    | _ -> invalid field in
  let text key fields = let* value = member key fields in nonempty key value in
  let object_member key fields = let* value = member key fields in object_fields key value in
  let optional_variant fields = match List.assoc_opt "variant" fields with
    | None | Some `Null -> Ok None
    | Some value -> Result.map Option.some (nonempty "variant" value) in
  let platform value =
    let* fields = object_fields "platform" value in
    let* architecture = text "architecture" fields in
    let* os = text "os" fields in
    let* variant = optional_variant fields in
    Ok {architecture; os; variant} in
  let entrypoint fields = match List.assoc_opt "Entrypoint" fields with
    | None | Some `Null -> Ok []
    | Some (`List values) ->
      let* values = List.fold_right (fun value result ->
        let* rest = result in
        match value with
        | `String value when not (String.contains value '\000') -> Ok (value :: rest)
        | _ -> invalid "Entrypoint argv") values (Ok []) in
      (match values with "" :: _ -> invalid "Entrypoint executable" | [] | _ :: _ -> Ok values)
    | Some _ -> invalid "Entrypoint" in
  let decode json =
    let* row = match json with
      | `List [row] -> object_fields "image row" row
      | _ -> invalid "image row count" in
    let* configuration = object_member "configuration" row in
    let* _canonical_name = text "name" configuration in
    let* descriptor = object_member "descriptor" configuration in
    let* digest = text "digest" descriptor in
    let* () = if digest = identity.descriptor_digest then Ok () else Error Descriptor_mismatch in
    let* id = text "id" row in
    let* () = match String.split_on_char ':' digest with
      | [algorithm; encoded] when algorithm <> "" && encoded <> "" && id = encoded -> Ok ()
      | _ -> invalid "image row identity" in
    let* variants = member "variants" row in
    let* variants = match variants with
      | `List values -> List.fold_right (fun value result ->
          let* rest = result in
          let* fields = object_fields "image variant" value in
          let* value = member "platform" fields in
          let* observed = platform value in
          Ok ((observed, fields) :: rest)) values (Ok [])
      | _ -> invalid "variants" in
    let matching = List.filter (fun (observed, _) -> observed = identity.platform) variants in
    let* selected = match matching with
      | [] -> Error Platform_absent
      | [(_, fields)] -> Ok fields
      | _ :: _ -> Error Platform_ambiguous in
    let* image_config = object_member "config" selected in
    let* architecture = text "architecture" image_config in
    let* os = text "os" image_config in
    let* variant = optional_variant image_config in
    let* () =
      if architecture <> identity.platform.architecture || os <> identity.platform.os
         || (match variant with None -> false | Some _ -> variant <> identity.platform.variant)
      then invalid "variant config platform" else Ok () in
    let* entrypoint = match List.assoc_opt "config" image_config with
      | None | Some `Null -> Ok []
      | Some value -> let* fields = object_fields "execution config" value in entrypoint fields in
    Ok {reference; identity; entrypoint}
  in
  match Yojson.Safe.from_string raw with
  | json -> decode json
  | exception Yojson.Json_error _ -> invalid "JSON"
