type t =
  { text : string
  ; toml : Otoml.t
  }

type client =
  | Claude_code
  | Codex
  | Antigravity

type base =
  { id : string
  ; display_name : string
  ; client : client
  }

type error =
  | Unparsable of string
  | Unknown_base of string
  | Nothing_to_bind of string
  | Id_taken of string
  | Invalid_location of string
  | Location_taken of
      { location : string
      ; provider : string
      }
  | Rejected of Runtime_toml.parse_error list

let ( let* ) = Result.bind

let error_message = function
  | Unparsable detail -> "runtime.toml does not parse: " ^ detail
  | Unknown_base id -> Printf.sprintf "%s is not an official-client provider" id
  | Nothing_to_bind id -> Printf.sprintf "%s binds no model to copy" id
  | Id_taken id -> Printf.sprintf "%s is already used in runtime.toml" id
  | Invalid_location detail -> detail
  | Location_taken { location; provider } ->
    Printf.sprintf "%s already signs in at %s" provider location
  | Rejected errors ->
    String.concat
      "; "
      (List.map
         (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message)
         errors)
;;

let parse text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> Error (Unparsable detail)
  | Ok toml -> Ok { text; toml }
;;

let entries = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> fields
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ -> []
;;

let field key table = List.assoc_opt key (entries table)

let string_field key table =
  match field key table with
  | Some (Otoml.TomlString value) -> Some value
  | Some _ | None -> None
;;

let providers t =
  match field "providers" t.toml with
  | Some table -> entries table
  | None -> []
;;

(* The loader decides a provider's client from its protocol; this asks the
   same function rather than comparing protocol names. *)
let client_of_provider table =
  match string_field "protocol" table with
  | None -> None
  | Some protocol ->
    (match Runtime_toml.api_format_of_protocol protocol with
     | Ok Runtime_schema.Claude_code_runtime -> Some Claude_code
     | Ok Runtime_schema.Codex_app_server_runtime -> Some Codex
     | Ok Runtime_schema.Antigravity_cli_runtime -> Some Antigravity
     | Ok
         ( Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api
         | Runtime_schema.Ollama_api | Runtime_schema.Gemini_api
         | Runtime_schema.Vertex_gemini_api )
     | Error _ -> None)
;;

(* Same order as the loader's display name. *)
let display_name_of ~id table =
  match string_field "display-name" table, string_field "provider-name" table with
  | Some name, _ | None, Some name -> name
  | None, None -> id
;;

let bases t =
  List.filter_map
    (fun (id, table) ->
      Option.map
        (fun client -> { id; display_name = display_name_of ~id table; client })
        (client_of_provider table))
    (providers t)
;;

let taken t id = List.mem_assoc id (entries t.toml) || List.mem_assoc id (providers t)

(* The base is the first account, so the first copy is the second. *)
let first_copy_number = 2

let suggest_id t base =
  let rec from n =
    let id = Printf.sprintf "%s_%d" base.id n in
    if taken t id then from (n + 1) else id
  in
  from first_copy_number
;;

let location_label = function
  | Claude_code | Codex -> "account-home"
  | Antigravity -> "credentials.path"
;;

let expand ?home_dir path =
  match home_dir with
  | Some home when String.starts_with ~prefix:"~/" path ->
    Filename.concat home (String.sub path 2 (String.length path - 2))
  | Some _ | None -> path
;;

(* Both login stores are absolute paths kept exactly as written, which is the
   rule [Runtime_account_home] states; only the message differs. *)
let location_of ?home_dir client raw =
  match Runtime_account_home.of_string (expand ?home_dir raw) with
  | Ok path -> Ok path
  | Error reason ->
    (match client with
     | Claude_code | Codex -> Error (Invalid_location reason)
     | Antigravity ->
       Error
         (Invalid_location
            "the Antigravity OAuth file must be a non-empty absolute path without \
             surrounding whitespace"))
;;

let current_location ?home_dir client table =
  match client with
  | Claude_code | Codex -> string_field "account-home" table
  | Antigravity ->
    Option.map
      (expand ?home_dir)
      (Option.bind (field "credentials" table) (string_field "path"))
;;

let signed_in_at ?home_dir t client location =
  List.find_map
    (fun (id, table) ->
      match client_of_provider table with
      | Some other
        when other = client
             && current_location ?home_dir client table = Some location -> Some id
      | Some _ | None -> None)
    (providers t)
;;

let replace key value fields =
  if List.mem_assoc key fields
  then List.map (fun (k, v) -> if k = key then k, value else k, v) fields
  else fields @ [ key, value ]
;;

let provider_copy base ~id ~location table =
  let fields =
    replace
      "display-name"
      (Otoml.string (base.display_name ^ " · " ^ id))
      (entries table)
  in
  Otoml.table
    (match base.client with
     | Claude_code | Codex -> replace "account-home" (Otoml.string location) fields
     | Antigravity ->
       replace
         "credentials"
         (Otoml.table [ "type", Otoml.string "file"; "path", Otoml.string location ])
         fields)
;;

let declare ?home_dir t ~base ~id ~location =
  let* table =
    match List.assoc_opt base.id (providers t) with
    | Some table when client_of_provider table = Some base.client -> Ok table
    | Some _ | None -> Error (Unknown_base base.id)
  in
  let* bindings =
    match Option.map entries (field base.id t.toml) with
    | Some (_ :: _ as bindings) -> Ok bindings
    | Some [] | None -> Error (Nothing_to_bind base.id)
  in
  let* () = if taken t id then Error (Id_taken id) else Ok () in
  let* location = location_of ?home_dir base.client location in
  let* () =
    match signed_in_at ?home_dir t base.client location with
    | Some provider -> Error (Location_taken { location; provider })
    | None -> Ok ()
  in
  let appended =
    Otoml.Printer.to_string
      ~indent_width:0
      ~collapse_tables:true
      (Otoml.table
         [ "providers", Otoml.table [ id, provider_copy base ~id ~location table ]
         ; id, Otoml.table bindings
         ])
  in
  let separator = if String.ends_with ~suffix:"\n" t.text then "" else "\n" in
  let text = t.text ^ separator ^ appended in
  match Runtime_toml.parse_string text with
  | Ok _ -> Ok text
  | Error errors -> Error (Rejected errors)
;;
