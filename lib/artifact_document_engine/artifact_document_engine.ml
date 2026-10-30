type selection = { anchor : int list; head : int list }
type snapshot = { state : string; content : string }
type positioned = { snapshot : snapshot; selection : selection; anchor : int; head : int }
type error_kind = Invalid_request | Invalid_document | Invalid_selection | Changed_selection | Unavailable
type error = { kind : error_kind; message : string }
type runner = string -> (Unix.process_status * string, string) result
open Result.Syntax
let error_message error = error.message
let invalid message = Error { kind = Invalid_request; message }
let unavailable message = Error { kind = Unavailable; message }

let fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || List.exists (fun name -> not (List.mem name allowed)) names
    then Error "duplicate or unknown transformer field" else Ok fields
  | _ -> Error "expected transformer object"
let string name fields = match List.assoc_opt name fields with
  | Some (`String value) when String.is_valid_utf_8 value -> Ok value
  | _ -> Error ("invalid " ^ name)
let index name fields = match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 && Int64.of_int value <= 9_007_199_254_740_991L -> Ok value
  | _ -> Error ("invalid " ^ name)
let valid_state value =
  value <> "" && match Base64.decode value with
  | Ok bytes -> String.equal (Base64.encode_string bytes) value
  | Error (`Msg _) -> false
let selection_to_json (selection : selection) =
  let bytes values = `List (List.map (fun value -> `Int value) values) in
  `Assoc ["anchor", bytes selection.anchor; "head", bytes selection.head]
let selection_of_json json =
  let* fields = fields ["anchor"; "head"] json in
  let bytes name = match List.assoc_opt name fields with
    | Some (`List values) -> List.fold_right (fun value rest ->
        let* rest = rest in match value with
        | `Int byte when byte >= 0 && byte <= 255 -> Ok (byte :: rest)
        | _ -> Error "invalid relative-position byte") values (Ok [])
    | _ -> Error "missing relative position" in
  let* anchor = bytes "anchor" in let* head = bytes "head" in
  Ok { anchor; head }

let default_runner ?(executable = "masc-artifact-document") input =
  try Eio.Switch.run (fun sw ->
    let output_path = Filename.temp_file "masc-artifact-document-" ".json" in
    Eio.Switch.on_release sw (fun () -> Sys.remove output_path);
    (* No provider credentials or NODE_OPTIONS enter this pure transformer.
       stdout is a complete private file, never the process runner's preview. *)
    let env = [|"PATH=" ^ Option.value ~default:"" (Sys.getenv_opt "PATH")|] in
    match Process_eio.run_argv_with_redirects ~env
      ~timeout_sec:30.0
      ~stdin:(Process_eio.From_string input)
      ~stdout:(Process_eio.Written_to { path = output_path; append = false })
      ~stderr:Process_eio.Captured [executable] with
    | Error message -> Error message
    | Ok (status, _, _) when Process_eio.exit_reason_of_status status = Process_eio.Timed_out ->
      (* The shared classifier recognises Process_eio's synthesized timeout
         status (timeout(1) style). An over-long transformer is not a broken
         document: invoke maps this raw runner error to Unavailable so the
         client can retry. *)
      Error "masc-artifact-document timed out"
    | Ok (status, _, _) ->
      let output = Eio_unix.run_in_systhread (fun () ->
        In_channel.with_open_bin output_path In_channel.input_all) in
      Ok (status, output))
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error)

let invoke ~runner request =
  let* status, output = match runner (Yojson.Safe.to_string request) with
    | Ok value -> Ok value
    | Error message -> unavailable message in
  match status with
  | Unix.WEXITED (0 | 2 as exit_code) ->
    let* json = match Yojson.Safe.from_string output with
      | json -> Ok json
      | exception Yojson.Json_error _ -> unavailable "invalid transformer JSON response" in
    (match json with
     | `Assoc values when List.assoc_opt "ok" values = Some (`Bool true) && exit_code = 0 ->
       Result.map_error (fun message -> { kind = Unavailable; message })
         (fields ["ok"; "state"; "content"; "selection"; "range"] json)
     | `Assoc values when List.assoc_opt "ok" values = Some (`Bool false) && exit_code = 2 ->
       let parsed =
         let* values = fields ["ok"; "code"; "message"] json in
         let* code = string "code" values in let* message = string "message" values in
         let* kind = match code with
           | "invalid_request" -> Ok Invalid_request | "invalid_document" -> Ok Invalid_document
           | "invalid_selection" -> Ok Invalid_selection | "changed_selection" -> Ok Changed_selection
           | _ -> Error "unknown transformer error code" in
         Ok { kind; message } in
       (match parsed with Ok error -> Error error | Error message -> unavailable message)
     | _ -> unavailable "transformer exit and response disagree")
  | Unix.WEXITED 127 -> unavailable "shared-document transformer unavailable; run scripts/install-artifact-document.sh"
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> unavailable "shared-document transformer did not complete"

let snapshot fields =
  let* state = string "state" fields in
  let* content = string "content" fields in
  if valid_state state then Ok { state; content } else Error "invalid transformer state"
let decode_snapshot values =
  let parsed = match List.assoc_opt "selection" values, List.assoc_opt "range" values with
    | None, None | Some `Null, Some `Null -> snapshot values
    | _ -> Error "unexpected positioned transformer response" in
  Result.map_error (fun message -> { kind = Unavailable; message }) parsed
let utf16_length text =
  let rec count offset total =
    if offset = String.length text then total
    else
      let decoded = String.get_utf_8_uchar text offset in
      let scalar = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
      count (offset + Uchar.utf_decode_length decoded) (total + if scalar > 0xFFFF then 2 else 1) in
  count 0 0
let selected_text (positioned : positioned) =
  let text = positioned.snapshot.content in
  let offset target =
    let rec walk byte units =
      if units = target then Some byte
      else if units > target || byte >= String.length text then None
      else let decoded = String.get_utf_8_uchar text byte in
        let scalar = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
        walk (byte + Uchar.utf_decode_length decoded) (units + if scalar > 0xFFFF then 2 else 1) in
    if target < 0 then None else walk 0 0 in
  match offset (min positioned.anchor positioned.head), offset (max positioned.anchor positioned.head) with
  | Some start, Some stop -> Ok (String.sub text start (stop - start))
  | _ -> unavailable "transformer selection splits a character or exceeds source"
let decode_positioned values =
  let parsed =
    let* snapshot = snapshot values in
    let* selection = selection_of_json (Option.value ~default:`Null (List.assoc_opt "selection" values)) in
    let* range = fields ["anchor"; "head"] (Option.value ~default:`Null (List.assoc_opt "range" values)) in
    let* anchor = index "anchor" range in let* head = index "head" range in
    let length = utf16_length snapshot.content in
    if anchor > length || head > length
    then Error "transformer selection exceeds source" else Ok { snapshot; selection; anchor; head } in
  Result.map_error (fun message -> { kind = Unavailable; message }) parsed
let seed ?(runner = fun input -> default_runner input) content =
  if not (String.is_valid_utf_8 content) then invalid "source must be UTF-8"
  else let* fields = invoke ~runner (`Assoc ["kind", `String "seed"; "content", `String content]) in
    decode_snapshot fields
let state_request ~runner kind state extra decode =
  if not (valid_state state) then invalid "invalid shared-document state"
  else let* fields = invoke ~runner (`Assoc (["kind", `String kind; "state", `String state] @ extra)) in decode fields
let merge ?(runner = fun input -> default_runner input) ~state ~updates () =
  if not (List.for_all valid_state updates) then invalid "invalid shared-document update"
  else state_request ~runner "merge" state ["updates", `List (List.map (fun value -> `String value) updates)] decode_snapshot
let select ?(runner = fun input -> default_runner input) ~state ~anchor ~head () =
  if anchor < 0 || head < 0 then invalid "source indices must be nonnegative"
  else state_request ~runner "select" state ["anchor", `Int anchor; "head", `Int head] decode_positioned
let resolve ?(runner = fun input -> default_runner input) ~state ~selection () =
  state_request ~runner "resolve" state ["selection", selection_to_json selection] decode_positioned
let edit ?(runner = fun input -> default_runner input) ~state ~selection ~expected ~replacement () =
  if not (String.is_valid_utf_8 expected && String.is_valid_utf_8 replacement) then invalid "source must be UTF-8"
  else state_request ~runner "edit" state
      ["selection", selection_to_json selection; "expected", `String expected; "replacement", `String replacement] decode_positioned
