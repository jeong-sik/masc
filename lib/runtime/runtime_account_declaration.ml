(* Otoml prints floats with "%.2f", so a copied [price-input = 0.075] came out
   as 0.07 and a [timeout-s = 0.004] as 0.00, which the loader then refused.
   A copy has to carry the base's value, so this instance prints the shortest
   decimal that reads back as the same float -- 17 significant digits always
   do for binary64 -- and keeps a point or exponent so TOML still reads a
   float rather than an integer. Reading is Otoml's own. *)
module Exact_number = struct
  include Otoml.Base.OCamlNumber

  let round_trip_digits = [ 15; 16; 17 ]

  let float_to_string x =
    if Float.is_nan x
    then "nan"
    else if x = Float.infinity
    then "inf"
    else if x = Float.neg_infinity
    then "-inf"
    else (
      let candidates = List.map (fun digits -> Printf.sprintf "%.*g" digits x) round_trip_digits in
      let text =
        match List.find_opt (fun text -> Float.of_string text = x) candidates with
        | Some text -> text
        | None -> Printf.sprintf "%.17g" x
      in
      if String.exists (function '.' | 'e' | 'E' -> true | _ -> false) text
      then text
      else text ^ ".0")
  ;;
end

module Toml = Otoml.Base.Make (Exact_number) (Otoml.Base.StringDate)

type t =
  { text : string
  ; toml : Toml.t
  }

type client =
  | Claude_code
  | Codex
  | Antigravity
  | Muse
[@@deriving enumerate]

type base =
  { id : string
  ; display_name : string
  ; client : client
  ; command : string option
  }

type declared =
  { text : string
  ; location : string
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
  | Unsupported_layout of string
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
  | Unsupported_layout detail -> detail
  | Rejected errors ->
    String.concat
      "; "
      (List.map
         (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message)
         errors)
;;

let parse text =
  match Toml.Parser.from_string_result text with
  | Error detail -> Error (Unparsable detail)
  | Ok toml -> Ok { text; toml }
;;

let entries = function
  | Toml.TomlTable fields | Toml.TomlInlineTable fields -> fields
  | Toml.TomlString _ | Toml.TomlInteger _ | Toml.TomlFloat _
  | Toml.TomlBoolean _ | Toml.TomlOffsetDateTime _ | Toml.TomlLocalDateTime _
  | Toml.TomlLocalDate _ | Toml.TomlLocalTime _ | Toml.TomlArray _
  | Toml.TomlTableArray _ -> []
;;

let field key table = List.assoc_opt key (entries table)

let string_field key table =
  match field key table with
  | Some (Toml.TomlString value) -> Some value
  | Some _ | None -> None
;;

let providers_table = Runtime_toml_namespace.(key Providers)

let providers_of toml =
  match field providers_table toml with
  | Some table -> entries table
  | None -> []
;;

let providers t = providers_of t.toml

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
     | Ok Runtime_schema.Muse_serve_runtime -> Some Muse
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
        (fun client ->
          { id; display_name = display_name_of ~id table; client
          ; command = string_field "command" table
          })
        (client_of_provider table))
    (providers t)
;;

(* A name is taken by a table in the text, by a provider, or by a table
   another reader owns even when the text does not write it yet: the loader
   refuses that name as a provider id. *)
let taken t id =
  List.mem_assoc id (entries t.toml)
  || List.mem_assoc id (providers t)
  || List.mem id Runtime_toml.reserved_provider_ids

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
  | Claude_code | Codex | Muse -> "account-home"
  | Antigravity -> "credentials.path"
;;

let expand_home ?home_dir path =
  match home_dir with
  | Some home when String.starts_with ~prefix:"~/" path ->
    Filename.concat home (String.sub path 2 (String.length path - 2))
  | Some _ | None -> path
;;

(* Both login stores are absolute paths kept exactly as written, which is the
   rule [Runtime_account_home] states; only the message differs. *)
let location_of ?home_dir client raw =
  match home_dir, Runtime_account_home.of_string (expand_home ?home_dir raw) with
  | None, Error _ when String.starts_with ~prefix:"~/" raw ->
    Error (Invalid_location "~/ is expanded from HOME, which is not set; type an absolute path")
  | _, Ok path -> Ok path
  | _, Error reason ->
    (match client with
     | Claude_code | Codex | Muse -> Error (Invalid_location reason)
     | Antigravity ->
       Error
         (Invalid_location
            "the Antigravity OAuth file must be a non-empty absolute path without \
             surrounding whitespace"))
;;

(* Where a provider signs in. A Claude Code, Codex or Muse provider without
   [account-home] runs on the home the client inherits, which the caller
   knows and this module does not. *)
let login_store ?home_dir ~inherited_home client table =
  match client with
  | Claude_code | Codex | Muse ->
    (match string_field "account-home" table with
     | Some home -> Some home
     | None -> inherited_home client)
  | Antigravity ->
    Option.map
      (expand_home ?home_dir)
      (Option.bind (field "credentials" table) (string_field "path"))
;;

(* A file or directory that exists, told apart the way the filesystem does:
   two names with one device and inode are one thing, whether the second
   name is a link, a hard link or another letter case. *)
type identity =
  { dev : int
  ; ino : int
  }

(* Where a login store is on this machine, for comparing two of them; the
   text written stays as it is. A store that does not exist yet is the
   deepest directory on its path that does, and the parts below it as
   written. *)
type place =
  | Existing of identity
  | Absent of
      { under : identity
      ; rest : string list
      }

(* The parts that do not exist yet are compared with ASCII letters in either
   case taken as equal: on a case-insensitive disk [acct-new] and [ACCT-NEW]
   become one directory once either is created, and on a case-sensitive disk
   refusing both is the safe side. Nothing else is folded: two such names
   that differ in the case of a non-ASCII letter, or only in Unicode
   normalization, compare as different. *)
let same_place a b =
  let same_identity a b = a.dev = b.dev && a.ino = b.ino in
  let same_part a b = String.equal (String.lowercase_ascii a) (String.lowercase_ascii b) in
  match a, b with
  | Existing a, Existing b -> same_identity a b
  | Absent a, Absent b -> same_identity a.under b.under && List.equal same_part a.rest b.rest
  | Existing _, Absent _ | Absent _, Existing _ -> false
;;

(* Links followed in one path before giving up: Linux's MAXSYMLINKS. macOS
   gives up at 32, so a chain of 33 to 40 links is read here although the
   client could not open it. *)
let max_links = 40

let parts_of path =
  List.filter (fun part -> part <> "" && part <> ".") (String.split_on_char '/' path)
;;

let identity_of (stats : Unix.stats) = { dev = stats.Unix.st_dev; ino = stats.Unix.st_ino }

(* Where an absolute path leads, walked one part at a time as the kernel
   opens it. [..] goes up from where the walk has reached, so after a link it
   is the target's parent. A link is followed even when what it names does
   not exist yet, since signing in creates it. Nothing exists below a part
   that does not, so the parts after it are kept without reading the disk,
   and [..] drops the last of them. A part below a file, more than
   [max_links] links, or a part the filesystem refuses to read leaves the
   place unknown, and that is an error rather than a guess. *)
let place_of path =
  let refused name error = Error (Printf.sprintf "%s: %s" name (Unix.error_message error)) in
  (* [directory] exists and has no link in it; [absent] is below it, last
     part first. *)
  let rec walk ~links directory absent parts =
    match parts, absent with
    | [], _ ->
      (match Unix.stat directory with
       | exception Unix.Unix_error (error, _, _) -> refused directory error
       | stats ->
         (match absent with
          | [] -> Ok (Existing (identity_of stats))
          | _ :: _ ->
            Ok (Absent { under = identity_of stats; rest = List.rev absent })))
    | ".." :: parts, _ :: above -> walk ~links directory above parts
    | ".." :: parts, [] -> walk ~links (Filename.dirname directory) [] parts
    | part :: parts, _ :: _ -> walk ~links directory (part :: absent) parts
    | part :: parts, [] ->
      let next = Filename.concat directory part in
      (match Unix.lstat next with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> walk ~links directory [ part ] parts
       | exception Unix.Unix_error (error, _, _) -> refused next error
       | stats ->
         (match stats.Unix.st_kind with
          | Unix.S_DIR -> walk ~links next [] parts
          | Unix.S_LNK when links >= max_links -> refused next Unix.ELOOP
          | Unix.S_LNK ->
            (match Unix.readlink next with
             | exception Unix.Unix_error (error, _, _) -> refused next error
             | target ->
               let from = if Filename.is_relative target then directory else "/" in
               walk ~links:(links + 1) from [] (parts_of target @ parts))
          | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
            (match parts with
             | [] -> Ok (Existing (identity_of stats))
             | _ :: _ -> refused next Unix.ENOTDIR)))
  in
  walk ~links:0 "/" [] (parts_of path)
;;

(* The provider of [client] that already signs in where [location] leads.
   Two spellings of one place are one login: [/a/b/], [/a/./b], [/a/c/../b],
   a link to [/a/b] even before [/a/b] exists, a hard link to an OAuth file,
   or [/A/B] on a case-insensitive disk. *)
let signed_in_at ?home_dir ~inherited_home t client location =
  let unknown path detail =
    Invalid_location
      (Printf.sprintf "cannot tell which directory %s is (%s)" path detail)
  in
  let* target = Result.map_error (unknown location) (place_of location) in
  List.fold_left
    (fun found (id, table) ->
      match found with
      | Error _ | Ok (Some _) -> found
      | Ok None ->
        (match client_of_provider table with
         | Some other when other = client ->
           (match login_store ?home_dir ~inherited_home client table with
            | None -> Ok None
            | Some store ->
              (match place_of store with
               | Ok place when same_place place target -> Ok (Some id)
               | Ok _ -> Ok None
               | Error detail ->
                 Error
                   (unknown store (Printf.sprintf "provider %s signs in there; %s" id detail))))
         | Some _ | None -> Ok None))
    (Ok None)
    (providers t)
;;

let is_section = function
  | Toml.TomlTable _ | Toml.TomlTableArray _ -> true
  | Toml.TomlString _ | Toml.TomlInteger _ | Toml.TomlFloat _
  | Toml.TomlBoolean _ | Toml.TomlOffsetDateTime _ | Toml.TomlLocalDateTime _
  | Toml.TomlLocalDate _ | Toml.TomlLocalTime _ | Toml.TomlArray _
  | Toml.TomlInlineTable _ -> false
;;

(* A key added to a provider goes before its first section. Printed after a
   [[table array]] it would land inside that array's last element, and the
   provider would run without it. *)
let set key value fields =
  if List.mem_assoc key fields
  then List.map (fun (k, v) -> if k = key then k, value else k, v) fields
  else (
    let scalars, sections =
      List.partition (fun (_, v) -> not (is_section v)) fields
    in
    scalars @ [ key, value ] @ sections)
;;

let provider_copy base ~display_name ~location table =
  let fields = set "display-name" (Toml.string display_name) (entries table) in
  Toml.table
    (match base.client with
     | Claude_code | Codex | Muse -> set "account-home" (Toml.string location) fields
     | Antigravity ->
       set
         "credentials"
         (Toml.table [ "type", Toml.string "file"; "path", Toml.string location ])
         fields)
;;

(* What the appended text has to say once it is read back. Otoml accepts
   layouts a TOML 1.0 reader does not, and the loader ignores keys it does
   not know, so a copy that lost its login store would still load and run on
   someone else's login. *)
let carries ~id ~display_name ~location base text =
  match Toml.Parser.from_string_result text with
  | Error detail -> Error (Unparsable detail)
  | Ok toml ->
    let provider = List.assoc_opt id (providers_of toml) in
    let store =
      Option.bind provider (fun table ->
        match base.client with
        | Claude_code | Codex | Muse -> string_field "account-home" table
        | Antigravity -> Option.bind (field "credentials" table) (string_field "path"))
    in
    let name = Option.bind provider (string_field "display-name") in
    if store = Some location && name = Some display_name
    then Ok ()
    else
      Error
        (Unsupported_layout
           (Printf.sprintf
              "%s could not be written so that it signs in at %s; add it in the editor"
              id location))
;;

let declare ?home_dir ~inherited_home t ~base ~id ~location =
  let* () =
    match field providers_table t.toml with
    | Some (Toml.TomlInlineTable _) ->
      Error
        (Unsupported_layout
           "providers is one inline table, so a provider cannot be added after it")
    | Some _ | None -> Ok ()
  in
  let* table =
    match List.assoc_opt base.id (providers t) with
    | Some table when client_of_provider table = Some base.client -> Ok table
    | Some _ | None -> Error (Unknown_base base.id)
  in
  let* config = Result.map_error (fun errors -> Rejected errors) (Runtime_toml.parse_string t.text) in
  let* () =
    if List.exists
         (fun (binding : Runtime_schema.binding) -> String.equal binding.provider_id base.id)
         config.bindings
    then Ok ()
    else Error (Nothing_to_bind base.id)
  in
  (* A shared model set is carried by the provider itself. Copy only the
     source's explicit overrides so future changes to that set reach both
     accounts, including when the source has no binding table at all. *)
  let bindings = match field base.id t.toml with Some table -> entries table | None -> [] in
  let* () = if taken t id then Error (Id_taken id) else Ok () in
  let* location = location_of ?home_dir base.client location in
  let* () =
    match signed_in_at ?home_dir ~inherited_home t base.client location with
    | Ok (Some provider) -> Error (Location_taken { location; provider })
    | Ok None -> Ok ()
    | Error error -> Error error
  in
  let display_name = base.display_name ^ " · " ^ id in
  let appended =
    Toml.Printer.to_string
      ~indent_width:0
      ~collapse_tables:true
      (Toml.table
         ([ providers_table, Toml.table [ id, provider_copy base ~display_name ~location table ] ]
          @ match bindings with [] -> [] | _ :: _ -> [ id, Toml.table bindings ]))
  in
  let separator = if String.ends_with ~suffix:"\n" t.text then "" else "\n" in
  let text = t.text ^ separator ^ appended in
  let* () = carries ~id ~display_name ~location base text in
  match Runtime_toml.parse_string text with
  | Ok _ -> Ok { text; location }
  | Error errors -> Error (Rejected errors)
;;
