type entry = {
  key : string;
  value : string;
  contract_revision : string;
}

type error =
  | Invalid_json of string
  | Read_failed of string
  | Write_failed of string
  | Expected_object of string
  | Expected_list of string
  | Expected_integer of string
  | Expected_string of string
  | Duplicate_field of {
      location : string;
      field : string;
    }
  | Missing_field of {
      location : string;
      field : string;
    }
  | Unexpected_field of {
      location : string;
      field : string;
    }
  | Unsupported_schema_version of {
      expected : int;
      actual : int;
    }
  | Duplicate_override_key of string

let schema_version = 1

let error_to_string = function
  | Invalid_json message -> "invalid JSON: " ^ message
  | Read_failed message -> "read failed: " ^ message
  | Write_failed message -> "atomic write failed: " ^ message
  | Expected_object location -> location ^ " must be a JSON object"
  | Expected_list location -> location ^ " must be a JSON array"
  | Expected_integer location -> location ^ " must be an integer"
  | Expected_string location -> location ^ " must be a string"
  | Duplicate_field { location; field } ->
      Printf.sprintf "%s contains duplicate field %S" location field
  | Missing_field { location; field } ->
      Printf.sprintf "%s is missing required field %S" location field
  | Unexpected_field { location; field } ->
      Printf.sprintf "%s contains unsupported field %S" location field
  | Unsupported_schema_version { expected; actual } ->
      Printf.sprintf "unsupported schema_version %d (expected %d)" actual expected
  | Duplicate_override_key key ->
      Printf.sprintf "overrides contains duplicate key %S" key

module String_set = Set.Make (String)

let duplicate_field fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
        if String_set.mem field seen then Some field
        else loop (String_set.add field seen) rest
  in
  loop String_set.empty fields

let strict_object ~location ~fields json =
  match json with
  | `Assoc values -> (
      match duplicate_field values with
      | Some field -> Error (Duplicate_field { location; field })
      | None -> (
          match
            List.find_opt
              (fun (field, _) -> not (List.mem field fields))
              values
          with
          | Some (field, _) -> Error (Unexpected_field { location; field })
          | None -> (
              match
                List.find_opt
                  (fun field -> not (List.mem_assoc field values))
                  fields
              with
              | Some field -> Error (Missing_field { location; field })
              | None -> Ok values)))
  | _ -> Error (Expected_object location)

let string_field ~location field values =
  match List.assoc field values with
  | `String value -> Ok value
  | _ -> Error (Expected_string (location ^ "." ^ field))

let decode_entry index json =
  let location = Printf.sprintf "overrides[%d]" index in
  match
    strict_object ~location
      ~fields:[ "key"; "value"; "contract_revision" ]
      json
  with
  | Error _ as error -> error
  | Ok fields -> (
      match string_field ~location "key" fields with
      | Error _ as error -> error
      | Ok key -> (
          match string_field ~location "value" fields with
          | Error _ as error -> error
          | Ok value -> (
              match string_field ~location "contract_revision" fields with
              | Error _ as error -> error
              | Ok contract_revision -> Ok { key; value; contract_revision })))

let decode json =
  match
    strict_object ~location:"top-level"
      ~fields:[ "schema_version"; "overrides" ]
      json
  with
  | Error _ as error -> error
  | Ok fields -> (
      match List.assoc "schema_version" fields with
      | `Int actual when actual <> schema_version ->
          Error
            (Unsupported_schema_version
               { expected = schema_version; actual })
      | `Int _ -> (
          match List.assoc "overrides" fields with
          | `List items ->
              let rec loop index seen acc = function
                | [] -> Ok (List.rev acc)
                | item :: rest -> (
                    match decode_entry index item with
                    | Error _ as error -> error
                    | Ok entry ->
                        if String_set.mem entry.key seen then
                          Error (Duplicate_override_key entry.key)
                        else
                          loop (index + 1)
                            (String_set.add entry.key seen)
                            (entry :: acc) rest)
              in
              loop 0 String_set.empty [] items
          | _ -> Error (Expected_list "top-level.overrides"))
      | _ -> Error (Expected_integer "top-level.schema_version"))

let contract_revision ~body ~template_variables =
  let template_variables = List.sort String.compare template_variables in
  let canonical =
    `Assoc
      [
        ("body", `String body);
        ( "template_variables",
          `List (List.map (fun variable -> `String variable) template_variables)
        );
      ]
    |> Yojson.Safe.to_string
  in
  Digestif.SHA256.(digest_string canonical |> to_hex)

let entry_to_yojson entry =
  `Assoc
    [
      ("key", `String entry.key);
      ("value", `String entry.value);
      ("contract_revision", `String entry.contract_revision);
    ]

let encode entries =
  let entries = List.sort (fun left right -> String.compare left.key right.key) entries in
  let rec reject_duplicate previous = function
    | [] -> Ok ()
    | entry :: rest -> (
        match previous with
        | Some key when String.equal key entry.key ->
            Error (Duplicate_override_key entry.key)
        | None | Some _ -> reject_duplicate (Some entry.key) rest)
  in
  match reject_duplicate None entries with
  | Error _ as error -> error
  | Ok () ->
      Ok
        (`Assoc
          [
            ("schema_version", `Int schema_version);
            ("overrides", `List (List.map entry_to_yojson entries));
          ])

let load ~path =
  try
    let content = In_channel.with_open_text path In_channel.input_all in
    try Yojson.Safe.from_string content |> decode
    with Yojson.Json_error message -> Error (Invalid_json message)
  with
  | Sys_error message -> Error (Read_failed message)
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Read_failed
           (Printf.sprintf "%s(%s): %s" operation argument
              (Unix.error_message error)))

let save ~path entries =
  match encode entries with
  | Error _ as error -> error
  | Ok json ->
      let content = Yojson.Safe.pretty_to_string json ^ "\n" in
      (try
         match Fs_compat.save_file_atomic path content with
         | Ok () -> Ok ()
         | Error message -> Error (Write_failed message)
       with
       | Sys_error message -> Error (Write_failed message)
       | Unix.Unix_error (error, operation, argument) ->
           Error
             (Write_failed
                (Printf.sprintf "%s(%s): %s" operation argument
                   (Unix.error_message error))))
