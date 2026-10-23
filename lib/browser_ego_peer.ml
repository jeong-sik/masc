module Live = Browser_live_peer
let ( let* ) = Result.bind
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let obj fields = `Assoc fields
let str value = `String value

type run_failure = Exited of { code : int; output : string } | Signaled of int | Timed_out | Output_exceeded
  | Unobserved of string | Unstarted of string
type runner = window_s:float -> string -> (string, run_failure) result

(* The server waits Browser_lane.reply_timeout_sec for a command's answer,
   counted from when it was issued. A runner gets that less this margin for
   the delivery, so a stopped run's failure usually still arrives in time;
   one that does not is dropped by the connection. *)
let delivery_margin_s = 2.
let window_s verb = Browser_lane.reply_timeout_sec verb -. delivery_margin_s
(* Every read the server sends waits the same; opening and ending the space
   answer no command and get a read's window too. *)
let read_window_s = window_s Browser_lane.Tabs_list

(* The same answers as the BiDi connection: what a page script reads on one
   live connection it reads on the other. ego 0.6.0.16 carried a 3,000,003
   unit answer line whole (2026-10-22). *)
let answer_limit_units = Browser_bidi_peer.script_answer_limit_units
(* The answer line carries the page's JSON text as one JSON string, at most
   three bytes a UTF-16 unit, as on the BiDi socket. The rest is the frame
   and ego's own lines, such as its update notice. *)
let output_frame_bytes = 65_536
let output_limit_bytes = 3 * answer_limit_units + output_frame_bytes

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
  | Signaled signal -> "ego-browser nodejs was ended by " ^ Process_eio.signal_name signal
  | Timed_out -> "ego-browser nodejs did not finish in time and was stopped"
  | Output_exceeded -> Printf.sprintf "ego-browser nodejs wrote more than %d bytes and was stopped" output_limit_bytes
  | Unobserved detail -> "ego-browser nodejs ran and its output or its end could not be read: " ^ detail
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

type t = { run : runner; now : unit -> float; space_id : int; version : string; capture_directory : string;
  mutable pages : (page * int) list; mutable next_tab : int; mutable captures : int }

let space_id t = t.space_id

let remember t page = match List.assoc_opt page t.pages with
  | Some id -> id
  | None -> t.next_tab <- t.next_tab + 1; t.pages <- (page, t.next_tab) :: t.pages; t.next_tab

(* A run that ended without an answer, an answer that is not the frame's, a
   refusal the script made before it acted ([before: true]), and an error
   thrown at a point the script does not know, caught by the frame. *)
type step_failure = Unanswered of run_failure | Unreadable of string | Refused of string | Failed of string
let step_failure_message = function
  | Unanswered failure -> run_failure_message failure
  | Unreadable detail | Refused detail | Failed detail -> detail

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
    | json -> match field "ok" json, field "value" json, field "error" json, field "before" json with
      | Some (`Bool true), Some value, None, None -> Ok value
      | Some (`Bool false), None, Some (`String error), Some (`Bool true) -> Error (Refused (head error))
      | Some (`Bool false), None, Some (`String error), None -> Error (Failed (head error))
      | _ -> Error (Unreadable "ego-browser nodejs answered outside its answer frame")

let asked run ~window_s ~step ~space ~args body = match run ~window_s (script ~step ~space ~args body) with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output
let run_step t ~window_s ~step ~args body = asked t.run ~window_s ~step ~space:(`Int t.space_id) ~args body
(* A read has no effect, so however it failed, nothing happened. *)
let ask t ~step ~args body =
  run_step t ~window_s:read_window_s ~step ~args body |> Result.map_error step_failure_message

let open_space ~run ~now ~space ~version ~capture_directory =
  let* () = if String.trim space = "" then Error "the ego task space needs a name" else Ok () in
  let* opened = asked run ~window_s:read_window_s ~step:"space.open" ~space:(str space) ~args:`Null
      "  emit({ok: true, value: {spaceId: task.spaceId, ownership: task.ownership}});"
    |> Result.map_error step_failure_message in
  match field "spaceId" opened, field "ownership" opened with
  | Some (`Int space_id), Some (`String "agent") ->
    Ok {run; now; space_id; version; capture_directory; pages=[]; next_tab=0; captures=0}
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
   error for it repeats the whole expression. [fn] is spliced into that
   expression as source, so it is only ever [page_function] of one of this
   module's own scripts; what a Keeper sends reaches the page as [input],
   through JSON.stringify. *)
let page_call =
  "  const pageCall = (fn, input) => \"(function(){ try { return {answer: (\" + fn + \")(\" + JSON.stringify(input) + \")}; } catch (error) { return {pageError: String(error && error.message || error)}; } })()\";"
let on_page body = String.concat "\n" [
  page_call;
  "  const tabs = await task.tabs();";
  "  const tab = args.label === null ? tabs.find(item => item.active) : tabs.find(item => item.label === args.label);";
  "  if (tab === undefined) emit({ok: false, before: true, error: args.label === null ? \"no tab is active in the ego task space\" : \"browser tab is no longer present\"});";
  "  else if (!tab.label) emit({ok: false, before: true, error: " ^ Yojson.Safe.to_string (str ("the active tab " ^ unmanaged_refused)) ^ "});";
  "  else {";
  "    const page = task.page(tab.label);";
  body;
  "  }" ]

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

(* Effects. Only a page the space manages and an agent opened takes one: ego
   marks a tab the operator opened, or one adopted from them, otherwise. The
   page's own row is checked in the same run that acts, before acting. *)
let not_agent_refused = "was not opened by an agent in the ego task space; this connection moves and closes only the pages its space opened"
let agent_page = String.concat "\n" [
  "  const tab = (await task.tabs()).find(item => item.label === args.label);";
  "  if (tab === undefined) emit({ok: false, before: true, error: \"browser tab is no longer present\"});";
  "  else if (tab.openedBy !== \"agent\") emit({ok: false, before: true, error: \"tab \" + args.tabId + \" \" + " ^ Yojson.Safe.to_string (str not_agent_refused) ^ "});";
  "  else {" ]
let message = "error => String(error && error.message || error)"
(* After a step that may have moved the page, its row in the space says where it is. *)
let row_after = "(await task.tabs()).find(item => item.label === args.label)"

let http_url url =
  let refused = Error (Live.Before_effect "an ego connection opens and moves to absolute HTTP(S) URLs only") in
  match Uri.of_string url with
  | uri -> (match Uri.scheme uri, Uri.host uri with
      | Some ("http" | "https"), Some host when host <> "" -> Ok ()
      | (None | Some _), (None | Some _) -> refused)
  | exception Failure _ -> refused

(* What a failed effect says: refused before it acted, never started, or
   unknown, with what to do about the unknown. *)
let effect_failure ~unknown = function
  | Refused detail | Unanswered (Unstarted detail) -> Live.Before_effect detail
  | Unanswered (Exited _ | Signaled _ | Timed_out | Output_exceeded | Unobserved _ as failure) ->
    Live.Outcome_unknown (run_failure_message failure ^ "; " ^ unknown)
  | Unreadable detail | Failed detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)

let label_of t id = match List.find_opt (fun (_, known) -> known = id) t.pages with
  | Some (Managed label, _) -> Ok label
  | Some (Unmanaged _, _) -> Error (Live.Before_effect (Printf.sprintf "tab %d %s" id unmanaged_refused))
  | None -> Error (Live.Before_effect "browser tab is no longer present")

let tab_fields = function
  | Some (`Assoc row) -> List.filter (fun (name, _) -> List.mem name ["url";"title";"active"]) row
  | Some _ | None -> []

(* ego answers a new page with p<n> active. *)
let open_tab t url =
  let* () = http_url url in
  let unknown = "a tab may have been opened: list this connection's tabs before opening another" in
  match run_step t ~window_s:(window_s (Browser_lane.Page_act (Browser_lane.Action.Open_tab url)))
          ~step:"page.open" ~args:(obj ["url",str url]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      "  let page;";
      "  let refused = null;";
      "  try { page = await task.newPage(); } catch (error) { refused = reason(error); }";
      "  if (page === undefined) emit({ok: false, before: true, error: refused});";
      "  else {";
      "    args.label = page.label;";
      "    let failure = null;";
      "    try { await page.goto(args.url); } catch (error) { failure = reason(error); }";
      "    const tab = " ^ row_after ^ ";";
      "    emit({ok: true, value: {label: page.label, error: failure, tab: tab === undefined ? null : {url: tab.url, title: tab.title, active: tab.active}}});";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    match field "label" value with
    | Some (`String label) ->
      let id = remember t (Managed label) in
      let created = ["tabId",`Int id;"action",str "open_tab";"created",`Bool true] in
      (match field "error" value, field "tab" value with
       | Some `Null, Some (`Assoc _ as tab) -> Ok (obj (created @ tab_fields (Some tab)))
       | Some (`String error), _ ->
         Error (Live.Partial_failure {tab_id = id; receipt = obj created;
           message = Printf.sprintf "New tab was opened as tabId %d on this connection. %s. Do not open another tab to retry; inspect it with this clientId and tabId." id error})
       | Some `Null, (None | Some _) ->
         Error (Live.Partial_failure {tab_id = id; receipt = obj created;
           message = Printf.sprintf "New tab was opened as tabId %d on this connection and was not listed afterwards; inspect it with this clientId and tabId." id})
       | (None | Some _), _ -> Error (Live.Outcome_unknown ("ego answered the new tab outside its answer frame; " ^ unknown)))
    | Some _ | None -> Error (Live.Outcome_unknown ("ego answered the new tab without its page label; " ^ unknown))

let goto t args =
  let* url = match field "url" args with
    | Some (`String url) -> Ok url
    | Some _ | None -> Error (Live.Before_effect "page.goto requires an absolute HTTP(S) URL") in
  let* () = http_url url in
  let* id = match field "tabId" args with
    | Some (`Int id) -> Ok id
    | Some _ | None -> Error (Live.Before_effect "page.goto on an ego connection needs the tabId of a page its space opened") in
  let* label = label_of t id in
  let unknown = Printf.sprintf "list this connection's tabs and read tab %d before another step" id in
  match run_step t ~window_s:(window_s (Browser_lane.Page_goto {url; tab_id = Some id}))
          ~step:"page.goto" ~args:(obj ["label",str label;"url",str url;"tabId",`Int id]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      agent_page;
      "    let failure = null;";
      "    try { await task.page(args.label).goto(args.url); } catch (error) { failure = reason(error); }";
      "    const after = " ^ row_after ^ ";";
      "    emit({ok: true, value: {error: failure, tab: after === undefined ? null : {url: after.url, title: after.title}}});";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let receipt tab = obj (["tabId",`Int id;"action",str "goto"] @ tab_fields tab) in
    match field "error" value, field "tab" value with
    | Some `Null, Some (`Assoc _ as tab) -> Ok (receipt (Some tab))
    | Some (`String error), Some (`Assoc _ as tab) ->
      Error (Live.Partial_failure {tab_id = id; message = error; receipt = receipt (Some tab)})
    | Some (`String error), (None | Some _) -> Error (Live.Outcome_unknown (error ^ "; " ^ unknown))
    | (None | Some _), _ -> Error (Live.Outcome_unknown ("ego answered the move outside its answer frame; " ^ unknown))

let close_tab t id =
  let* label = label_of t id in
  match run_step t ~window_s:(window_s (Browser_lane.Page_act (Browser_lane.Action.On_tab {tab_id = id; frame_path = []; interaction = Browser_lane.Action.Close_tab})))
          ~step:"page.close" ~args:(obj ["label",str label;"tabId",`Int id]) (String.concat "\n" [
      agent_page;
      "    await task.page(args.label).close();";
      "    emit({ok: true, value: {closed: true}});";
      "  }" ]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "tab %d may have closed: list this connection's tabs" id) failure)
  | Ok _ ->
    t.pages <- List.filter (fun (_, known) -> known <> id) t.pages;
    Ok (obj ["tabId",`Int id;"action",str "close_tab";"closed",`Bool true])

(* Input acts as a move or a close does: on a page an agent opened, checked
   in the run that acts. The page scripts the BiDi connection runs find the
   target, check that the document, URL and viewport are the observed ones,
   and make the DOM edits, so a selector or node means the same on both;
   ego moves the mouse and presses the keys. *)

(* Finding a target and acting on it are two runs, and the command has one
   window for both: a later run gets what is left of it. *)
let command_deadline t verb = t.now () +. window_s verb
let left t deadline = deadline -. t.now ()

(* Pointer input at one point of the observed viewport. *)
type motion = Move | Press of { button : Browser_lane.Pointer.button; count : int } | Wheel of { x : int; y : int }
let button_name = function
  | Browser_lane.Pointer.Primary -> "left"
  | Browser_lane.Pointer.Middle -> "middle"
  | Browser_lane.Pointer.Secondary -> "right"
let motion_lines = function
  | Move -> ["        await page.mouse.move(args.x, args.y);"]
  | Press _ -> ["        await page.mouse.click(args.x, args.y, {button: args.button, clickCount: args.count});"]
  | Wheel _ -> ["        await page.mouse.move(args.x, args.y);"; "        await page.mouse.wheel(args.dx, args.dy);"]
let motion_fields = function
  | Move -> []
  | Press {button; count} -> ["button",str (button_name button);"count",`Int count]
  | Wheel {x; y} -> ["dx",`Int x;"dy",`Int y]

(* ego takes a chord as Playwright writes one: the modifiers, then the key,
   joined by "+". It presses the named keys and printable ASCII, up to "~";
   ego 0.6.0.16 refused é, ß and € as an unknown key (2026-10-23). Its typing
   takes any text. *)
let last_pressable_character = 0x7e
let press_refused = "an ego connection presses named keys and printable ASCII characters; type other text with type_text"
type keys = Text of string | Chord of Browser_lane.Keyboard.t
let keys_lines = function
  | Text _ -> ["        await page.keyboard.type(args.keys);"]
  | Chord _ -> ["        await page.keyboard.press(args.keys);"]
let keys_fields = function
  | Text text -> ["keys",str text]
  | Chord chord -> ["keys",str (String.concat "+"
      (List.map Browser_lane.Keyboard.modifier_name chord.modifiers @ [Browser_lane.Keyboard.key_text chord.key]))]

let receipt_of ~id ~verb = function
  | `Assoc fields -> Ok (obj (("tabId",`Int id) :: ("action",str verb) :: List.remove_assoc "action" fields))
  | _ -> Error "the input receipt is not an object"

(* A read: however it fails, nothing happened. *)
let resolve t ~label ~deadline input =
  match run_step t ~window_s:(left t deadline) ~step:"page.target"
          ~args:(obj ["label",str label;"fn",str (page_function Browser_interaction.pointer_target_script);
            "input",str (Yojson.Safe.to_string input)])
          (on_page "    const answer = await page.evaluate(pageCall(args.fn, args.input));\n    emit({ok: true, value: answer});") with
  | Error failure -> Error (Live.Before_effect (step_failure_message failure))
  | Ok answer -> page_json answer |> Result.map_error (fun detail -> Live.Before_effect detail)

(* One run: the guard script checks that the page is the observed one and
   refuses before any input if not, the input is sent, and the receipt script
   reads where the page is. *)
let guarded_input t ~id ~label ~deadline ~verb ~step ~guard ~input ~lines ~fields =
  let unknown = Printf.sprintf "read tab %d before another step" id in
  match run_step t ~window_s:(left t deadline) ~step
          ~args:(obj (["label",str label;"tabId",`Int id;"guard",str (page_function guard);
            "input",str (Yojson.Safe.to_string input);
            "receipt",str (page_function Browser_interaction.pointer_receipt_script)] @ fields))
          (String.concat "\n" ([
      page_call;
      "  const reason = " ^ message ^ ";";
      agent_page;
      "    const page = task.page(args.label);";
      "    const guard = await page.evaluate(pageCall(args.guard, args.input));";
      "    if (guard.pageError !== undefined) emit({ok: false, before: true, error: guard.pageError});";
      "    else {";
      "      let failure = null;";
      "      try {" ] @ lines @ [
      "      } catch (error) { failure = reason(error); }";
      "      const receipt = await page.evaluate(pageCall(args.receipt, \"{}\"));";
      "      emit({ok: true, value: {guard, receipt, error: failure}});";
      "    }";
      "  }" ])) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let decoded name = page_json (Option.value ~default:`Null (field name value)) in
    match decoded "guard", field "error" value, decoded "receipt" with
    | Ok observed, Some `Null, Ok receipt ->
      (match field "url" observed, receipt with
       | Some (`String url), `Assoc fields ->
         receipt_of ~id ~verb (obj (("urlBefore",str url) :: fields))
         |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown))
       | _ -> Error (Live.Outcome_unknown ("the input was sent and its guard or receipt lacks the page URL; " ^ unknown)))
    | (Ok _ | Error _), Some (`String error), (Ok _ | Error _) -> Error (Live.Outcome_unknown (head error ^ "; " ^ unknown))
    | Error detail, Some `Null, _ | Ok _, Some `Null, Error detail ->
      Error (Live.Outcome_unknown ("the input was sent and " ^ detail ^ "; " ^ unknown))
    | (Ok _ | Error _), (None | Some _), (Ok _ | Error _) ->
      Error (Live.Outcome_unknown ("ego answered the input outside its answer frame; " ^ unknown))

(* The DOM edits the shared script makes. It says itself whether it refused
   before any effect. *)
let dom_input t ~id ~label ~deadline ~verb input =
  let unknown = Printf.sprintf "read tab %d before another step" id in
  match run_step t ~window_s:(left t deadline) ~step:"page.input"
          ~args:(obj ["label",str label;"tabId",`Int id;"fn",str (page_function Browser_interaction.script);
            "input",str (Yojson.Safe.to_string input)])
          (String.concat "\n" [
      page_call;
      agent_page;
      "    const result = await task.page(args.label).evaluate(pageCall(args.fn, args.input));";
      "    emit({ok: true, value: result});";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    match page_json value with
    | Error detail -> Error (Live.Outcome_unknown (detail ^ "; " ^ unknown))
    | Ok result ->
      match field "interactionFailure" result with
      | None -> receipt_of ~id ~verb result |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown))
      | Some failure ->
        let reason = match field "message" failure with Some (`String reason) -> reason | _ -> "the page refused the input" in
        match field "effectStarted" failure with
        | Some (`Bool false) -> Error (Live.Before_effect reason)
        | Some _ | None -> Error (Live.Outcome_unknown (reason ^ "; " ^ unknown))

let interact t args =
  let before result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  let* fields = before (match args with `Assoc fields -> Ok fields | _ -> Error "invalid interaction") in
  let* request = before (Browser_interaction.parse (obj (("lane",str Browser_lane.Lane_name.(to_wire Live)) :: fields))) in
  let* () = match request.frame_path with
    | [] -> Ok ()
    | _ :: _ -> Error (Live.Before_effect "an ego connection does not act inside frames") in
  let id = request.tab_id in
  let verb = Browser_lane.interaction_verb request.action in
  let refused = Error (Live.Before_effect (verb ^ " is not served by an ego connection")) in
  let* label = label_of t id in
  let deadline = command_deadline t (Browser_lane.Page_interact {tab_id = id; frame_path = []; expected_url = request.expected_url; action = request.action}) in
  let input ~expected_url action = Browser_lane.interaction_args ~tab_id:id ~frame_path:[] ~expected_url action in
  let* expected_url, action = match request.action with
    | Browser_lane.Click _ | Browser_lane.Click_node _ | Browser_lane.Hover _ | Browser_lane.Double_click _ ->
      let* resolved = resolve t ~label ~deadline (input ~expected_url:request.expected_url request.action) in
      let* action = before (Browser_interaction.resolve_pointer_action request.action resolved) in
      let* url = before (match field "url" resolved with Some (`String url) -> Ok url | _ -> Error "pointer resolution missing url") in
      Ok (Some url, action)
    | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Set_zoom _
    | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
    | Browser_lane.Scroll _ | Browser_lane.Drag_to _ | Browser_lane.Hover_at _ | Browser_lane.Tap_at _ | Browser_lane.Swipe _
    | Browser_lane.Click_at _ | Browser_lane.Scroll_at _ | Browser_lane.Drag _ | Browser_lane.Follow_link _
    | Browser_lane.Fill_node _ -> Ok (request.expected_url, request.action) in
  let pointer (viewport : Browser_lane.Pointer.viewport) point motion =
    let x, y = Browser_lane.Pointer.viewport_pixels viewport point in
    guarded_input t ~id ~label ~deadline ~verb ~step:"page.pointer" ~guard:Browser_interaction.pointer_guard_script
      ~input:(input ~expected_url action) ~lines:(motion_lines motion) ~fields:(["x",`Int x;"y",`Int y] @ motion_fields motion) in
  let keyboard keys =
    guarded_input t ~id ~label ~deadline ~verb ~step:"page.keyboard" ~guard:Browser_interaction.keyboard_guard_script
      ~input:(input ~expected_url action) ~lines:(keys_lines keys) ~fields:(keys_fields keys) in
  match action with
  | Browser_lane.Click_at {point; viewport; button} -> pointer viewport point (Press {button; count = 1})
  | Browser_lane.Double_click_at {point; viewport} -> pointer viewport point (Press {button = Browser_lane.Pointer.Primary; count = 2})
  | Browser_lane.Hover_at {point; viewport} -> pointer viewport point Move
  | Browser_lane.Scroll_at {point; viewport; x; y} -> pointer viewport point (Wheel {x; y})
  | Browser_lane.Type_text {text; _} -> let* () = before (Browser_lane.Keyboard.validate_text text) in keyboard (Text text)
  | Browser_lane.Press_key {key; _} ->
    (match key.key with
     | Browser_lane.Keyboard.Character scalar when Uchar.to_int scalar > last_pressable_character ->
       Error (Live.Before_effect press_refused)
     | Browser_lane.Keyboard.Character _ | Browser_lane.Keyboard.Named _ -> keyboard (Chord key))
  | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Fill_node _ | Browser_lane.Scroll _ | Browser_lane.Follow_link _ ->
    dom_input t ~id ~label ~deadline ~verb (input ~expected_url action)
  | Browser_lane.Click _ | Browser_lane.Click_node _ | Browser_lane.Hover _ | Browser_lane.Double_click _ ->
    Error (Live.Before_effect "unresolved semantic pointer target")
  | Browser_lane.Drag_to _ | Browser_lane.Drag _ | Browser_lane.Tap_at _ | Browser_lane.Swipe _
  | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ | Browser_lane.Activate_tab -> refused

let act t args =
  match Browser_lane.Action.parse args with
  | Error detail -> Error (Live.Before_effect detail)
  | Ok (Browser_lane.Action.Open_tab url) -> open_tab t url
  | Ok (Browser_lane.Action.On_tab {frame_path = _ :: _; _}) ->
    Error (Live.Before_effect "an ego connection does not act inside frames")
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Close_tab}) -> close_tab t tab_id
  | Ok (Browser_lane.Action.On_tab {frame_path = []; interaction = (Browser_lane.Action.Upload _
      | Browser_lane.Action.Accept_dialog _ | Browser_lane.Action.Dismiss_dialog
      | Browser_lane.Action.Back | Browser_lane.Action.Forward | Browser_lane.Action.Reload); _}) ->
    Error (Live.Before_effect "an ego connection's page.act serves open_tab and close_tab only")

let dispatch t ~verb args =
  let pre result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  match (verb : Live.verb) with
  | Browser_info -> Ok (obj ["name",str "ego lite";"version",str t.version])
  | Tabs_list -> pre (tab_rows t)
  | Page_read -> pre (read t args)
  | Page_elements -> pre (elements t args)
  | Page_scene -> pre (scene t args)
  | Page_capture -> pre (capture t args)
  | Page_goto -> goto t args
  | Page_act -> act t args
  | Page_interact -> interact t args
