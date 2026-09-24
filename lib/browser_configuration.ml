type automation = { driver : string; binary : string option }
type stagehand = { chrome : string; extension : string; profile : string option }
type t = { automation : automation option; stagehand : stagehand option }

let none = { automation = None; stagehand = None }
let ( let* ) = Result.bind

let optional_string toml path =
  match Field_resolution.resolve_string toml path with
  | Field_resolution.Missing -> Ok None
  | Field_resolution.Type_mismatch { expected; message } -> Error (expected ^ ": " ^ message)
  | Field_resolution.Present value -> Ok (Some value)
;;

let absolute toml path ~refusal =
  let* value = optional_string toml path in
  match value with
  | None -> Ok None
  | Some path when String.trim path <> "" && not (Filename.is_relative path) -> Ok (Some path)
  | Some _ -> Error refusal
;;

let parse_automation toml =
  let* driver =
    absolute toml [ "browser"; "geckodriver" ]
      ~refusal:"browser.geckodriver must be an absolute path to the geckodriver executable"
  in
  let* binary =
    absolute toml [ "browser"; "binary" ]
      ~refusal:"browser.binary must be an absolute browser executable or app bundle path"
  in
  match driver, binary with
  | None, None -> Ok None
  | None, Some _ -> Error "browser.geckodriver is required when browser.binary is configured"
  | Some driver, binary -> Ok (Some { driver; binary })
;;

let parse_stagehand toml =
  let* chrome =
    absolute toml [ "browser"; "stagehand"; "chrome" ]
      ~refusal:"browser.stagehand.chrome must be an absolute path to a Chromium-family executable"
  in
  let* extension =
    absolute toml [ "browser"; "stagehand"; "extension" ]
      ~refusal:"browser.stagehand.extension must be an absolute path to the unpacked Stagehand extension"
  in
  let* profile =
    absolute toml [ "browser"; "stagehand"; "profile" ]
      ~refusal:
        "browser.stagehand.profile must be an absolute path to an operator-owned profile directory (not Chrome's default user-data-dir: Chrome 136+ refuses remote debugging there)"
  in
  match chrome, extension, profile with
  | None, None, None -> Ok None
  | Some chrome, Some extension, profile -> Ok (Some { chrome; extension; profile })
  | None, _, _ -> Error "browser.stagehand.chrome is required when [browser.stagehand] is configured"
  | Some _, None, _ -> Error "browser.stagehand.extension is required when [browser.stagehand] is configured"
;;

let parse toml =
  let* automation = parse_automation toml in
  let* stagehand = parse_stagehand toml in
  Ok { automation; stagehand }
;;
