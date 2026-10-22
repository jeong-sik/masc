module Live = Browser_live_peer
let ( let* ) = Result.bind
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let obj fields = `Assoc fields
let str value = `String value

type run_failure = Exited of { code : int; output : string } | Timed_out | Unstarted of string
type runner = string -> (string, run_failure) result

(* At most this much of what ego wrote reaches a Keeper, cut where a UTF-8
   character starts. ego's own error for a page step repeats the whole
   expression, page script included. *)
let excerpt_bytes = 400
let starts_character text index = index >= String.length text || Char.code text.[index] land 0xC0 <> 0x80
(* The end of a run's output: where it says why it stopped. *)
let tail output =
  let output = String.trim output in
  let length = String.length output in
  if length <= excerpt_bytes then output
  else
    let rec start index = if starts_character output index then index else start (index + 1) in
    let from = start (length - excerpt_bytes) in
    "..." ^ String.sub output from (length - from)
(* The start of an error ego threw: what failed comes first. *)
let head message =
  if String.length message <= excerpt_bytes then message
  else
    let rec stop index = if starts_character message index then index else stop (index - 1) in
    String.sub message 0 (stop excerpt_bytes) ^ "..."

let run_failure_message = function
  | Exited {code; output} -> Printf.sprintf "ego-browser nodejs exited with code %d: %s" code (tail output)
  | Timed_out -> "ego-browser nodejs did not finish in time and was stopped"
  | Unstarted detail -> "ego-browser nodejs did not start: " ^ detail

let result_marker = "masc-ego-result "

(* ego-browser 0.6.0.16 prints its version on the first line and Chromium's
   on an indented "chromium" line. *)
let version_of_output output =
  let lines = List.map String.trim (String.split_on_char '\n' output) in
  let after prefix = List.find_map (fun line ->
    if String.starts_with ~prefix line
    then Some (String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)))
    else None) lines in
  match after "ego-browser ", after "chromium " with
  | Some version, Some engine when version <> "" && engine <> "" -> Ok (version, engine)
  | _ -> Error ("ego-browser --version named no ego lite and Chromium versions: " ^ tail output)

(* A page the space manages has a label, p1, p2 and on, that names it for
   the life of the space. A tab the operator opened there has no label until
   it is adopted, only Chromium's target id. ego says not to keep a target id
   from one run to the next, so a managed page is known by its label alone. *)
type page = Managed of string | Unmanaged of string

type t = { run : runner; space_id : int; version : string; capture_directory : string;
  mutable pages : (page * int) list; mutable next_tab : int; mutable captures : int }

let space_id t = t.space_id

let remember t page = match List.assoc_opt page t.pages with
  | Some id -> id
  | None -> t.next_tab <- t.next_tab + 1; t.pages <- (page, t.next_tab) :: t.pages; t.next_tab

(* A run that ended without an answer, an answer that is not the frame's,
   and ego's own refusal inside the frame. *)
type step_failure = Unanswered of run_failure | Unreadable of string | Refused of string
let step_failure_message = function
  | Unanswered failure -> run_failure_message failure
  | Unreadable detail | Refused detail -> detail

(* Every script has the same frame. [args] is written into it as JSON: ego's
   Node does not see the caller's environment. It writes exactly one answer
   line whatever happens inside. The first line names the step, for a test
   runner that stands in for ego. *)
let script ~step ~space ~args body = String.concat "\n" [
  "// masc-ego: " ^ step;
  "const emit = answer => console.log(" ^ Yojson.Safe.to_string (str result_marker) ^ " + JSON.stringify(answer));";
  "const args = " ^ Yojson.Safe.to_string args ^ ";";
  "try {";
  "  const task = await taskSpace(" ^ Yojson.Safe.to_string space ^ ");";
  body;
  "} catch (error) {";
  "  emit({ok: false, error: String(error && error.message || error)});";
  "}" ]

let answer output =
  let marked = List.filter_map (fun line ->
    if String.starts_with ~prefix:result_marker line
    then Some (String.sub line (String.length result_marker) (String.length line - String.length result_marker))
    else None) (String.split_on_char '\n' output) in
  match marked with
  | [] -> Error (Unreadable ("ego-browser nodejs ended without an answer: " ^ tail output))
  | _ :: _ :: _ -> Error (Unreadable "ego-browser nodejs answered more than once")
  | [line] ->
    match Yojson.Safe.from_string line with
    | exception Yojson.Json_error _ -> Error (Unreadable "ego-browser nodejs answered unreadable JSON")
    | json -> match field "ok" json, field "value" json, field "error" json with
      | Some (`Bool true), Some value, None -> Ok value
      | Some (`Bool false), None, Some (`String error) -> Error (Refused (head error))
      | _ -> Error (Unreadable "ego-browser nodejs answered outside its answer frame")

let asked run ~step ~space ~args body = match run (script ~step ~space ~args body) with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output
let ask t ~step ~args body =
  asked t.run ~step ~space:(`Int t.space_id) ~args body |> Result.map_error step_failure_message

let open_space ~run ~space ~version ~capture_directory =
  let* () = if String.trim space = "" then Error "the ego task space needs a name" else Ok () in
  let* opened = asked run ~step:"space.open" ~space:(str space) ~args:`Null
      "  emit({ok: true, value: {spaceId: task.spaceId, ownership: task.ownership}});"
    |> Result.map_error step_failure_message in
  match field "spaceId" opened, field "ownership" opened with
  | Some (`Int space_id), Some (`String "agent") ->
    Ok {run; space_id; version; capture_directory; pages=[]; next_tab=0; captures=0}
  | Some (`Int _), Some (`String ownership) ->
    Error (Printf.sprintf "ego task space %S belongs to %s, not to an agent" space ownership)
  | _ -> Error "ego answered the task space without its number and owner"

let finish t =
  Result.map ignore (ask t ~step:"space.finish" ~args:`Null
    "  await task.finish({keep: []});\n  emit({ok: true, value: null});")

(* A listing is the space's tabs now: a number whose page is no longer
   listed is dropped, so a read of it is refused before any run. *)
let tab_rows t =
  let* listed = ask t ~step:"tabs.list" ~args:`Null
      "  const tabs = await task.tabs();\n  emit({ok: true, value: tabs.map(tab => ({label: tab.label ?? null, targetId: tab.targetId, title: tab.title, url: tab.url, active: tab.active}))});" in
  let row json =
    let* page = match field "label" json, field "targetId" json with
      | Some (`String label), _ when label <> "" -> Ok (Managed label)
      | Some `Null, Some (`String target) when target <> "" -> Ok (Unmanaged target)
      | _ -> Error "ego listed a tab without a label or a target id" in
    match field "title" json, field "url" json, field "active" json with
    | Some (`String title), Some (`String url), Some (`Bool active) -> Ok (page, title, url, active)
    | _ -> Error "ego listed a tab without its title, URL or active state" in
  let* rows = match listed with
    | `List rows ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | json :: rest -> let* row = row json in collect (row :: acc) rest in
      collect [] rows
    | _ -> Error "ego answered a tab list that is not a list" in
  let numbered = List.map (fun (page, title, url, active) -> remember t page, title, url, active) rows in
  t.pages <- List.filter (fun (page, _) -> List.exists (fun (listed, _, _, _) -> listed = page) rows) t.pages;
  Ok (`List (List.mapi (fun index (id, title, url, active) ->
    obj ["id",`Int id;"index",`Int index;"url",str url;"title",str title;"active",`Bool active]) numbered))

let unmanaged_refused = "was opened by the operator in the ego task space; this connection reads only the pages the space manages"

(* The page a step acts on, by label; [`Null] is the space's active tab,
   which the script finds. *)
let target t args = match field "tabId" args with
  | None -> Ok `Null
  | Some (`Int id) -> (match List.find_opt (fun (_, known) -> known = id) t.pages with
      | Some (Managed label, _) -> Ok (str label)
      | Some (Unmanaged _, _) -> Error (Printf.sprintf "tab %d %s" id unmanaged_refused)
      | None -> Error "browser tab is no longer present")
  | Some _ -> Error "invalid tabId"

(* A page script that throws is answered from inside the page: ego's own
   error for it repeats the whole expression. *)
let on_page body = String.concat "\n" [
  "  const pageCall = (fn, input) => \"(function(){ try { return {answer: (\" + fn + \")(\" + JSON.stringify(input) + \")}; } catch (error) { return {pageError: String(error && error.message || error)}; } })()\";";
  "  const tabs = await task.tabs();";
  "  const tab = args.label === null ? tabs.find(item => item.active) : tabs.find(item => item.label === args.label);";
  "  if (tab === undefined) emit({ok: false, error: args.label === null ? \"no tab is active in the ego task space\" : \"browser tab is no longer present\"});";
  "  else if (!tab.label) emit({ok: false, error: " ^ Yojson.Safe.to_string (str ("the active tab " ^ unmanaged_refused)) ^ "});";
  "  else {";
  "    const page = task.page(tab.label);";
  body;
  "  }" ]

(* The same answers as the BiDi connection: what a page script reads on one
   live connection it reads on the other. ego 0.6.0.16 carried a 3,000,003
   unit answer line whole (2026-10-22). *)
let answer_limit_units = Browser_bidi_peer.script_answer_limit_units
let page_function body =
  Browser_scene_script.page_function ~answer_limit_units ("arguments[0]=JSON.parse(arguments[0]);\n" ^ body)

let page_json call = match field "answer" call, field "pageError" call with
  | Some (`String text), None -> (match Yojson.Safe.from_string text with
      | json -> Ok json
      | exception Yojson.Json_error _ -> Error "the page script answered unreadable JSON")
  | Some (`Int units), None -> Error (Printf.sprintf "page_answer_exceeds_ego_answer_limit: %d UTF-16 units, at most %d are answered"
      units answer_limit_units)
  | None, Some (`String error) -> Error ("the fixed page script failed in the page: " ^ error)
  | _ -> Error "the page script answered outside its answer frame"

let with_tab id = function
  | `Assoc fields -> Ok (obj (("tabId",`Int id) :: fields))
  | _ -> Error "invalid page object"

let evaluate t args ~step body input =
  let* label = target t args in
  let* value = ask t ~step ~args:(obj ["label",label;"fn",str (page_function body);"input",str (Yojson.Safe.to_string input)])
      (on_page "    const answer = await page.evaluate(pageCall(args.fn, args.input));\n    emit({ok: true, value: {label: tab.label, answer}});") in
  match field "label" value, field "answer" value with
  | Some (`String label), Some answer -> let* json = page_json answer in Ok (remember t (Managed label), json)
  | _ -> Error "ego answered a page read without its page label"

let read t args =
  let* cap = match field "maxChars" args with
    | None -> Browser_page_script.text_cap None
    | Some (`Int cap) -> Browser_page_script.text_cap (Some cap)
    | Some _ -> Error Browser_page_script.text_cap_refused in
  let* () = match field "includeHtml" args with
    | None | Some (`Bool false) -> Ok ()
    | Some (`Bool true) -> Error "an ego connection does not read the document source"
    | Some _ -> Error "invalid includeHtml" in
  let* id,page = evaluate t args ~step:"page.read" Browser_page_script.text (`Int cap) in
  with_tab id page

let elements t args =
  let* within = Browser_page_script.within_of_json (field "within" args) in
  let* id,page = evaluate t args ~step:"page.elements"
      (Browser_page_script.parsed Browser_page_script.elements) (Browser_page_script.elements_args within) in
  if Option.is_some (field "documentLoading" page) then Error Browser_page_script.document_loading_refused
  else with_tab id page

let scene t args =
  let* fields = match args with `Assoc fields -> Ok fields | _ -> Error "invalid scene arguments" in
  let* id,page = evaluate t args ~step:"page.scene" Browser_scene_script.read_call (obj (("mode",str "read")::fields)) in
  with_tab id page

let png_signature = "\137PNG\r\n\026\n"
let remove path = match Unix.unlink path with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (code, _, _) ->
    Error (Printf.sprintf "the screenshot file %s was not removed: %s" path (Unix.error_message code))

(* ego writes the screenshot to a file and answers its path. The page's URL
   and viewport are read on each side of it, as the BiDi capture does. *)
let capture t args =
  let* label = target t args in
  t.captures <- t.captures + 1;
  let path = Filename.concat t.capture_directory (Printf.sprintf "ego-capture-%d-%d.png" t.space_id t.captures) in
  let taken = ask t ~step:"page.capture"
      ~args:(obj ["label",label;"state",str (page_function Browser_page_script.capture_state);"path",str path])
      (on_page (String.concat "\n" [
         "    const state = pageCall(args.state, \"{}\");";
         "    const before = await page.evaluate(state);";
         "    const path = await page.screenshot({path: args.path});";
         "    const after = await page.evaluate(state);";
         "    emit({ok: true, value: {label: tab.label, before, after, path}});" ])) in
  let image = match taken with
    | Error _ -> Ok None
    | Ok _ -> Fs_compat.load_owned_regular_file ~ownership_root:t.capture_directory path
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
  let* () = remove path in
  let* value = taken in
  let* image = image in
  let* label = match field "label" value with Some (`String label) -> Ok label | _ -> Error "ego answered a capture without its page label" in
  let* () = if field "path" value = Some (str path) then Ok () else Error "ego wrote the screenshot somewhere else" in
  let* before = page_json (Option.value ~default:`Null (field "before" value)) in
  let* after = page_json (Option.value ~default:`Null (field "after" value)) in
  let* image = match image with
    | Some image when String.starts_with ~prefix:png_signature image -> Ok image
    | Some _ -> Error "ego wrote a screenshot that is not a PNG"
    | None -> Error "ego wrote no screenshot file" in
  match field "url" before, field "url" after, field "viewport" before, field "viewport" after, field "title" after with
  | Some (`String url), Some (`String after_url), Some viewport, Some after_viewport, Some title ->
    if url <> after_url || viewport <> after_viewport then Error "viewport_changed_during_capture"
    else Ok (obj ["tabId",`Int (remember t (Managed label));"url",str url;"title",title;"mimeType",str "image/png";
      "data",str (Base64.encode_string image);"viewport",viewport])
  | _ -> Error "the capture state lacks the page URL, title or viewport"

let dispatch t ~verb args =
  let pre result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  match (verb : Live.verb) with
  | Browser_info -> Ok (obj ["name",str "ego lite";"version",str t.version])
  | Tabs_list -> pre (tab_rows t)
  | Page_read -> pre (read t args)
  | Page_elements -> pre (elements t args)
  | Page_scene -> pre (scene t args)
  | Page_capture -> pre (capture t args)
  | Page_interact | Page_act | Page_goto ->
    Error (Live.Before_effect (Live.verb_to_wire verb ^ " is not served by an ego connection"))
