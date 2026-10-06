type automation = { driver : string; binary : string option }
[@@deriving show, eq]
type stagehand = { chrome : string; extension : string; profile : string option }
[@@deriving show, eq]
type t = {
  automation : automation option;
  stagehand : stagehand option;
  live_enabled : bool;
  automation_enabled : bool;
  stagehand_enabled : bool;
}
[@@deriving show, eq]

let browser_table = Runtime_toml_namespace.(key Browser)
let none = { automation = None; stagehand = None;
  live_enabled = true; automation_enabled = true; stagehand_enabled = true }
let ( let* ) = Result.bind

let table ~path ~keys = function
  | None -> Ok None
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    (match List.filter (fun (key, _) -> not (List.mem key keys)) entries with
     | [] -> Ok (Some entries)
     | (key, _) :: _ -> Error (path ^ "." ^ key ^ " is not a supported setting"))
  | Some _ -> Error (path ^ " must be a TOML table")

let fields = function None -> [] | Some entries -> entries
let enabled ~path entries =
  match List.assoc_opt "enabled" entries with
  | None -> Ok true
  | Some (Otoml.TomlBoolean value) -> Ok value
  | Some _ -> Error (path ^ ".enabled must be a boolean")

let absolute ~path entries key =
  match List.assoc_opt key entries with
  | None -> Ok None
  | Some (Otoml.TomlString value)
    when String.trim value <> "" && not (Filename.is_relative value) -> Ok (Some value)
  | Some _ -> Error (path ^ "." ^ key ^ " must be a non-empty absolute path")

let parse_automation ~path entries =
  let* driver = absolute ~path entries "geckodriver" in
  let* binary = absolute ~path entries "binary" in
  match driver, binary with
  | None, None -> Ok None
  | None, Some _ -> Error (path ^ ".geckodriver is required when binary is configured")
  | Some driver, binary -> Ok (Some { driver; binary })

let parse_stagehand ~path configured =
  let entries = fields configured in
  let* chrome = absolute ~path entries "chrome" in
  let* extension = absolute ~path entries "extension" in
  let* profile = absolute ~path entries "profile" in
  match chrome, extension, profile with
  | None, None, None when configured = None || List.mem_assoc "enabled" entries -> Ok None
  | Some chrome, Some extension, profile -> Ok (Some { chrome; extension; profile })
  | None, _, _ -> Error (path ^ ".chrome is required when the backend is configured")
  | Some _, None, _ -> Error (path ^ ".extension is required when the backend is configured")

let parse toml =
  let* root = table ~path:browser_table
    ~keys:["geckodriver"; "binary"; "live"; "automation"; "stagehand"]
    (Otoml.find_opt toml Fun.id [browser_table]) in
  let root = fields root in
  let automation_path = browser_table ^ ".automation" in
  let stagehand_path = browser_table ^ ".stagehand" in
  let live_path = browser_table ^ ".live" in
  let* automation_table = table ~path:automation_path
    ~keys:["enabled"; "geckodriver"; "binary"] (List.assoc_opt "automation" root) in
  let* stagehand_table = table ~path:stagehand_path
    ~keys:["enabled"; "chrome"; "extension"; "profile"] (List.assoc_opt "stagehand" root) in
  let* live_table = table ~path:live_path ~keys:["enabled"] (List.assoc_opt "live" root) in
  let root_automation = List.mem_assoc "geckodriver" root || List.mem_assoc "binary" root in
  let* automation = match automation_table with
    | Some _ when root_automation ->
      Error "configure geckodriver/binary in only one place: [browser.automation] or [browser]"
    | Some entries -> parse_automation ~path:automation_path entries
    | None -> parse_automation ~path:browser_table root
  in
  let* stagehand = parse_stagehand ~path:stagehand_path stagehand_table in
  let* live_enabled = enabled ~path:live_path (fields live_table) in
  let* automation_enabled = enabled ~path:automation_path (fields automation_table) in
  let* stagehand_enabled = enabled ~path:stagehand_path (fields stagehand_table) in
  Ok { automation; stagehand; live_enabled; automation_enabled; stagehand_enabled }
