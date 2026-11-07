type ego_space = Named_space of string | Existing_space of int
[@@deriving show, eq]
let validate_ego_space = function
  | Named_space name when String.trim name<>"" -> Ok ()
  | Existing_space id when id>=0 && Int64.of_int id<=9007199254740991L -> Ok ()
  | Named_space _|Existing_space _ ->
      Error "must be a non-empty task space name or a nonnegative JavaScript-safe Space ID"
type live_ego = { command : string; space : ego_space }
[@@deriving show, eq]
type t = {
  live_ego : live_ego option;
}
[@@deriving show, eq]

let browser_table = Runtime_toml_namespace.(key Browser)
let none = { live_ego = None }
open Result.Syntax

let table ~path ~keys = function
  | None -> Ok None
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    (match List.filter (fun (key, _) -> not (List.mem key keys)) entries with
     | [] -> Ok (Some entries)
     | (key, _) :: _ -> Error (path ^ "." ^ key ^ " is not a supported setting"))
  | Some
      Otoml.(
        TomlString _ | TomlInteger _ | TomlFloat _ | TomlBoolean _
        | TomlOffsetDateTime _ | TomlLocalDateTime _ | TomlLocalDate _
        | TomlLocalTime _ | TomlArray _ | TomlTableArray _) ->
    Error (path ^ " must be a TOML table")

let fields = function None -> [] | Some entries -> entries

let absolute ~path entries key =
  match List.assoc_opt key entries with
  | None -> Ok None
  | Some (Otoml.TomlString value)
    when String.trim value <> "" && not (Filename.is_relative value) -> Ok (Some value)
  | Some
      Otoml.(
        TomlString _ | TomlInteger _ | TomlFloat _ | TomlBoolean _
        | TomlOffsetDateTime _ | TomlLocalDateTime _ | TomlLocalDate _
        | TomlLocalTime _ | TomlArray _ | TomlTable _ | TomlInlineTable _
        | TomlTableArray _) ->
    Error (path ^ "." ^ key ^ " must be a non-empty absolute path")

let space ~path entries =
  match List.assoc_opt "space" entries with
  | None -> Ok None
  | Some (Otoml.TomlString value) ->
      let space=Named_space value in
      validate_ego_space space |> Result.map (fun () -> Some space)
      |> Result.map_error (fun detail -> path ^ ".space " ^ detail)
  | Some (Otoml.TomlInteger value) ->
      let space=Existing_space value in
      validate_ego_space space |> Result.map (fun () -> Some space)
      |> Result.map_error (fun detail -> path ^ ".space " ^ detail)
  | Some
      Otoml.(
        TomlFloat _ | TomlBoolean _
        | TomlOffsetDateTime _ | TomlLocalDateTime _ | TomlLocalDate _
        | TomlLocalTime _ | TomlArray _ | TomlTable _ | TomlInlineTable _
        | TomlTableArray _) ->
    Error (path ^ ".space must be a non-empty task space name or a nonnegative JavaScript-safe Space ID")

(* A table that is there names an ego-browser to run, so both keys are needed. *)
let parse_live_ego ~path = function
  | None -> Ok None
  | Some entries ->
    let* command = absolute ~path entries "command" in
    let* space = space ~path entries in
    (match command, space with
     | Some command, Some space -> Ok (Some { command; space })
     | None, _ -> Error (path ^ ".command is required when the table is configured")
     | Some _, None -> Error (path ^ ".space is required when the table is configured"))

let live_path = browser_table ^ ".live"
let live_ego_path = live_path ^ ".ego"

let parse toml =
  let* root = table ~path:browser_table
    ~keys:["live"]
    (Otoml.find_opt toml Fun.id [browser_table]) in
  let root = fields root in
  let* live_table = table ~path:live_path ~keys:["ego"] (List.assoc_opt "live" root) in
  let* live_ego_table = table ~path:live_ego_path
    ~keys:["command"; "space"] (List.assoc_opt "ego" (fields live_table)) in
  let* live_ego = parse_live_ego ~path:live_ego_path live_ego_table in
  Ok { live_ego }

type _ source =
  | Live_ego : live_ego source

let source_path : type a. a source -> string = function
  | Live_ego -> live_ego_path

let source_table : type a. a source -> t -> a option = fun source t ->
  match source with
  | Live_ego -> t.live_ego

(* The file parser returns most syntax errors but raises on a repeated
   table. *)
let of_file path =
  match Otoml.Parser.from_file_result path with
  | Error detail -> Error detail
  | Ok toml -> parse toml
  | exception Otoml.Duplicate_key detail -> Error detail

let of_text text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> Error detail
  | Ok toml -> parse toml
  | exception Otoml.Duplicate_key detail -> Error detail
