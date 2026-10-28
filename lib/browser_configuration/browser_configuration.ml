type automation = { driver : string; binary : string option }
[@@deriving show, eq]
type stagehand = { chrome : string; extension : string; profile : string option }
[@@deriving show, eq]
type live_bidi = { firefox : string; profile : string; port : int }
[@@deriving show, eq]
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
  automation : automation option;
  stagehand : stagehand option;
  live_bidi : live_bidi option;
  live_ego : live_ego option;
}
[@@deriving show, eq]

let browser_table = Runtime_toml_namespace.(key Browser)
let default_live_bidi_port = 9222
let max_port = 65535
let none = { automation = None; stagehand = None; live_bidi = None; live_ego = None }
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

(* A table that is there names a Firefox to drive, so geckodriver is needed. *)
let parse_automation ~path entries =
  let* driver = absolute ~path entries "geckodriver" in
  let* binary = absolute ~path entries "binary" in
  match driver with
  | Some driver -> Ok (Some { driver; binary })
  | None -> Error (path ^ ".geckodriver is required when the backend is configured")

let parse_stagehand ~path configured =
  let entries = fields configured in
  let* chrome = absolute ~path entries "chrome" in
  let* extension = absolute ~path entries "extension" in
  let* profile = absolute ~path entries "profile" in
  match chrome, extension, profile with
  | None, None, None when configured = None -> Ok None
  | Some chrome, Some extension, profile -> Ok (Some { chrome; extension; profile })
  | None, _, _ -> Error (path ^ ".chrome is required when the backend is configured")
  | Some _, None, _ -> Error (path ^ ".extension is required when the backend is configured")

let port ~path entries =
  match List.assoc_opt "port" entries with
  | None -> Ok default_live_bidi_port
  | Some (Otoml.TomlInteger value) when value >= 1 && value <= max_port -> Ok value
  | Some
      Otoml.(
        TomlString _ | TomlInteger _ | TomlFloat _ | TomlBoolean _
        | TomlOffsetDateTime _ | TomlLocalDateTime _ | TomlLocalDate _
        | TomlLocalTime _ | TomlArray _ | TomlTable _ | TomlInlineTable _
        | TomlTableArray _) ->
    Error (Printf.sprintf "%s.port must be an integer from 1 to %d" path max_port)

(* A table that is there names a Firefox to start, so both paths are needed. *)
let parse_live_bidi ~path = function
  | None -> Ok None
  | Some entries ->
    let* firefox = absolute ~path entries "firefox" in
    let* profile = absolute ~path entries "profile" in
    let* port = port ~path entries in
    (match firefox, profile with
     | Some firefox, Some profile -> Ok (Some { firefox; profile; port })
     | None, _ -> Error (path ^ ".firefox is required when the table is configured")
     | Some _, None -> Error (path ^ ".profile is required when the table is configured"))

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

let automation_path = browser_table ^ ".automation"
let stagehand_path = browser_table ^ ".stagehand"
let live_path = browser_table ^ ".live"
let live_bidi_path = live_path ^ ".bidi"
let live_ego_path = live_path ^ ".ego"

let parse toml =
  let* root = table ~path:browser_table
    ~keys:["geckodriver"; "binary"; "live"; "automation"; "stagehand"]
    (Otoml.find_opt toml Fun.id [browser_table]) in
  let root = fields root in
  let* automation_table = table ~path:automation_path
    ~keys:["geckodriver"; "binary"] (List.assoc_opt "automation" root) in
  let* stagehand_table = table ~path:stagehand_path
    ~keys:["chrome"; "extension"; "profile"] (List.assoc_opt "stagehand" root) in
  let* live_table = table ~path:live_path ~keys:["bidi"; "ego"] (List.assoc_opt "live" root) in
  let* live_bidi_table = table ~path:live_bidi_path
    ~keys:["firefox"; "profile"; "port"] (List.assoc_opt "bidi" (fields live_table)) in
  let* live_bidi = parse_live_bidi ~path:live_bidi_path live_bidi_table in
  let* live_ego_table = table ~path:live_ego_path
    ~keys:["command"; "space"] (List.assoc_opt "ego" (fields live_table)) in
  let* live_ego = parse_live_ego ~path:live_ego_path live_ego_table in
  let root_automation = List.mem_assoc "geckodriver" root || List.mem_assoc "binary" root in
  let* automation = match automation_table, root_automation with
    | Some _, true ->
      Error "configure geckodriver/binary in only one place: [browser.automation] or [browser]"
    | Some entries, false -> parse_automation ~path:automation_path entries
    | None, true -> parse_automation ~path:browser_table root
    | None, false -> Ok None
  in
  let* stagehand = parse_stagehand ~path:stagehand_path stagehand_table in
  Ok { automation; stagehand; live_bidi; live_ego }

type _ source =
  | Automation : automation source
  | Stagehand : stagehand source
  | Live_bidi : live_bidi source
  | Live_ego : live_ego source

let source_path : type a. a source -> string = function
  | Automation -> automation_path
  | Stagehand -> stagehand_path
  | Live_bidi -> live_bidi_path
  | Live_ego -> live_ego_path

let source_table : type a. a source -> t -> a option = fun source t ->
  match source with
  | Automation -> t.automation
  | Stagehand -> t.stagehand
  | Live_bidi -> t.live_bidi
  | Live_ego -> t.live_ego

(* The file parser returns most syntax errors but raises on a repeated
   table. *)
let of_file path =
  match Otoml.Parser.from_file_result path with
  | Error detail -> Error detail
  | Ok toml -> parse toml
  | exception Otoml.Duplicate_key detail -> Error detail
