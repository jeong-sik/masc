type source = { content : string; sha256 : string }
type keeper = { name : string; declaration : source }
type origin = { base_path : string; config_root : string }
type t =
  { origin : origin
  ; runtime : source option
  ; overrides : source option
  ; keepers : keeper list
  }

type document = Runtime | Overrides | Keeper of string
type error =
  | Invalid_json of string
  | Invalid_envelope of string
  | Unsupported_version of int
  | Invalid_keeper_name of string
  | Duplicate_keeper of string
  | Invalid_document of { document : document; detail : string }
  | Digest_mismatch of document

let ( let* ) = Result.bind
module Names = Set.Make (String)
let schema_version = 1
let digest content = Agent_core_sha256.(digest_string content |> to_hex)
let source content = { content; sha256 = digest content }

let document_to_string = function
  | Runtime -> "runtime"
  | Overrides -> "prompt overrides"
  | Keeper name -> "keeper " ^ name

let error_to_string = function
  | Invalid_json detail -> "invalid world bundle JSON: " ^ detail
  | Invalid_envelope detail -> "invalid world bundle: " ^ detail
  | Unsupported_version version ->
    Printf.sprintf "unsupported world bundle version: %d" version
  | Invalid_keeper_name name -> "invalid world Keeper name: " ^ name
  | Duplicate_keeper name -> "duplicate world Keeper: " ^ name
  | Invalid_document { document; detail } -> document_to_string document ^ ": " ^ detail
  | Digest_mismatch document -> document_to_string document ^ ": source digest differs"

let validate_optional document validate = function
  | None -> Ok ()
  | Some source ->
    validate source.content
    |> Result.map_error (fun detail -> Invalid_document { document; detail })

let validate ~origin ~runtime ~overrides ~keepers =
  if String.trim origin.base_path = "" || String.trim origin.config_root = "" then
    Error (Invalid_envelope "source locations must not be blank")
  else
    let* () = validate_optional Runtime
      (fun content -> Keeper_toml_loader.parse_toml content |> Result.map (fun _ -> ())) runtime in
    let* () = validate_optional Overrides
      (fun content -> Prompt_override_persistence.of_string content
        |> Result.map (fun _ -> ())
        |> Result.map_error Prompt_override_persistence.error_to_string) overrides in
    let rec check seen = function
      | [] -> Ok { origin; runtime; overrides; keepers }
      | keeper :: rest ->
        if not (Keeper_config.validate_name keeper.name) then
          Error (Invalid_keeper_name keeper.name)
        else if Names.mem keeper.name seen then Error (Duplicate_keeper keeper.name)
        else
          let path = keeper.name ^ Config_dir_resolver.keeper_toml_suffix in
          let* () = Keeper_types_profile.materialization_defaults_of_content
            ~path keeper.declaration.content
            |> Result.map (fun _ -> ())
            |> Result.map_error (fun error ->
              Invalid_document { document = Keeper keeper.name;
                detail = Keeper_types_profile.keeper_toml_load_error_to_string error }) in
          check (Names.add keeper.name seen) rest
    in
    check Names.empty keepers

let make ~origin ~runtime ~overrides ~keepers =
  validate ~origin ~runtime:(Option.map source runtime) ~overrides:(Option.map source overrides)
    ~keepers:(List.map (fun (name, content) -> { name; declaration = source content }) keepers)

let source_to_yojson (source : source) : Yojson.Safe.t =
  `Assoc [ "content", `String source.content; "sha256", `String source.sha256 ]

let optional_source_to_yojson = function
  | None -> `Null
  | Some source -> source_to_yojson source

let origin_to_yojson origin : Yojson.Safe.t =
  `Assoc [ "base_path", `String origin.base_path; "config_root", `String origin.config_root ]

let to_yojson bundle : Yojson.Safe.t =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "origin", origin_to_yojson bundle.origin
    ; "runtime", optional_source_to_yojson bundle.runtime
    ; "overrides", optional_source_to_yojson bundle.overrides
    ; "keepers", `List (List.map (fun keeper ->
        `Assoc [ "name", `String keeper.name;
          "declaration", source_to_yojson keeper.declaration ]) bundle.keepers)
    ]

let invalid detail = Error (Invalid_envelope detail)

let object_fields ~where ~keys = function
  | `Assoc fields ->
    let rec check seen = function
      | [] ->
        (match List.find_opt (fun key -> not (Names.mem key seen)) keys with
         | Some key -> invalid (where ^ ": missing field " ^ key)
         | None -> Ok fields)
      | (key, _) :: rest ->
        if not (List.mem key keys) then invalid (where ^ ": unknown field " ^ key)
        else if Names.mem key seen then invalid (where ^ ": duplicate field " ^ key)
        else check (Names.add key seen) rest
    in
    check Names.empty fields
  | _ -> invalid (where ^ ": expected object")

let field fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> invalid ("missing field " ^ key)

let string_field fields key =
  let* value = field fields key in
  match value with
  | `String text -> Ok text
  | _ -> invalid (key ^ ": expected string")

let source_of_yojson document json =
  let* fields = object_fields ~where:(document_to_string document)
    ~keys:[ "content"; "sha256" ] json in
  let* content = string_field fields "content" in
  let* sha256 = string_field fields "sha256" in
  if String.equal sha256 (digest content) then Ok { content; sha256 }
  else Error (Digest_mismatch document)

let optional_source_of_yojson document = function
  | `Null -> Ok None
  | json -> source_of_yojson document json |> Result.map Option.some

let of_yojson json =
  let* fields = object_fields ~where:"world"
    ~keys:[ "schema_version"; "origin"; "runtime"; "overrides"; "keepers" ] json in
  let* version = field fields "schema_version" in
  let* () = match version with
    | `Int version when version = schema_version -> Ok ()
    | `Int version -> Error (Unsupported_version version)
    | _ -> invalid "schema_version: expected integer" in
  let* origin_json = field fields "origin" in
  let* origin_fields = object_fields ~where:"origin"
    ~keys:[ "base_path"; "config_root" ] origin_json in
  let* base_path = string_field origin_fields "base_path" in
  let* config_root = string_field origin_fields "config_root" in
  let* runtime_json = field fields "runtime" in
  let* runtime = optional_source_of_yojson Runtime runtime_json in
  let* overrides_json = field fields "overrides" in
  let* overrides = optional_source_of_yojson Overrides overrides_json in
  let* keepers_json = field fields "keepers" in
  let* keepers = match keepers_json with
    | `List rows ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest ->
          let* fields = object_fields ~where:"keeper" ~keys:[ "name"; "declaration" ] row in
          let* name = string_field fields "name" in
          let* declaration_json = field fields "declaration" in
          let* declaration = source_of_yojson (Keeper name) declaration_json in
          loop ({ name; declaration } :: acc) rest
      in
      loop [] rows
    | _ -> invalid "keepers: expected array" in
  validate ~origin:{ base_path; config_root } ~runtime ~overrides ~keepers

let of_string content =
  match Yojson.Safe.from_string content with
  | json -> of_yojson json
  | exception Yojson.Json_error detail -> Error (Invalid_json detail)

let to_string bundle = Yojson.Safe.pretty_to_string (to_yojson bundle) ^ "\n"

let summary_to_yojson bundle : Yojson.Safe.t =
  let digest = function None -> `Null | Some source -> `String source.sha256 in
  `Assoc
    [ "origin", origin_to_yojson bundle.origin
    ; "runtime_sha256", digest bundle.runtime
    ; "overrides_sha256", digest bundle.overrides
    ; "keepers", `List (List.map (fun keeper ->
        `Assoc [ "name", `String keeper.name;
          "sha256", `String keeper.declaration.sha256 ]) bundle.keepers)
    ]
