type t = Disabled | Geckodriver of { driver : string; binary : string option }
let ( let* ) = Result.bind
let optional_string toml key =
  match Field_resolution.resolve_string toml ["browser"; key] with
  | Field_resolution.Missing -> Ok None
  | Field_resolution.Type_mismatch { expected; message } -> Error (expected ^ ": " ^ message)
  | Field_resolution.Present value -> Ok (Some value)
let absolute toml key ~refusal =
  let* value = optional_string toml key in
  match value with
  | None -> Ok None
  | Some path when String.trim path <> "" && not (Filename.is_relative path) -> Ok (Some path)
  | Some _ -> Error refusal
let parse toml =
  let* driver = absolute toml "geckodriver"
      ~refusal:"browser.geckodriver must be an absolute path to the geckodriver executable" in
  let* binary = absolute toml "binary"
      ~refusal:"browser.binary must be an absolute browser executable or app bundle path" in
  match driver, binary with
  | None, None -> Ok Disabled
  | None, Some _ -> Error "browser.geckodriver is required when browser.binary is configured"
  | Some driver, binary -> Ok (Geckodriver { driver; binary })
