module Live = Browser_live_peer
open Result.Syntax
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let obj fields = `Assoc fields
let str value = `String value

type run_failure = Exited of { code : int; output : string } | Signaled of int | Timed_out | Output_exceeded
  | Unobserved of string | Unstarted of string
type runner = window_s:float -> string -> (string, run_failure) result
type space_name_observation = No_user_owned_match | User_owned_matches of int list | Space_names_unavailable of string

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

(* A page the space manages has a label, p1, p2 and on, that names it for
   the life of the space. A tab the operator opened there has no label until
   it is adopted, only Chromium's target id. ego says not to keep a target id
   from one run to the next, so a managed page is known by its label alone. *)
type page = Managed of string | Unmanaged of string

module Input = Browser_ego_input

type downloads = { root : string; publish : string -> (Yojson.Safe.t, string) result }

type finish_state = Active | Finish_uncertain | Finished of {
  keep : Browser_lane.Action.keep_pages; receipt : Yojson.Safe.t; settlement : (unit, string) result }

type t = { run : runner; run_native : string -> (string, run_failure) result; now : unit -> float; space : Browser_lane.ego_space; version : string; capture_directory : string;
  downloads : downloads; published : (string, Yojson.Safe.t) Hashtbl.t; uploads : Browser_lane.Upload_lease.owner;
  input : Input.t; mutable finish_state : finish_state; mutable space_observation : Browser_ego_space_observation.t option;
  mutable pages : (page * int) list; mutable next_tab : int; mutable captures : int }

let space_id t = t.space.id
let space t = t.space
let space_observation t = t.space_observation
let input_status t = Input.status t.input
let input_busy t = Input.busy t.input
let assert_input_reset t ~generation = Input.assert_reset t.input ~generation ~now:(t.now ())

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

(* ego's owner of a task space, as a TaskSpace handle and listTaskSpaces
   name it. The agent holds a space it opened until it hands the space to
   the operator, or the operator takes it over in ego; ego then stops every
   call on the space with EGO_TASK_SPACE_USER_IN_CONTROL until the agent
   takes it back. A space the operator made ("user") is theirs. *)
type space_owner = Agent_owner | Handed_to_operator | Operator_owner [@@deriving enumerate]
let space_owner_to_wire = function
  | Agent_owner -> "agent"
  | Handed_to_operator -> "agentDelegatedToUser"
  | Operator_owner -> "user"
let space_owner_of_wire raw =
  List.find_opt (fun owner -> String.equal (space_owner_to_wire owner) raw) all_of_space_owner
let agent_ownership = space_owner_to_wire Agent_owner

(* Who must hold the space for a script's body to run. Every step needs the
   agent to hold it, taking the space back needs the operator to, and
   opening the connection reads the owner itself. The frame checks before
   the body runs, so a step on a space the operator holds is refused before
   any effect. *)
type holder = Agent_holds | Operator_holds | Either_holds
let operator_holds_refused = "the operator holds this ego task space, so nothing was done; take it back with take_over only after the operator says they are done. ego ownership: "
let agent_holds_refused = "the agent already holds this ego task space; there is nothing to take over"
let held_by holder body = match holder with
  | Either_holds -> [body]
  | Agent_holds ->
    ["  if (task.ownership !== " ^ Yojson.Safe.to_string (str agent_ownership) ^ ") emit({ok: false, before: true, error: "
       ^ Yojson.Safe.to_string (str operator_holds_refused) ^ " + task.ownership});";
     "  else {"; body; "  }"]
  | Operator_holds ->
    ["  if (task.ownership === " ^ Yojson.Safe.to_string (str agent_ownership) ^ ") emit({ok: false, before: true, error: "
       ^ Yojson.Safe.to_string (str agent_holds_refused) ^ "});";
     "  else {"; body; "  }"]

(* Every script has the same frame. [args] is written into it as JSON: ego's
   Node does not see the caller's environment. It writes exactly one answer
   line whatever happens inside. The first line names the step, for a test
   runner that stands in for ego. *)
let frame ~step ~args lines = String.concat "\n" ([
  "// masc-ego: " ^ step;
  "const emit = answer => console.log(" ^ Yojson.Safe.to_string (str result_marker) ^ " + JSON.stringify(answer));";
  "const args = JSON.parse(" ^ Yojson.Safe.to_string (str (Yojson.Safe.to_string args)) ^ ");";
  "try {" ]
  @ lines @ [
  "} catch (error) {";
  "  emit({ok: false, error: String(error && error.message || error)});";
  "}" ])
let script ~step ~space ~holder ~args body =
  frame ~step ~args (("  const task = await taskSpace(" ^ Yojson.Safe.to_string space ^ ");") :: held_by holder body)

(* taskSpace makes the space it does not find, so the spaces are read from
   the list without opening one. Every row is passed on and the name is
   compared here, so a row ego lists without a name is refused, not skipped;
   an ego without the list answers no list. *)
let task_spaces_script = frame ~step:"spaces.list" ~args:(obj []) [
  "  const spaces = typeof listTaskSpaces === \"function\" ? await listTaskSpaces() : null;";
  "  emit({ok: true, value: Array.isArray(spaces)";
  "    ? spaces.map(space => space !== null && typeof space === \"object\"";
  "        ? {spaceId: space.id, name: space.name, ownership: space.ownership} : space)";
  "    : spaces});" ]

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

type spaces_failure = Spaces_failed of string | Spaces_malformed of string
let matching_spaces ~space output =
  let* value = match answer output with
    | Ok value -> Ok value
    (* ego threw inside the frame, for one that could not reach ego lite. *)
    | Error (Failed detail) -> Error (Spaces_failed detail)
    | Error (Unanswered failure) -> Error (Spaces_failed (run_failure_message failure))
    | Error (Unreadable detail | Refused detail) -> Error (Spaces_malformed detail) in
  let row = function
    | `Assoc _ as listed ->
      (match field "spaceId" listed, field "name" listed, field "ownership" listed with
       | Some (`Int space_id), Some (`String name), Some (`String wire) ->
         let matches=match space with
           | Browser_configuration.Named_space wanted -> String.equal name wanted
           | Existing_space id -> space_id=id in
         if not matches then Ok None
         else (match space_owner_of_wire wire with
          | Some owner -> Ok (Some (space_id, owner))
          | None -> Error (Spaces_malformed (Printf.sprintf "ego named the owner of task space %d %S, which masc does not know" space_id wire)))
       | _ -> Error (Spaces_malformed "ego listed a task space without its number, name and owner"))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Spaces_malformed "ego listed a task space that is not an object") in
  match value with
  | `List spaces ->
    List.fold_right (fun listed spaces ->
      let* spaces = spaces in
      let* named = row listed in
      Ok (match named with Some named -> named :: spaces | None -> spaces)) spaces (Ok [])
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    Error (Spaces_malformed "ego answered the task spaces without a list")

(* Do not call taskSpace here: opening by name can create a space or refuse a
   user-owned name. This listing is only evidence for leaving that space alone. *)
let observe_space_name ~run ~space =
  let script = frame ~step:"space.inspect" ~args:(obj ["name", str space]) [
    "  const spaces = await listTaskSpaces();";
    "  if (!Array.isArray(spaces)) throw new Error('task space listing is not an array');";
    "  const matches = spaces.filter(row => row && row.name === args.name).map(row => ({id: row.id, createdBy: row.createdBy, ownership: row.ownership}));";
    "  emit({ok: true, value: matches});" ] in
  let inspected = match run ~window_s:read_window_s script with
    | Error failure -> Error (run_failure_message failure)
    | Ok output -> Result.map_error step_failure_message (answer output) in
  let rec matches ids unreadable = function
    | [] ->
      (match List.rev ids, unreadable with
       | _ :: _ as ids, _ -> User_owned_matches ids
       | [], true -> Space_names_unavailable "ego listed a matching task space without a recognized id and owner"
       | [], false -> No_user_owned_match)
    | row :: rest ->
      (match field "id" row, field "createdBy" row, field "ownership" row with
       | Some (`Int id), _, Some (`String "user") when id > 0 -> matches (id :: ids) unreadable rest
       | Some (`Int id), Some (`String ("agent" | "user")),
         Some (`String ("agent" | "user" | "agentDelegatedToUser")) when id > 0 -> matches ids unreadable rest
       | _ -> matches ids true rest) in
  match inspected with
  | Error detail -> Space_names_unavailable detail
  | Ok (`List rows) -> matches [] false rows
  | Ok _ -> Space_names_unavailable "ego did not list task spaces as an array"

let asked run ~window_s ~step ~space ~holder ~args body = match run ~window_s (script ~step ~space ~holder ~args body) with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output
(* Every step carries the folder an agent page's downloads are saved in, so
   the step that arms a page's download wait saves there whichever ego
   process runs it. *)
let with_download_root t = function
  | `Assoc fields -> `Assoc (("downloads", str t.downloads.root) :: fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as args -> args
let run_step t ~window_s ~step ~args body =
  asked t.run ~window_s ~step ~space:(`Int t.space.id) ~holder:Agent_holds ~args:(with_download_root t args) body
let run_native_script t source =
  match t.run_native source with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output
let run_native_step t ~step ~args body =
  run_native_script t (script ~step ~space:(`Int t.space.id) ~holder:Agent_holds ~args:(with_download_root t args) body)
(* A read has no effect, so however it failed, nothing happened. *)
let ask t ~step ~args body =
  run_step t ~window_s:read_window_s ~step ~args body |> Result.map_error step_failure_message

let open_space ~run ~run_native ~now ~space ~version ~capture_directory ~downloads =
  let* () = Browser_configuration.validate_ego_space space in
  let reference=match space with Browser_configuration.Named_space name -> str name | Existing_space id -> `Int id in
  let* opened = asked run ~window_s:read_window_s ~step:"space.open" ~space:reference ~holder:Either_holds ~args:`Null
      "  emit({ok: true, value: {spaceId: task.spaceId, name: task.name, ownership: task.ownership}});"
    |> Result.map_error step_failure_message in
  (* A space the agent handed to the operator is still the agent's: a
     connection opened while they hold it refuses every step until take_over,
     so a restart during a hand-off does not strand the space. *)
  let* fields=match opened with
    | `Assoc fields when List.sort String.compare (List.map fst fields)=["name";"ownership";"spaceId"] -> Ok fields
    | _ -> Error "ego answered invalid or duplicate Space attachment fields" in
  let* id=Option.to_result ~none:"ego answered a Space without its ID" (List.assoc_opt "spaceId" fields) in
  let* name=Option.to_result ~none:"ego answered a Space without its name" (List.assoc_opt "name" fields) in
  let* bound_space=Browser_lane.ego_space_of_json (obj ["id",id;"name",name]) in
  let* ()=match space with
    | Browser_configuration.Existing_space id when id<>bound_space.id -> Error "ego answered a different Space ID; no replacement or fallback is permitted"
    | Existing_space _|Named_space _ -> Ok () in
  let* observation=Browser_ego_space_observation.of_sdk ~expected_id:bound_space.id ~observed_at:(now ()) opened in
  match List.assoc_opt "ownership" fields with
  | Some (`String ownership) ->
    (match space_owner_of_wire ownership with
     | Some (Agent_owner | Handed_to_operator) ->
       Ok {run; run_native; now; space=bound_space; version; capture_directory; downloads; published = Hashtbl.create 16;
         uploads = Browser_lane.Upload_lease.create_owner ();
         input=Input.create (); finish_state=Active; space_observation=Some observation; pages=[]; next_tab=0; captures=0}
     | Some Operator_owner | None ->
       Error (Printf.sprintf "ego task space %s belongs to %s, not to an agent" (Yojson.Safe.to_string reference) ownership))
  | _ -> Error "ego answered the task space without its owner"

let retirement_settlement t = match t.finish_state with
  | Active -> Error "ego Space retained; connection retirement is not task completion"
  | Finish_uncertain -> Error "ego Space completion is unconfirmed; preserve files and never replay finish"
  | Finished {settlement;_} -> settlement

(* A page blocked on a JavaScript dialog runs no page script until the
   dialog is answered: ego 0.6.0.16 refuses page.evaluate then, and a move
   would leave the dialog's answer to the browser. Reads, moves and input
   are refused before any effect; closing the tab and answering the dialog
   are not. ego's page.info() names the open dialog. *)
let dialog_blocked = "is blocked on a JavaScript dialog; list the tabs to read it, and answer it with accept_dialog or dismiss_dialog before another step"
let open_dialog page = "(await " ^ page ^ ".info()).dialog ?? null"

(* The dialog ego's page.info() names: CDP's javascriptDialogOpening, with
   defaultPrompt "" on a dialog that is not a prompt. *)
let ego_dialog json : (Browser_surface.dialog, string) result =
  match field "type" json, field "message" json, field "defaultPrompt" json with
  | Some (`String kind), Some (`String message), default_prompt ->
    (match Browser_surface.dialog_kind_of_wire kind, default_prompt with
     | Some Browser_surface.Prompt, Some (`String value) -> Ok {kind = Browser_surface.Prompt; message; default_value = Some value}
     | Some Browser_surface.Prompt, (None | Some _) -> Error "ego reported a prompt dialog without its default text"
     | Some (Browser_surface.Alert | Browser_surface.Confirm | Browser_surface.Beforeunload as kind), (None | Some _) ->
       Ok {kind; message; default_value = None}
     | None, (None | Some _) -> Error (Printf.sprintf "ego reported a JavaScript dialog of unknown type %S" kind))
  | _ -> Error "ego reported a JavaScript dialog without its type or message"

(* A listing is the space's tabs now: a number whose page is no longer
   listed is dropped, so a read of it is refused before any run. Each page
   the space manages says whether a JavaScript dialog blocks it, as a BiDi
   row does; a page whose dialog state could not be read is listed among
   the unavailable tabs with why, as BiDi lists a tab it could not read. *)
type listed_tab = Listed of { page : page; title : string; url : string; active : bool;
    dialog : Browser_surface.dialog option; provenance : Browser_surface.ego_page }
  | Unread of { page : page; url : string; reason : string; provenance : Browser_surface.ego_page }
let tab_rows t =
  let* listed = ask t ~step:"tabs.list" ~args:`Null (String.concat "\n" [
      "  const rows = [];";
      "  for (const tab of await task.tabs()) {";
      "    const row = {label: tab.label ?? null, targetId: tab.targetId, openedBy: tab.openedBy, title: tab.title, url: tab.url, active: tab.active, dialog: null, dialogUnread: null};";
      "    if (tab.label) { try { row.dialog = " ^ open_dialog "task.page(tab.label)" ^ "; } catch (error) { row.dialogUnread = String(error && error.message || error); } }";
      "    rows.push(row);";
      "  }";
      "  emit({ok: true, value: rows});" ]) in
  let row json =
    let* ()=match json with
      | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok ()
      | _ -> Error "ego listed duplicate or invalid tab fields" in
    let* provenance=match field "label" json,field "targetId" json,field "openedBy" json with
      | Some label,Some target_id,Some opened_by -> Browser_surface.ego_page_of_json
          (obj ["label",label;"targetId",target_id;"openedBy",opened_by])
      | _ -> Error "ego listed a tab without Page provenance" in
    let page=match provenance.label with Some label -> Managed label | None -> Unmanaged provenance.target_id in
    match field "title" json, field "url" json, field "active" json with
    | Some (`String title), Some (`String url), Some (`Bool active) ->
      (match field "dialog" json, field "dialogUnread" json with
       | Some `Null, Some `Null -> Ok (Listed {page; title; url; active; dialog = None;provenance})
       | Some (`Assoc _ as dialog), Some `Null ->
         (match ego_dialog dialog with
          | Ok dialog -> Ok (Listed {page; title; url; active; dialog = Some dialog;provenance})
          | Error reason -> Ok (Unread {page; url; reason;provenance}))
       | Some `Null, Some (`String reason) -> Ok (Unread {page; url; provenance;reason = "ego did not read whether a dialog blocks this page: " ^ reason})
       | _ -> Error "ego listed a tab without its dialog state")
    | _ -> Error "ego listed a tab without its title, URL or active state" in
  let* rows = match listed with
    | `List rows ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | json :: rest -> let* row = row json in collect (row :: acc) rest in
      collect [] rows
    | _ -> Error "ego answered a tab list that is not a list" in
  let page_of = function Listed {page; _} | Unread {page; _} -> page in
  let numbered = List.map (fun row -> remember t (page_of row), row) rows in
  t.pages <- List.filter (fun (page, _) -> List.exists (fun row -> page_of row = page) rows) t.pages;
  let tabs, unavailable = List.fold_left (fun (tabs, unavailable) (index, (id, row)) -> match row with
    | Listed {title; url; active; dialog; provenance; _} ->
      obj (["id",`Int id;"index",`Int index;"url",str url;"title",str title;"active",`Bool active;
        "egoPage",Browser_surface.ego_page_to_json provenance]
        @ match dialog with Some dialog -> ["dialog",Browser_surface.dialog_json dialog] | None -> []) :: tabs, unavailable
    | Unread {url; reason; provenance; _} ->
      tabs, obj ["id",`Int id;"index",`Int index;"error",str reason;"url",str url;
        "egoPage",Browser_surface.ego_page_to_json provenance] :: unavailable)
    ([], []) (List.mapi (fun index row -> index, row) numbered) in
  Ok (match unavailable with
    | [] -> `List (List.rev tabs)
    | _ :: _ -> obj ["tabs",`List (List.rev tabs);"complete",`Bool false;"unavailableTabs",`List (List.rev unavailable)])

let unmanaged_refused = "is unmanaged in the ego task space; this connection reads only the pages the space manages"

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
  "    const blocking = " ^ open_dialog "page" ^ ";";
  "    if (blocking !== null) emit({ok: false, before: true, error: \"the page \" + " ^ Yojson.Safe.to_string (str dialog_blocked) ^ "});";
  "    else {";
  body;
  "    }";
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
  let* filter = Browser_page_script.elements_filter_of_json (fun key -> field key args) in
  let* id,page = evaluate t args ~step:"page.elements"
      (Browser_page_script.parsed Browser_page_script.elements) (Browser_page_script.elements_args filter) in
  if Option.is_some (field "documentLoading" page) then Error Browser_page_script.document_loading_refused
  else with_tab id page

let scene t args =
  let* fields = match args with `Assoc fields -> Ok fields | _ -> Error "invalid scene arguments" in
  let* id,page = evaluate t args ~step:"page.scene" Browser_scene_script.read_call (obj (("mode",str "read")::fields)) in
  with_tab id page

(* ego's own snapshot of a page: the accessibility tree, each actionable node
   with the ref ego's element actions accept. A ref names a node of the page
   as it was read; after the page changes it needs a new snapshot. *)
let snapshot_options = function
  | Browser_lane.Snapshot_viewport -> `Null
  | (Snapshot_full_page | Snapshot_subtree _) as scope -> obj (Browser_lane.snapshot_scope_fields scope)
let snapshot t args =
  let* cap = match field "maxChars" args with
    | Some (`Int cap) -> Browser_page_script.text_cap (Some cap)
    | Some _ | None -> Error Browser_page_script.text_cap_refused in
  let* scope = match field "scope" args, field "root" args with
    | Some (`String scope), None -> Browser_lane.snapshot_scope_of_wire ~scope ~root:None
    | Some (`String scope), Some (`String root) -> Browser_lane.snapshot_scope_of_wire ~scope ~root:(Some root)
    | _ -> Error "invalid snapshot scope" in
  let* label = match field "tabId" args with
    | Some (`Int _) -> target t args
    | Some _ | None -> Error "a snapshot reads one tab; give its tabId" in
  let* value = ask t ~step:"page.snapshot" ~args:(obj ["label",label;"options",snapshot_options scope;"cap",`Int cap])
      (on_page (String.concat "\n" [
        "    const text = await (args.options === null ? page.snapshot() : page.snapshot(args.options));";
        "    if (typeof text !== \"string\") emit({ok: false, error: \"ego answered a snapshot that is not text\"});";
        "    else {";
        (* A cut never splits a surrogate pair. *)
        "      const end = text.length <= args.cap ? text.length : (/[\\uD800-\\uDBFF]/.test(text[args.cap - 1]) ? args.cap - 1 : args.cap);";
        "      emit({ok: true, value: {label: tab.label, url: await page.url(), title: await page.title(),";
        "        snapshot: text.slice(0, end), truncated: end < text.length, chars: text.length}});";
        "    }" ])) in
  match field "label" value, field "url" value, field "title" value, field "snapshot" value,
        field "truncated" value, field "chars" value with
  | Some (`String label), Some (`String url), Some (`String title), Some (`String text),
    Some (`Bool truncated), Some (`Int chars) ->
    let id = remember t (Managed label) in
    Ok (obj (["tabId",`Int id;"url",str url;"title",str title] @ Browser_lane.snapshot_scope_fields scope
      @ ["snapshot",str text;"truncated",`Bool truncated;"chars",`Int chars]))
  | _ -> Error "ego answered a snapshot without its page, text or length"

(* Native download events and receipted Fetch saves share the file broker,
   with distinct provenance. A completed file is <downloads>/<UUID> only. *)
type download_source = Native_download | Native_fetch
let download_source_name = function Native_download -> "native_download" | Native_fetch -> "fetch"
let download_row ~root ~tab json =
  let* source=match field "source" json with
    | Some (`String "native_download") -> Ok Native_download
    | Some (`String "fetch") -> Ok Native_fetch
    | None|Some _ -> Error "ego answered a download without recognized native provenance" in
  match field "id" json, field "url" json, field "suggestedFilename" json, field "state" json,
        field "path" json, field "reason" json with
  | Some (`String id), Some (`String url), Some (`String name), Some (`String state), Some path, Some reason ->
    let* () = match Uuidm.of_string id with Some _ -> Ok () | None -> Error "ego answered a download whose id is not a UUID" in
    let* status = match state, path, reason with
      | "pending", `Null, `Null -> Ok Browser_downloads.Pending
      | "completed", `String path, `Null when String.equal path (Filename.concat root id) ->
        Ok (Browser_downloads.Completed (Browser_downloads.File path))
      | "completed", `String _, `Null -> Error "ego answered a download saved outside the connection's download folder"
      | "interrupted", `Null, `String reason -> Ok (Browser_downloads.Interrupted reason)
      | _ -> Error (Printf.sprintf "ego answered a download in an unreadable state %S" state) in
    Ok ({Browser_downloads.id; context = string_of_int tab; url; filename = Some name; status},source)
  | _ -> Error "ego answered a download without its id, URL, name, state, path or reason"

let downloads t args =
  let* tab = match field "tabId" args with
    | Some (`Int tab) -> Ok tab
    | Some _ | None -> Error "downloads are read for one tab; give its tabId" in
  let* label = target t args in
  let* value = ask t ~step:"page.downloads" ~args:(obj ["label",label]) (String.concat "\n" [
      "  const registry = globalThis.mascDownloads;";
      "  emit({ok: true, value: registry === undefined ? {since: null, rows: []}";
      "    : {since: registry.since, rows: registry.rows.filter(row => row.label === args.label)}});" ]) in
  let* since, rows = match field "since" value, field "rows" value with
    | Some ((`Null | `String _) as since), Some (`List rows) -> Ok (since, rows)
    | _ -> Error "ego answered downloads without their rows or since when they were watched" in
  let* rows = List.fold_left (fun collected json ->
      let* collected = collected in
      let* row = download_row ~root:t.downloads.root ~tab json in
      Ok (row :: collected)) (Ok []) rows in
  let verify = Browser_bidi_downloads.verify_file ~root:t.downloads.root in
  let* records=List.fold_left (fun records (row,source) ->
    let* records=records in
    match Browser_downloads.published_json ~verify ~publish:t.downloads.publish ~published:t.published row with
    | `Assoc fields -> Ok (obj (("source",str (download_source_name source))::fields)::records)
    | _ -> Error "download publication returned an unreadable row") (Ok []) rows in
  Ok (obj ["tabId",`Int tab;"downloads",`List records;"watchingSince",since])

let png_signature = "\137PNG\r\n\026\n"
let remove path = match Unix.unlink path with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (code, _, _) ->
    Error (Printf.sprintf "the screenshot file %s was not removed: %s" path (Unix.error_message code))

(* ego writes the screenshot to a file and answers its path. The page's URL
   and viewport are read on each side of it, as the BiDi capture does. *)
let capture t args =
  let* options=Browser_lane.Capture.of_optional_json (field "options" args) in
  let* label = target t args in
  t.captures <- t.captures + 1;
  let path = Filename.concat t.capture_directory (Printf.sprintf "ego-capture-%d-%d.png" t.space.id t.captures) in
  let taken = run_native_step t ~step:"page.capture"
      ~args:(obj (["label",label;"state",str (page_function Browser_page_script.capture_state);"path",str path]
        @ Option.to_list (Option.map (fun value -> "options",Browser_lane.Capture.to_json value) options)))
      (on_page (String.concat "\n" [
         "    const state = pageCall(args.state, \"{}\");";
         "    const before = await page.evaluate(state);";
         "    const path = await page.screenshot({...args.options, path: args.path});";
         "    const after = await page.evaluate(state);";
         "    emit({ok: true, value: {label: tab.label, before, after, path, ...(args.options === undefined ? {} : {captureOptions: args.options})}});" ]))
      |> Result.map_error step_failure_message in
  let image = match taken with
    | Error _ -> Ok None
    | Ok _ ->
      let* image=Fs_compat.load_owned_regular_file_prefix ~ownership_root:t.capture_directory
        ~max_bytes:(Env_config_keeper.KeeperVision.max_image_bytes ()) path
        |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
      (match image with
       | Some image when image.truncated -> Error "screenshot exceeds Vision image size limit"
       | Some image -> Ok (Some image.content)
       | None -> Ok None) in
  let* () = remove path in
  let* value = taken in
  let* image = image in
  let* label = match field "label" value with Some (`String label) -> Ok label | _ -> Error "ego answered a capture without its page label" in
  let* () = if field "path" value = Some (str path) then Ok () else Error "ego wrote the screenshot somewhere else" in
  let* observed_options=Browser_lane.Capture.of_optional_json (field "captureOptions" value) in
  let* ()=if observed_options=options then Ok () else Error "ego answered different native screenshot options" in
  let* before = page_json (Option.value ~default:`Null (field "before" value)) in
  let* after = page_json (Option.value ~default:`Null (field "after" value)) in
  let* image = match image with
    | Some image when String.starts_with ~prefix:png_signature image -> Ok image
    | Some _ -> Error "ego wrote a screenshot that is not a PNG"
    | None -> Error "ego wrote no screenshot file" in
  match field "url" before, field "url" after, field "viewport" before, field "viewport" after, field "title" after with
  | Some (`String url), Some (`String after_url), Some viewport, Some after_viewport, Some title ->
    if url <> after_url || viewport <> after_viewport then Error "viewport_changed_during_capture"
    else Ok (obj (["tabId",`Int (remember t (Managed label));"url",str url;"title",title;"mimeType",str "image/png";
      "data",str (Base64.encode_string image)]
      @ (match options with None -> ["viewport",viewport]
          | Some options -> ["captureOptions",Browser_lane.Capture.to_json options])))
  | _ -> Error "the capture state lacks the page URL, title or viewport"

(* Effects use native managed Pages in the agent-controlled Space, including
   Pages explicitly adopted from an unknown origin. The SDK retains Page
   lifecycle/Space authority. No effect implicitly adopts an unmanaged tab. *)

(* ego hands a page's download only to a wait armed before the download
   starts (Page.waitForEvent), so every step that acts on a managed Page arms
   one wait there, once in each ego process, and the wait arms itself again.
   A download is saved as <downloads>/<id>, the folder the step's arguments
   carry, and ego's own copy is deleted. The rows live in that ego process:
   one started again after a stopped command lists what it saw from [since].
   A wait that fails for any reason, its page closing included, stops, and
   the next step on that page arms it again. Nothing in it may throw: a
   rejection no one handles ends ego's Node process. *)
let download_wait_ms = 2_147_483_647 (* the longest JavaScript timer *)
let download_watch = String.concat "\n" [
  "  const watchDownloads = (page, label) => {";
  "    const registry = globalThis.mascDownloads ??= {since: new Date().toISOString(), rows: [], watched: new Set()};";
  "    registry.handles ??= new Map();";
  "    if (registry.watched.has(label)) return;";
  "    registry.watched.add(label);";
  "    const root = args.downloads;";
  "    (async () => {";
  "      for (;;) {";
  "        let download;";
  "        try { download = await page.waitForEvent(\"download\", {timeout: " ^ string_of_int download_wait_ms ^ "}); }";
  "        catch (error) { break; }";
  "        try {";
  "          const row = {id: crypto.randomUUID(), label, source: \"native_download\", url: download.url(), suggestedFilename: download.suggestedFilename(), state: \"pending\", path: null, reason: null};";
  "          registry.rows.push(row);";
  "          registry.handles.set(row.id, {label, download});";
  "          const path = root + \"/\" + row.id;";
  "          download.saveAs(path).then(() => download.failure()).then(";
  "            failure => { if (failure === null) { row.state = \"completed\"; row.path = path; } else { row.state = \"interrupted\"; row.reason = String(failure); } },";
  "            error => { row.state = \"interrupted\"; row.reason = String(error && error.message || error); })";
  "            .then(() => { registry.handles.delete(row.id); return download.delete(); }).catch(() => {});";
  "        } catch (error) {}";
  "      }";
  "      registry.watched.delete(label);";
  "    })().catch(() => { registry.watched.delete(label); });";
  "  };" ]
let watch_managed_page = "    watchDownloads(task.page(args.label), args.label);"

let find_managed_tab = "  const tab = (await task.tabs()).find(item => item.label === args.label);"
let managed_refusals = [
  "  if (tab === undefined) emit({ok: false, before: true, error: \"browser tab is no longer present\"});" ]
let managed_page = String.concat "\n" (download_watch :: find_managed_tab :: managed_refusals @ ["  else {"; watch_managed_page])
(* The installed SDK guide treats unknown-origin Pages as user-owned when
   deciding whether to close. Explicit adoption grants Page operations but
   does not change that disposition; release returns the tab without closing. *)
let closable_page = String.concat "\n" (download_watch :: find_managed_tab :: managed_refusals @ [
  "  else if (tab.openedBy !== \"agent\") emit({ok: false, before: true, error: \"only an agent-created Page may be closed; release an unknown-origin Page instead\"});";
  "  else {"; watch_managed_page])
let unblocked_managed_page = String.concat "\n" (download_watch :: find_managed_tab
  :: ("  const blocking = tab === undefined ? null : " ^ open_dialog "task.page(args.label)" ^ ";")
  :: managed_refusals @ [
  "  else if (blocking !== null) emit({ok: false, before: true, error: \"tab \" + args.tabId + \" \" + " ^ Yojson.Safe.to_string (str dialog_blocked) ^ "});";
  "  else {"; watch_managed_page ])
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

(* Native finish is terminal. Capture the returned receipt without reading
   TaskSpace/Page properties afterward, including retained Pages' old labels. *)
let finish_receipt ~space_id ~keep value =
  let bad () = Error "invalid native Space completion receipt" in
  let labels = function
    | `List values ->
      let rec collect acc = function
        | [] when List.length acc=List.length (List.sort_uniq String.compare acc) -> Ok (List.rev acc)
        | `String label::rest when String.trim label<>"" -> collect (label::acc) rest
        | []|_::_ -> bad () in
      collect [] values
    | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`Assoc _ -> bad () in
  let* ()=match value with
    | `Assoc fields when List.sort String.compare (List.map fst fields)=
        ["closedManagedLabels";"closedSpace";"keptManagedLabels";"preservedUnmanagedCount";"spaceId"] -> Ok ()
    | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _|`Assoc _ -> bad () in
  match field "spaceId" value,field "closedSpace" value,field "keptManagedLabels" value,
      field "closedManagedLabels" value,field "preservedUnmanagedCount" value with
  | Some (`Int id),Some (`Bool closed),Some kept,Some removed,Some (`Int count) when id=space_id && count>=0 ->
    let* kept=labels kept in let* removed=labels removed in
    let policy_matches = match keep with
      | Browser_lane.Action.Keep_all -> not closed && removed=[]
      | Keep_labels requested ->
        List.for_all (fun label -> List.mem label kept) requested
        && (not closed || requested=[]) in
    if List.exists (fun label -> List.mem label removed) kept
      || not policy_matches
      || (closed && (kept<>[] || count<>0)) then bad ()
    else Ok closed
  | _ -> bad ()

let finish_space t keep =
  let unknown="Space completion may have happened; reconcile through Space metadata and the operator; never replay finish" in
  match t.finish_state with
  | Finished {keep=previous;receipt;_} when previous=keep -> Ok receipt
  | Finished _ -> Error (Live.Before_effect "this task already finished with a different keepPages policy")
  | Finish_uncertain -> Error (Live.Before_effect unknown)
  | Active ->
    (* Record before a yielding runner: cancellation/lost output stays uncertain. *)
    t.finish_state <- Finish_uncertain;
    t.space_observation <- None;
    let args=obj ["keep",Browser_lane.Action.keep_pages_to_json keep] in
    match run_native_step t ~step:"space.finish" ~args
        "  const receipt = await task.finish({keep: args.keep});\n  emit({ok: true, value: receipt});" with
    | Error failure ->
      (match failure with
       | Refused _|Unanswered (Unstarted _) -> t.finish_state <- Active
       | Unreadable _|Failed _|Unanswered (Exited _|Signaled _|Timed_out|Output_exceeded|Unobserved _) -> ());
      Error (effect_failure ~unknown failure)
    | Ok value ->
      let* closed=finish_receipt ~space_id:t.space.id ~keep value
        |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
      let settlement=if closed then
          (match Browser_lane.Upload_lease.release_owner t.uploads with
           | () -> Ok ()
           | exception ((Sys_error _|Unix.Unix_error _) as exn) -> Error ("upload cleanup unconfirmed: " ^ Printexc.to_string exn))
        else Error "native task completed with retained Space; browser-backed files remain owned" in
      let receipt=obj ["action",str "finish_space";"spaceId",`Int t.space.id;"spaceName",str t.space.name;
        "keepPages",Browser_lane.Action.keep_pages_to_json keep;"nativeReceipt",value] in
      t.finish_state <- Finished {keep;receipt;settlement};
      Ok receipt

let finish t = finish_space t (Browser_lane.Action.Keep_labels []) |> Result.map (fun _ -> ()) |> Result.map_error (function
  | Live.Before_effect detail|Outcome_unknown detail -> detail
  | Partial_failure {message;_}|Observed_failure {message;_} -> message)

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
  match run_native_step t ~step:"page.open" ~args:(obj ["url",str url]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      "  let page;";
      "  let refused = null;";
      "  try { page = await task.newPage(); } catch (error) { refused = reason(error); }";
      download_watch;
      "  if (page === undefined) emit({ok: false, before: true, error: refused});";
      "  else {";
      "    args.label = page.label;";
      watch_managed_page;
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

(* A step that moves a page answers where the page is now. The script catches
   what the page step threw and reads the tab's row after it, so a failure
   with a row is a known partial effect, as the BiDi connection settles a
   navigation; without a row the outcome is unknown. *)
let moved_page_answer = String.concat "\n" [
  "    const after = " ^ row_after ^ ";";
  "    emit({ok: true, value: {error: failure, tab: after === undefined ? null : {url: after.url, title: after.title}}});" ]
let unknown_move id = Printf.sprintf "list this connection's tabs and read tab %d before another step" id
let settled ~id ~action = function
  | Error failure -> Error (effect_failure ~unknown:(unknown_move id) failure)
  | Ok value ->
    let receipt tab = obj (["tabId",`Int id;"action",str action] @ tab_fields tab) in
    match field "error" value, field "tab" value with
    | Some `Null, Some (`Assoc _ as tab) -> Ok (receipt (Some tab))
    | Some (`String error), Some (`Assoc _ as tab) ->
      Error (Live.Partial_failure {tab_id = id; message = error; receipt = receipt (Some tab)})
    | Some (`String error), (None | Some _) -> Error (Live.Outcome_unknown (error ^ "; " ^ unknown_move id))
    | (None | Some _), _ ->
      Error (Live.Outcome_unknown (Printf.sprintf "ego answered the %s outside its answer frame; %s" action (unknown_move id)))

let goto t args =
  let* url = match field "url" args with
    | Some (`String url) -> Ok url
    | Some _ | None -> Error (Live.Before_effect "page.goto requires an absolute HTTP(S) URL") in
  let* () = http_url url in
  let* id = match field "tabId" args with
    | Some (`Int id) -> Ok id
    | Some _ | None -> Error (Live.Before_effect "page.goto on an ego connection needs the tabId of a managed Page") in
  let* label = label_of t id in
  settled ~id ~action:"goto" (run_native_step t ~step:"page.goto" ~args:(obj ["label",str label;"url",str url;"tabId",`Int id]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    let failure = null;";
      "    try { await task.page(args.label).goto(args.url); } catch (error) { failure = reason(error); }";
      moved_page_answer;
      "  }" ]))

let tab_window id interaction =
  window_s (Browser_lane.Page_act (Browser_lane.Action.On_tab {tab_id = id; frame_path = []; interaction}))

let reload t id =
  let* label = label_of t id in
  settled ~id ~action:"reload" (run_native_step t ~step:"page.reload" ~args:(obj ["label",str label;"tabId",`Int id]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    let failure = null;";
      "    try { await task.page(args.label).reload(); } catch (error) { failure = reason(error); }";
      moved_page_answer;
      "  }" ]))

(* ego's Page API has no back or forward, so the step goes through the
   page's CDP session: it reads the tab's history, refuses before acting when
   there is no entry that way, moves to the entry, and waits until the tab's
   current entry is that one and its document has loaded. The entry's index
   says the move happened even when the page at it has the same URL. A read
   while waiting can fail as the page changes renderer (ego lite 0.6.0.16
   answered "Not attached to an active page" once on a move back to
   chrome://new-tab-page/, and the next read was on the entry); such a
   failure says nothing about the move, so the wait goes on, within the
   run's window. *)
let history_poll_ms = 50
let traverse t id ~action ~delta ~side interaction =
  let* label = label_of t id in
  settled ~id ~action (run_step t ~window_s:(tab_window id interaction)
    ~step:"page.history" ~args:(obj ["label",str label;"tabId",`Int id;"delta",`Int delta;"side",str side;"pollMs",`Int history_poll_ms])
    (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    const page = task.page(args.label);";
      "    let history = null;";
      "    let unread = null;";
      "    try { history = await page.cdp(\"Page.getNavigationHistory\", {}); } catch (error) { unread = reason(error); }";
      "    const target = history === null ? -1 : history.currentIndex + args.delta;";
      "    const entry = history === null ? undefined : history.entries[target];";
      "    if (history === null) emit({ok: false, before: true, error: \"the history of tab \" + args.tabId + \" could not be read: \" + unread});";
      "    else if (entry === undefined) emit({ok: false, before: true, error: \"tab \" + args.tabId + \" has no \" + args.side + \" page in its history\"});";
      "    else {";
      "      let failure = null;";
      "      try {";
      "        await page.cdp(\"Page.navigateToHistoryEntry\", {entryId: entry.id});";
      "        const landed = async () => { try { return (await page.cdp(\"Page.getNavigationHistory\", {})).currentIndex === target; } catch (error) { return false; } };";
      "        while (!(await landed())) await page.waitForTimeout(args.pollMs);";
      "        await page.waitForLoadState();";
      "      } catch (error) { failure = reason(error); }";
      moved_page_answer;
      "    }";
      "  }" ]))

let close_tab t id =
  let* label = label_of t id in
  match run_step t ~window_s:(tab_window id Browser_lane.Action.Close_tab)
          ~step:"page.close" ~args:(obj ["label",str label;"tabId",`Int id]) (String.concat "\n" [
      closable_page;
      "    await task.page(args.label).close();";
      "    emit({ok: true, value: {closed: true}});";
      "  }" ]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "tab %d may have closed: list this connection's tabs" id) failure)
  | Ok _ ->
    t.pages <- List.filter (fun (_, known) -> known <> id) t.pages;
    Ok (obj ["tabId",`Int id;"action",str "close_tab";"closed",`Bool true])

(* A dialog is answered on a native managed Page in this Ego Space.
   The dialog is read before it is
   answered, since the answer closes it, and the receipt says which one was
   answered; ego answers false when none is open, and nothing happened. A
   dialog ego reported in a shape this connection cannot read is left out
   of the receipt, as BiDi leaves out one it did not track. Prompt text
   reaches ego as given, as BiDi passes userText. *)
let no_dialog_refused = "no dialog is open in this tab"
let answer_dialog t id ~accept text =
  let* label = label_of t id in
  let action, interaction = if accept then "accept_dialog", Browser_lane.Action.Accept_dialog text
    else "dismiss_dialog", Browser_lane.Action.Dismiss_dialog in
  match run_step t ~window_s:(tab_window id interaction) ~step:"page.dialog"
          ~args:(obj ["label",str label;"tabId",`Int id;"accept",`Bool accept;
            "text",(match text with Some text -> str text | None -> `Null)]) (String.concat "\n" [
      managed_page;
      "    const page = task.page(args.label);";
      "    const open = " ^ open_dialog "page" ^ ";";
      "    if (open === null) emit({ok: false, before: true, error: " ^ Yojson.Safe.to_string (str no_dialog_refused) ^ "});";
      "    else {";
      "      const answered = !args.accept ? await page.dismissDialog() : args.text === null ? await page.acceptDialog() : await page.acceptDialog(args.text);";
      "      if (answered === false) emit({ok: false, before: true, error: " ^ Yojson.Safe.to_string (str no_dialog_refused) ^ "});";
      "      else emit({ok: true, value: {dialog: open}});";
      "    }";
      "  }" ]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "the dialog of tab %d may have been answered: list this connection's tabs" id) failure)
  | Ok value ->
    let answered = match field "dialog" value with
      | Some dialog -> (match ego_dialog dialog with Ok dialog -> ["dialog",Browser_surface.dialog_json dialog] | Error _ -> [])
      | None -> [] in
    Ok (obj (["tabId",`Int id;"action",str action] @ answered))

(* ego shows a mouse step's [label] beside its own cursor highlight. It says
   who acts and what, from the same pieces as the BiDi connection's overlay
   badge (Browser_pointer_feedback): MASC, the actor, the interaction. *)
let cursor_label ~actor ~verb = String.concat " · " ["MASC"; Option.value actor ~default:"agent"; verb]

(* Ego resolves the file input, including labels, containers, refs and shadow
   roots. MASC validates staged regular files and holds their lease until the
   task space ends because Ego reads them when the page does. [chosen] is the
   staged metadata handed to the SDK, not a post-input DOM observation. *)
let native_upload_script = {js|async function nativeUpload(page, args) {
  try {
    const receipt = await page.setInputFiles(args.selector, args.paths);
    return {receipt: receipt ?? {}, error: null};
  } catch (error) { return {receipt: null, error: String(error?.message ?? error)}; }
}|js}
(* The name and size a page sees for one of the worker's copies. *)
let chosen_file path = match Unix.stat path with
  | {Unix.st_kind = Unix.S_REG; st_size; _} -> Some (obj ["name",str (Filename.basename path);"size",`Int st_size])
  | {Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _} -> None
  | exception Unix.Unix_error _ -> None
let chosen_files = function
  | [] -> Error (Live.Before_effect "upload needs at least one file")
  | _ :: _ as paths ->
    List.fold_right (fun path acc -> match acc, chosen_file path with
      | Ok rows, Some row -> Ok (row :: rows)
      | Ok _, None -> Error (Live.Before_effect ("the upload file " ^ Filename.basename path ^ " is not there"))
      | (Error _ as error), _ -> error) paths (Ok [])
let upload t id ~selector ~paths =
  let* label = label_of t id in
  let* chosen = chosen_files paths in
  Browser_lane.Upload_lease.claim ~owner:t.uploads ~paths;
  match run_native_step t ~step:"page.upload"
          ~args:(obj ["label",str label;"tabId",`Int id;"selector",str selector;"paths",`List (List.map str paths)])
          (String.concat "\n" [native_upload_script;unblocked_managed_page;
      "    const page = task.page(args.label);";
      "    const outcome = await nativeUpload(page, args);";
      "    if (outcome.error !== null) emit({ok: true, value: {error: outcome.error, dialog: null, tab: null}});";
      "    else {";
      "      const dialog = outcome.receipt.dialog ?? " ^ open_dialog "page" ^ ";";
      "      const tab = " ^ row_after ^ ";";
      "      emit({ok: true, value: {error: null, dialog, tab: tab === undefined ? null : {url: tab.url, title: tab.title}}});";
      "    }";"  }"]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "the file input of tab %d may have been set: read tab %d before another upload" id id) failure)
  | Ok value ->
    let receipt extra = obj (["tabId",`Int id;"action",str "upload";"chosen",`List chosen] @ tab_fields (field "tab" value) @ extra) in
    match field "error" value, field "dialog" value with
    | Some (`String detail), _ ->
      Error (Live.Outcome_unknown (Printf.sprintf "ego did not confirm setting the files (%s); read tab %d before another upload" (head detail) id))
    | Some `Null, Some (`Assoc _ as dialog) ->
      (match ego_dialog dialog with
       | Ok dialog -> Ok (receipt ["dialog",Browser_surface.dialog_json dialog])
       | Error reason -> Error (Live.Outcome_unknown ("the upload opened a dialog this connection cannot read: " ^ reason)))
    | Some `Null, Some `Null -> Ok (receipt [])
    | _ -> Error (Live.Outcome_unknown "ego answered an upload outside its frame")

(* A page that makes its file input only when a control is clicked gets the
   files through ego's file chooser. The run arms the SDK's default
   waitForFileChooser and clicks the native opener locator
   through ego with the cursor label and hands the chooser the worker's
   copies. The click is the effect: a chooser whose SDK wait fails, or one that takes one file when more were given, is
   reported after it. The page may keep that input out of its document, so
   the receipt lists the files handed to the chooser ([chosen]) rather than
   what an input holds. The lease is held as for a file input. A chooser
   left unanswered makes ego refuse every later chooser wait in the same
   process ("this Page is already waiting for a file chooser", 0.6.0.16),
   and one process serves this connection, so the run closes a chooser it
   does not fill with setFiles([]), which hands the page nothing. *)
let choose_files ?actor t id ~opener ~paths =
  let* () = Input.admit t.input |> Result.map_error (fun detail -> Live.Before_effect detail) in
  let* label = label_of t id in
  let* chosen = chosen_files paths in
  Browser_lane.Upload_lease.claim ~owner:t.uploads ~paths;
  match run_native_step t ~step:"page.choose_files"
          ~args:(obj ["label",str label;"tabId",`Int id;"opener",str opener;"paths",`List (List.map str paths);
            "cursor",str (cursor_label ~actor ~verb:"upload")])
          (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    const page = task.page(args.label);";
      "      let failure = null, chooser = null, set = null;";
      "      const waiting = page.waitForFileChooser();";
      "      waiting.catch(() => {});";
      "      try { await page.click(args.opener, {label: args.cursor}); }";
      "      catch (error) { failure = \"ego did not click the opener: \" + reason(error); }";
      "      try { chooser = await waiting; }";
      "      catch (error) { if (failure === null) failure = \"the opener opened no file chooser: \" + reason(error); }";
      "      if (chooser !== null) {";
      "        const close = async () => { try { await chooser.setFiles([]); return \"\"; }";
      "          catch (error) { return \"; closing the chooser failed too (\" + reason(error) + \"), so this tab's next chooser upload may be refused\"; } };";
      "        let multiple = true;";
      "        if (failure === null) {";
      "          try { multiple = args.paths.length === 1 || await chooser.isMultiple(); } catch (error) { failure = \"ego did not say whether the chooser takes several files: \" + reason(error); }";
      "        }";
      "        if (failure === null && !multiple) failure = \"the file chooser takes one file, so it was closed with none\";";
      "        if (failure === null) {";
      "          try { set = await chooser.setFiles(args.paths); } catch (error) { failure = \"ego did not set the files: \" + reason(error); }";
      "        } else failure += await close();";
      "      }";
      "      const dialog = set?.dialog ?? (failure === null ? " ^ open_dialog "page" ^ " : null);";
      "      const tab = " ^ row_after ^ ";";
      "      emit({ok: true, value: {error: failure, dialog, tab: tab === undefined ? null : {url: tab.url, title: tab.title}}});";
      "  }" ]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "the opener of tab %d may have been clicked: read tab %d before another upload" id id) failure)
  | Ok value ->
    let receipt extra = obj (["tabId",`Int id;"action",str "upload";"chosen",`List chosen] @ tab_fields (field "tab" value) @ extra) in
    match field "error" value, field "dialog" value with
    | Some (`String detail), _ ->
      Error (Live.Outcome_unknown (Printf.sprintf "%s; read tab %d before another upload" (head detail) id))
    | Some `Null, Some (`Assoc _ as dialog) ->
      (match ego_dialog dialog with
       | Ok dialog -> Ok (receipt ["dialog",Browser_surface.dialog_json dialog])
       | Error reason -> Error (Live.Outcome_unknown ("the upload opened a dialog this connection cannot read: " ^ reason)))
    | Some `Null, Some `Null -> Ok (receipt [])
    | _ -> Error (Live.Outcome_unknown "ego answered an upload outside its frame")

(* Input acts on a native managed Page, checked in the run that acts.
   The page scripts the BiDi connection runs find the
   target, check that the document, URL and viewport are the observed ones,
   and make the DOM edits, so a selector or node means the same on both;
   ego moves the mouse and presses the keys. *)

(* ego reads and acts inside frames without a frame path: its viewport
   snapshot holds each iframe's content with refs, a subtree snapshot rooted
   at the iframe's ref reads one frame, a ref from it acts inside that frame,
   and a role or text target is looked for in frames when the top document
   has none (cross-origin frames included, 0.6.0.16). Input frame paths are
   refused here with the supported route. Frame_read is refused by the live
   transport gate before this peer; the tool description explains snapshots. *)
let frame_input_refused =
  "an ego connection acts inside frames through target, with no framePath: a ref from the frame's snapshot, or a role or text target, which ego also finds inside frames"
let frame_upload_refused = "an ego connection uploads through a native selector or snapshot ref, without framePath; use a locator or ref from that frame"

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
  | Move -> ["        await page.mouse.move(args.x, args.y, {label: args.cursor});"]
  | Press _ -> ["        await page.mouse.click(args.x, args.y, {button: args.button, clickCount: args.count, label: args.cursor});"]
  | Wheel _ -> ["        await page.mouse.move(args.x, args.y, {label: args.cursor});";
                "        await page.mouse.wheel(args.dx, args.dy, {label: args.cursor});"]
let motion_fields = function
  | Move -> []
  | Press {button; count} -> ["button",str (button_name button);"count",`Int count]
  | Wheel {x; y} -> ["dx",`Int x;"dy",`Int y]

(* Native ego calls, not synthetic page events. A failed down may already
   have pressed, so its finally block always attempts release. mouse.down,
   move and up answer void and swallow a dialog interruption, so nothing here
   declares that the button came up and the result claims nothing about it. *)
let drag_input = {js|
async function dragInput(page, path, label) {
  let error = null;
  const reason = failure => String(failure?.message ?? failure);
  try {
    await page.mouse.move(path[0].x, path[0].y, {label});
    try {
      await page.mouse.down({button:'left'});
      for (const point of path.slice(1)) await page.mouse.move(point.x, point.y, {label});
    } finally {
      await page.mouse.up({button:'left'});
    }
  } catch (failure) { error = reason(failure); }
  return {error};
}
|js}

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

(* An input can stop at a JavaScript dialog. The receipt reports the tab's
   row and dialog; answering the dialog is separate from input-release
   settlement and does not establish that the original gesture completed. *)
let dialog_receipt ~id ~verb ~unknown value =
  let guard = page_json (Option.value ~default:`Null (field "guard" value)) in
  let dialog = match field "dialog" value with Some opened -> ego_dialog opened | None -> Error "ego reported no dialog" in
  match field "error" value, guard, field "tab" value, dialog with
  | Some (`String error), (Ok _ | Error _), (None | Some _), (Ok _ | Error _) ->
    Error (Live.Outcome_unknown (head error ^ "; the page opened a JavaScript dialog; " ^ unknown))
  | Some `Null, Ok observed, Some (`Assoc _ as tab), Ok dialog ->
    (match field "url" observed with
     | Some (`String url) ->
       receipt_of ~id ~verb (obj (("urlBefore",str url) :: tab_fields (Some tab) @ ["dialog",Browser_surface.dialog_json dialog]))
       |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown))
     | Some _ | None -> Error (Live.Outcome_unknown ("the input was sent and its guard lacks the page URL; " ^ unknown)))
  | Some `Null, Error detail, (None | Some _), (Ok _ | Error _) | Some `Null, Ok _, (None | Some _), Error detail ->
    Error (Live.Outcome_unknown ("the input was sent and " ^ detail ^ "; " ^ unknown))
  | Some `Null, Ok _, (None | Some _), Ok _ ->
    Error (Live.Outcome_unknown ("the input opened a JavaScript dialog and its tab was not listed; " ^ unknown))
  | (None | Some _), (Ok _ | Error _), (None | Some _), (Ok _ | Error _) ->
    Error (Live.Outcome_unknown ("ego answered the input outside its answer frame; " ^ unknown))

(* One run: the guard script checks that the page is the observed one and
   refuses before any input if not, the input is sent, and the receipt script
   reads where the page is. *)
let guarded_input ?(holds_button=false) t ~id ~label ~deadline ~verb ~step ~guard ~input ~lines ~fields =
  let unknown = Printf.sprintf "read tab %d before another step" id in
  let* ()=if holds_button then Input.begin_holding t.input ~tab_id:id ~page_label:label ~operation:step
    |> Result.map_error (fun detail -> Live.Before_effect detail) else Ok () in
  let response = run_step t ~window_s:(left t deadline) ~step
          ~args:(obj (["label",str label;"tabId",`Int id;"guard",str (page_function guard);
            "input",str (Yojson.Safe.to_string input);
            "receipt",str (page_function Browser_interaction.pointer_receipt_script)] @ fields))
          (String.concat "\n" ([
      page_call;
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    const page = task.page(args.label);";
      "    const guard = await page.evaluate(pageCall(args.guard, args.input));";
      "    if (guard.pageError !== undefined) emit({ok: false, before: true, error: guard.pageError});";
      "    else {";
      "      let failure = null;";
      "      try {" ] @ lines @ [
      "      } catch (error) { failure = reason(error); }";
      (* An unread dialog state is left to the receipt script, which ego
         refuses while a dialog is open. *)
      "      let opened = null;";
      "      try { opened = " ^ open_dialog "page" ^ "; } catch (error) { opened = null; }";
      "      if (opened !== null) {";
      "        const after = " ^ row_after ^ ";";
      "        emit({ok: true, value: {guard, dialog: opened, tab: after === undefined ? null : {url: after.url, title: after.title}, error: failure}});";
      "      } else {";
      "        const receipt = await page.evaluate(pageCall(args.receipt, \"{}\"));";
      "        emit({ok: true, value: {guard, receipt, error: failure}});";
      "      }";
      "    }";
      "  }" ])) in
  (* A button held through raw mouse calls is never settled here: the SDK
     declares no outcome for them, so the input stays unconfirmed until the
     operator's reset. *)
  if holds_button then (match response with
    | Error (Refused _ | Unanswered (Unstarted _)) -> Input.not_started t.input
    | Ok _ | Error (Unanswered (Exited _ | Signaled _ | Timed_out | Output_exceeded | Unobserved _)
        | Unreadable _ | Failed _) -> ());
  match response with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value when holds_button ->
      let reported = match field "error" value with Some (`String error) -> head error ^ "; " | Some _ | None -> "" in
      let opened = match field "dialog" value with
        | Some (`Assoc _) -> "the page opened a JavaScript dialog; " | Some _ | None -> "" in
      Error (Live.Outcome_unknown (reported ^ opened ^ "ego drag cannot confirm input release; " ^ unknown))
  | Ok value when (match field "dialog" value with Some (`Assoc _) -> true | Some _ | None -> false) ->
    dialog_receipt ~id ~verb ~unknown value
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
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    const page = task.page(args.label);";
      "    let result = null, failure = null;";
      "    try { result = await page.evaluate(pageCall(args.fn, args.input)); } catch (error) { failure = reason(error); }";
      "    let opened = null;";
      "    if (failure !== null) { try { opened = " ^ open_dialog "page" ^ "; } catch (error) { opened = null; } }";
      "    if (failure === null) emit({ok: true, value: {result}});";
      "    else if (opened === null) emit({ok: false, error: failure});";
      "    else {";
      "      const after = " ^ row_after ^ ";";
      "      emit({ok: true, value: {dialog: opened, tab: after === undefined ? null : {url: after.url, title: after.title}}});";
      "    }";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    match field "dialog" value, field "result" value with
    (* ego stops waiting for a page script once it opens a dialog; the
       script goes on in the page after the answer, so its own receipt is
       not read. *)
    | Some (`Assoc _ as opened), _ ->
      (match field "tab" value, ego_dialog opened with
       | Some (`Assoc _ as tab), Ok dialog ->
         Error (Live.Partial_failure {tab_id = id;
           receipt = obj (["tabId",`Int id;"action",str verb] @ tab_fields (Some tab) @ ["dialog",Browser_surface.dialog_json dialog]);
           message = Printf.sprintf "The page opened a JavaScript dialog while the %s ran, so its own receipt was not read. Answer the dialog with accept_dialog or dismiss_dialog, then read tab %d." verb id})
       | (None | Some _), Error detail -> Error (Live.Outcome_unknown ("the input opened a JavaScript dialog and " ^ detail ^ "; " ^ unknown))
       | (None | Some _), Ok _ -> Error (Live.Outcome_unknown ("the input opened a JavaScript dialog and its tab was not listed; " ^ unknown)))
    | (None | Some _), None -> Error (Live.Outcome_unknown ("ego answered the input outside its answer frame; " ^ unknown))
    | (None | Some _), Some value ->
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

(* ego owns locator resolution, actionability and auto-scrolling. MASC checks
   ownership, dialog and the observed URL before entering its Page method.
   Once that method starts, any failure is uncertain and is never replayed. A
   receipt lists the pages the action opened and a JavaScript dialog it
   raised. The tab's row in the space says where the page is after, also
   while that dialog is open. *)
let ego_locator = function
  | Browser_lane.Target_ref node -> "@" ^ string_of_int node
  | Target_role {role;name;exact} ->
    Printf.sprintf "loc=role:%s[name%s%s]" role (if exact then "=" else "*=") (Yojson.Safe.to_string (str name))
  | Target_text {text;exact} -> "text=" ^ (if exact then Yojson.Safe.to_string (str text) else text)
type target_operation = Target_click | Target_fill of string | Target_hover | Target_double_click
  | Target_select of Browser_lane.option_selection | Target_drag of string
let target_input_script = {js|async function nativeTargetInput(page, args) {
  const reason = error => String(error && error.message || error);
  let refusal = null, urlBefore = null;
  const checkUrl = async () => {
    try {
      urlBefore = await page.url();
      if (args.expectedUrl !== null && urlBefore !== args.expectedUrl)
        refusal = "the tab is at " + urlBefore + ", not at expectedUrl; read it again";
    } catch (error) { refusal = reason(error); }
  };
  if (!["click", "fill", "hover", "double_click", "select_option", "drag_to"].includes(args.action))
    return {before: true, error: "unsupported snapshot target action"};
  await checkUrl();
  if (refusal !== null) return {before: true, error: refusal};
  let receipt = null, failure = null;
  try {
    switch (args.action) {
      case "click": receipt = await page.click(args.target, {label: args.cursor}); break;
      case "fill": receipt = await page.fill(args.target, args.text); break;
      case "hover": receipt = await page.hover(args.target, {label: args.cursor}); break;
      case "double_click": receipt = await page.dblclick(args.target, {label: args.cursor}); break;
      case "select_option": receipt = {selectedValues: await page.selectOption(args.target, args.selection)}; break;
      case "drag_to": receipt = await page.dragAndDrop(args.target, args.destination, {label: args.cursor}); break;
    }
  } catch (error) {
    failure = reason(error);
    // The SDK owns this gesture and its release attempts. mouse.up() can
    // swallow a dialog interruption as void; another release could also
    // duplicate the SDK's original mouseup. Keep uncertainty on failure.
  }
  return {urlBefore, receipt, error: failure};
}|js}
(* An input the SDK showed released is settled. One that was never held keeps the readiness it had. *)
let settle_input t = function
  | Browser_ego_release.No_hold -> Input.not_started t.input
  | Browser_ego_release.Released proof -> Input.command_settled t.input proof
let native_input t ~id ~label ~cursor ~expected_url ~locator ~reference ~operation =
  let verb, text = match operation with
    | Target_click -> "click", `Null
    | Target_fill text -> "fill", str text
    | Target_hover -> "hover", `Null
    | Target_double_click -> "double_click", `Null
    | Target_select _ -> "select_option", `Null
    | Target_drag _ -> "drag_to", `Null in
  let selection = match operation with
    | Target_select (Browser_lane.Single_option value) -> obj ["value",str value]
    | Target_select (Browser_lane.Multiple_options values) -> `List (List.map (fun value -> obj ["value",str value]) values)
    | Target_click | Target_fill _ | Target_hover | Target_double_click | Target_drag _ -> `Null in
  let unknown = Printf.sprintf "read tab %d before another step" id in
  let holds_button = match operation with Target_drag _ -> true
    | Target_click | Target_fill _ | Target_hover | Target_double_click | Target_select _ -> false in
  let* ()=if holds_button then Input.begin_holding t.input ~tab_id:id ~page_label:label ~operation:"native_target_input"
    |> Result.map_error (fun detail -> Live.Before_effect detail) else Ok () in
  let response = run_native_step t ~step:"page.target_input"
      ~args:(obj ["label",str label;"tabId",`Int id;"expectedUrl",(match expected_url with Some url -> str url | None -> `Null);"target",str locator;
        "action",str verb;"text",text;"selection",selection;"cursor",str cursor;
        "destination",(match operation with Target_drag destination -> str destination | Target_click | Target_fill _ | Target_hover | Target_double_click | Target_select _ -> `Null)])
      (String.concat "\n" [
        target_input_script;
        unblocked_managed_page;
        "    const page = task.page(args.label);";
        "    const outcome = await nativeTargetInput(page, args);";
        "    if (outcome.before === true) emit({ok: false, before: true, error: outcome.error});";
        "    else {";
        "      const after = " ^ row_after ^ ";";
        "      emit({ok: true, value: {...outcome, tab: after === undefined ? null : {url: after.url, title: after.title}}});";
        "    }";
        "  }" ]) in
  if holds_button then (match response with
    | Error (Refused _ | Unanswered (Unstarted _)) -> Input.not_started t.input
    | Ok _ | Error (Unanswered (Exited _ | Signaled _ | Timed_out | Output_exceeded | Unobserved _) | Failed _ | Unreadable _) -> ());
  match response with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let outcome detail = Error (Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
    match field "error" value, field "urlBefore" value, field "receipt" value, field "tab" value with
    | Some (`String error), _, _, _ -> outcome (head error)
    | Some `Null, Some (`String url_before), Some (`Assoc receipt), Some ((`Null | `Assoc _) as tab) ->
      (* dragAndDrop answers with the SDK's receipt, and the drag settles only from a reply read whole. A receipt
         with a member the SDK does not declare is not an answer, so it is read as neither released nor served. *)
      let answer = Browser_ego_release.answer_of_json (`Assoc receipt) in
      let declared = match operation with
        | Target_drag _ ->
          (match answer with
           | Browser_ego_release.Unreleased Browser_ego_release.Undeclared_answer ->
             Error "ego answered the drag with a receipt the SDK does not declare"
           | Browser_ego_release.Receipt_without_dialog
           | Browser_ego_release.Unreleased (Browser_ego_release.Receipt_with_dialog | Void_answer | Never_returned) -> Ok ())
        | Target_click | Target_fill _ | Target_hover | Target_double_click | Target_select _ -> Ok () in
      let popups = match List.assoc_opt "popups" receipt with
        | None -> Ok []
        | Some (`List popups) ->
          List.fold_right (fun popup acc -> match acc, field "label" popup with
            | Ok rows, Some (`String label) when label <> "" ->
              Ok (obj ["tabId",`Int (remember t (Managed label));"label",str label] :: rows)
            | Ok _, _ -> Error "ego reported a popup without its page label"
            | (Error _ as error), _ -> error) popups (Ok [])
        | Some _ -> Error "ego reported popups that are not a list" in
      let dialog = match List.assoc_opt "dialog" receipt with
        | None | Some `Null -> Ok []
        | Some json -> Result.map (fun dialog -> ["dialog",Browser_surface.dialog_json dialog]) (ego_dialog json) in
      (match declared, popups, dialog with
       | Ok (), Ok popups, Ok dialog ->
         let* selected = match operation, List.assoc_opt "selectedValues" receipt with
           | Target_select _, Some (`List values) when List.for_all (function `String _ -> true | _ -> false) values ->
             Ok ["selectedValues",`List values]
           | Target_select _, (None | Some _) -> outcome "ego answered selection without its selected values"
           | (Target_click | Target_fill _ | Target_hover | Target_double_click | Target_drag _), (None | Some _) -> Ok [] in
         if holds_button then (match Browser_ego_release.judge [0,answer] with
           | Browser_ego_release.Settled settled -> settle_input t settled
           | Browser_ego_release.Unconfirmed _ -> ());
         Ok (obj (["tabId",`Int id;"action",str verb] @ reference @ ["urlBefore",str url_before]
                  @ tab_fields (Some tab)
                  @ (match popups with [] -> [] | _ :: _ -> ["popups",`List popups])
                  @ selected
                  @ dialog))
       | Error detail, _, _ | _, Error detail, _ | _, _, Error detail -> outcome detail)
    | _ -> outcome "ego answered the input outside its answer frame"

let activate_tab t ~id ~label ~expected_url =
  let unknown=Printf.sprintf "activation of tab %d is unconfirmed; observe the same Space before another command" id in
  let* expected_url=Option.to_result ~none:(Live.Before_effect "activate_tab requires expectedUrl") expected_url in
  match run_native_step t ~step:"page.activate"
      ~args:(obj ["label",str label;"expectedUrl",str expected_url])
      (String.concat "\n" ["    const activate = " ^ Browser_ego_activation.script ^ ";";
        "    const outcome = await activate(task, args);";
        "    if (outcome.before === true) emit({ok:false, before:true, error:outcome.error});";
        "    else emit({ok:true, value:outcome});"]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value -> Browser_ego_activation.receipt ~space_id:t.space.id ~tab_id:id ~label ~expected_url value
      |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown))

let interact ?actor t args =
  let before result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  let* fields = before (match args with `Assoc fields -> Ok fields | _ -> Error "invalid interaction") in
  let* request = before (Browser_interaction.parse (obj (("lane",str Browser_lane.Lane_name.(to_wire Live)) :: fields))) in
  let* () = match request.frame_path with
    | [] -> Ok ()
    | _ :: _ -> Error (Live.Before_effect frame_input_refused) in
  let id = request.tab_id in
  let verb = Browser_lane.interaction_verb request.action in
  let refused = Error (Live.Before_effect (verb ^ " is not served by an ego connection")) in
  let* label = label_of t id in
  let deadline = command_deadline t (Browser_lane.Page_interact {tab_id = id; frame_path = []; expected_url = request.expected_url; action = request.action}) in
  let input ~expected_url action = Browser_lane.interaction_args ~tab_id:id ~frame_path:[] ~expected_url action in
  let* () = Input.admit t.input |> Result.map_error (fun detail -> Live.Before_effect detail) in
  let* () = match request.action with
    | Browser_lane.Drag_to {duration_ms;_} | Browser_lane.Drag {duration_ms;_} when duration_ms <> 0 ->
        Error (Live.Before_effect "ego drag requires durationMs=0; movement timing is not exposed by its mouse API")
    | Browser_lane.Drag_to _ | Browser_lane.Drag _
    | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Set_zoom _
    | Browser_lane.Set_viewport _ | Browser_lane.Double_click_at _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
    | Browser_lane.Scroll _ | Browser_lane.Hover_at _ | Browser_lane.Tap_at _ | Browser_lane.Swipe _
    | Browser_lane.Click_at _ | Browser_lane.Scroll_at _ | Browser_lane.Follow_link _
    | Browser_lane.Fill_node _ | Browser_lane.Click _ | Browser_lane.Click_node _ | Browser_lane.Hover _
    | Browser_lane.Double_click _ | Browser_lane.Click_target _ | Browser_lane.Fill_target _ | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ -> Ok () in
  let* expected_url, action =
    let needs_resolution = match request.action with
      | Browser_lane.Click _ -> false
      | Browser_lane.Hover target | Browser_lane.Double_click target ->
        (match target with Browser_lane.Selector _ -> false | Browser_lane.Scene_node _ -> true)
      | Browser_lane.Drag_to {source;destination;via;_} ->
        (match source,destination with
         | Browser_lane.Selector _, Browser_lane.Selector _ -> (match via with [] -> false | _::_ -> true)
         | Browser_lane.Scene_node _, (Browser_lane.Selector _ | Browser_lane.Scene_node _)
         | Browser_lane.Selector _, Browser_lane.Scene_node _ -> true)
      | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _ | Browser_lane.Set_zoom _
      | Browser_lane.Set_viewport _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
      | Browser_lane.Scroll _ | Browser_lane.Hover_at _
      | Browser_lane.Tap_at _ | Browser_lane.Swipe _ | Browser_lane.Click_at _ | Browser_lane.Double_click_at _
      | Browser_lane.Scroll_at _ | Browser_lane.Drag _ | Browser_lane.Follow_link _ | Browser_lane.Click_node _
      | Browser_lane.Fill_node _ | Browser_lane.Click_target _ | Browser_lane.Fill_target _
      | Browser_lane.Hover_target _ | Browser_lane.Double_click_target _ -> Browser_interaction.needs_pointer_resolution request.action in
    if needs_resolution then
      let* resolved = resolve t ~label ~deadline (input ~expected_url:request.expected_url request.action) in
      before (Browser_interaction.resolve_pointer_input request.action resolved)
    else Ok (request.expected_url, request.action) in
  let cursor_text = cursor_label ~actor ~verb in
  let cursor = "cursor",str cursor_text in
  let pointer (viewport : Browser_lane.Pointer.viewport) point motion =
    let x, y = Browser_lane.Pointer.viewport_pixels viewport point in
    guarded_input t ~id ~label ~deadline ~verb ~step:"page.pointer" ~guard:Browser_interaction.pointer_guard_script
      ~input:(input ~expected_url action) ~lines:(motion_lines motion) ~fields:(["x",`Int x;"y",`Int y;cursor] @ motion_fields motion) in
  let keyboard keys =
    guarded_input t ~id ~label ~deadline ~verb ~step:"page.keyboard" ~guard:Browser_interaction.keyboard_guard_script
      ~input:(input ~expected_url action) ~lines:(keys_lines keys) ~fields:(keys_fields keys) in
  let drag ~from ~to_ ~viewport ~via =
    let pixels point =
      let x,y = Browser_lane.Pointer.viewport_pixels viewport point in obj ["x",`Int x;"y",`Int y] in
    let path = from :: (Browser_lane.Pointer.drag_waypoints ~start:from ~destination:to_ via @ [to_;to_]) in
    guarded_input ~holds_button:true t ~id ~label ~deadline ~verb ~step:"page.drag"
      ~guard:Browser_interaction.pointer_guard_script ~input:(input ~expected_url action)
      ~lines:["        const outcome = await (" ^ drag_input ^ ")(page, args.path, args.cursor);";
        "        if (outcome.error !== null) throw new Error(outcome.error);"]
      ~fields:["path",`List (List.map pixels path);cursor] in
  let on_target ~target operation = match expected_url with
    | Some _ -> native_input t ~id ~label ~cursor:cursor_text ~expected_url
        ~locator:(ego_locator target) ~reference:["target",Browser_lane.snapshot_target_to_json target] ~operation
    | None -> Error (Live.Before_effect "a snapshot target requires expectedUrl") in
  let on_selector selector operation = native_input t ~id ~label ~cursor:cursor_text ~expected_url
      ~locator:selector ~reference:["selector",str selector] ~operation in
  match action with
  | Browser_lane.Activate_tab -> activate_tab t ~id ~label ~expected_url
  | Browser_lane.Click selector -> on_selector selector Target_click
  | Browser_lane.Fill {selector;text} -> on_selector selector (Target_fill text)
  | Browser_lane.Select_option {selector;selection} -> on_selector selector (Target_select selection)
  | Browser_lane.Hover (Browser_lane.Selector selector) -> on_selector selector Target_hover
  | Browser_lane.Double_click (Browser_lane.Selector selector) -> on_selector selector Target_double_click
  | Browser_lane.Drag_to {source;destination;via;_} ->
    (match source,destination with
     | Browser_lane.Selector source, Browser_lane.Selector destination ->
       (match via with
        | [] -> native_input t ~id ~label ~cursor:cursor_text ~expected_url ~locator:source
            ~reference:["source",obj ["selector",str source];"destination",obj ["selector",str destination]]
            ~operation:(Target_drag destination)
        | _::_ -> refused)
     | Browser_lane.Scene_node _, (Browser_lane.Selector _ | Browser_lane.Scene_node _)
     | Browser_lane.Selector _, Browser_lane.Scene_node _ -> refused)
  | Browser_lane.Click_at {point; viewport; button} -> pointer viewport point (Press {button; count = 1})
  | Browser_lane.Double_click_at {point; viewport} -> pointer viewport point (Press {button = Browser_lane.Pointer.Primary; count = 2})
  | Browser_lane.Hover_at {point; viewport} -> pointer viewport point Move
  | Browser_lane.Scroll_at {point; viewport; x; y} -> pointer viewport point (Wheel {x; y})
  | Browser_lane.Drag {from;to_;viewport;via;duration_ms=_} -> drag ~from ~to_ ~viewport ~via
  | Browser_lane.Type_text {text; _} -> let* () = before (Browser_lane.Keyboard.validate_text text) in keyboard (Text text)
  | Browser_lane.Press_key {key; _} ->
    (match key.key with
     | Browser_lane.Keyboard.Character scalar when Uchar.to_int scalar > last_pressable_character ->
       Error (Live.Before_effect press_refused)
     | Browser_lane.Keyboard.Character _ | Browser_lane.Keyboard.Named _ -> keyboard (Chord key))
  | Browser_lane.Fill_node _ | Browser_lane.Scroll _ | Browser_lane.Follow_link _ ->
    dom_input t ~id ~label ~deadline ~verb (input ~expected_url action)
  | Browser_lane.Click_node _ | Browser_lane.Hover (Browser_lane.Scene_node _) | Browser_lane.Double_click (Browser_lane.Scene_node _) ->
    Error (Live.Before_effect "unresolved semantic pointer target")
  | Browser_lane.Click_target target -> on_target ~target Target_click
  | Browser_lane.Fill_target {target; text} -> on_target ~target (Target_fill text)
  | Browser_lane.Hover_target target -> on_target ~target Target_hover
  | Browser_lane.Double_click_target target -> on_target ~target Target_double_click
  | Browser_lane.Tap_at _ | Browser_lane.Swipe _
  | Browser_lane.Set_zoom _ | Browser_lane.Set_viewport _ -> refused

(* The whole space goes to the operator for a step only a person can take;
   from then on the frame refuses every step until take_over. A handOff that
   failed may still have happened; do not probe or replay it without the
   operator's explicit confirmation. *)
let hand_off t =
  t.space_observation <- None;
  let unknown = Printf.sprintf
    "control of ego Space #%d is unconfirmed; ask the operator and wait for explicit confirmation before any further command"
    t.space.id in
  match run_step t ~window_s:(window_s (Browser_lane.Page_act (Browser_lane.Action.Control Browser_lane.Action.Hand_off)))
          ~step:"space.hand_off" ~args:`Null (String.concat "\n" [
            "    const space = {spaceId: task.spaceId, spaceName: task.name};";
            "    await task.handOff();";
            "    emit({ok: true, value: space});" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok (`Assoc fields) when List.length fields = 2 ->
    (match List.assoc_opt "spaceId" fields,List.assoc_opt "spaceName" fields with
     | Some (`Int id),Some (`String name) when id=t.space.id && String.trim name<>"" ->
       Ok (obj ["action",str "hand_off";"spaceId",`Int id;"spaceName",str name])
     | (None|Some _),(None|Some _) ->
       Error (Live.Outcome_unknown ("ego answered the hand-off without this space's identity; " ^ unknown)))
  | Ok _ -> Error (Live.Outcome_unknown ("ego answered the hand-off without this space's identity; " ^ unknown))

(* Take back the original Space on the operator's explicit completion. The
   native boundary can identify a managed or unmanaged Page; neither is read
   or adopted here. A later active tab is never a replacement for that Page. *)
let take_over t =
  t.space_observation <- None;
  let unknown = Printf.sprintf "control of original ego Space #%d is unconfirmed; confirm operator control and inspect that same Space; never automatically repeat take_over or select a replacement" t.space.id in
  match run_native_script t (script ~step:"space.take_over" ~space:(`Int t.space.id)
      ~holder:Operator_holds ~args:(obj ["spaceId",`Int t.space.id]) Browser_ego_takeover.script) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let* receipt=Browser_ego_takeover.decode ~expected_id:t.space.id value
      |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
    let fields=["action",str "take_over";"spaceId",`Int receipt.space.id;"spaceName",str receipt.space.name] in
    (match receipt.page with
     | None -> Ok (obj fields)
     | Some page ->
         let identity=match page.label with Some label -> Managed label | None -> Unmanaged page.target_id in
         Ok (obj (fields @ ["activeTabId",`Int (remember t identity);
           "egoPage",Browser_surface.ego_page_to_json page])))

(* SDK-owned polling of this agent-owned Space only. It does not change the
   owner or settle an earlier uncertain input, including after a dialog.
   The native runner has no reply window of its own, and the Keeper stops
   waiting once this action's window ends. The SDK timeout therefore stays
   inside that window: a longer request is refused before the wait starts,
   and an omitted one becomes the window, since the SDK's own default is
   not declared. *)
let wait_for_control t (options : Browser_lane.Action.control_wait) =
  let limit_ms = window_s (Browser_lane.Page_act (Browser_lane.Action.Control
    (Browser_lane.Action.Wait_for_control options))) *. 1000. in
  match options.timeout_ms with
  | Some requested when requested > limit_ms ->
    Error (Live.Before_effect (Printf.sprintf
      "controlOptions.timeout %.0f ms exceeds this action's %.0f ms reply window" requested limit_ms))
  | Some _ | None ->
  let bounded = {options with timeout_ms = Some (Option.value options.timeout_ms ~default:limit_ms)} in
  t.space_observation <- None;
  let args=obj ["controlOptions",Browser_lane.Action.control_wait_to_json bounded] in
  match run_native_step t ~step:"space.wait_for_control" ~args (String.concat "\n" [
    "    await task.waitForControl(args.controlOptions);";
    "    emit({ok: true, value: {spaceId: task.spaceId, spaceName: task.name, controlAvailable: true}});" ]) with
  | Error failure -> Error (Live.Before_effect (step_failure_message failure))
  | Ok (`Assoc fields) when List.sort String.compare (List.map fst fields)=["controlAvailable";"spaceId";"spaceName"] ->
    (match List.assoc_opt "spaceId" fields,List.assoc_opt "spaceName" fields,List.assoc_opt "controlAvailable" fields with
     | Some (`Int id),Some (`String name),Some (`Bool true) when id=t.space.id && String.trim name<>"" ->
       Ok (obj ["action",str "wait_for_control";"spaceId",`Int id;"spaceName",str name;"controlAvailable",`Bool true])
     | (None|Some _),(None|Some _),(None|Some _) -> Error (Live.Before_effect "invalid native control wait observation"))
  | Ok _ -> Error (Live.Before_effect "invalid native control wait observation")

let space_status_script ~space_id = String.concat "\n" [
  "// masc-ego: space.status";
  "const emit = answer => console.log(" ^ Yojson.Safe.to_string (str result_marker) ^ " + JSON.stringify(answer));";
  "const args = JSON.parse(" ^ Yojson.Safe.to_string (str (Yojson.Safe.to_string (obj ["spaceId",`Int space_id]))) ^ ");";
  "try {";
  "  const matches = (await listTaskSpaces()).filter(space => space.id === args.spaceId);";
  "  if (matches.length !== 1) throw new Error('the bound Space is absent or ambiguous in the native inventory');";
  "  const observed = matches[0];";
  "  emit({ok: true, value: {spaceId: observed.id, name: observed.name, ownership: observed.ownership}});";
  "} catch (error) {";
  "  emit({ok: false, error: String(error && error.message || error)});";
  "}" ]

let space_status t =
  (* A failed refresh must not leave an earlier owner looking current. The
     numeric helper never creates a replacement, and no Page is addressed. *)
  t.space_observation <- None;
  let* value=run_native_script t (space_status_script ~space_id:t.space.id)
    |> Result.map_error (fun failure -> Live.Before_effect (step_failure_message failure)) in
  let* observation=Browser_ego_space_observation.of_sdk ~expected_id:t.space.id ~observed_at:(t.now ()) value
    |> Result.map_error (fun detail -> Live.Before_effect detail) in
  t.space_observation <- Some observation;
  match Browser_ego_space_observation.to_json observation with
  | `Assoc fields -> Ok (obj (("action",str "space_status")::fields))
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ ->
    Error (Live.Before_effect "invalid encoded Space observation")

let page_management_script = {js|async (task, args) => {
  const tabs = await task.tabs();
  let page;
  if (args.action === "adopt_tab") {
    const tab = tabs.find(row => row.targetId === args.targetId);
    if (!tab || tab.label !== null || tab.openedBy !== "unknown")
      return {ok:false,before:true,error:"the observed unmanaged tab changed; list tabs before adopting"};
    page = await task.adopt(tab.page, args.pageLabel === undefined ? {} : {as: args.pageLabel});
    if (page.targetId !== tab.targetId || page.openedBy !== tab.openedBy)
      throw new Error("native adoption changed Page identity or origin");
  } else if (args.action === "release_tab") {
    const tab = tabs.find(row => row.label === args.label);
    if (!tab || tab.openedBy !== "unknown")
      return {ok:false,before:true,error:"only an observed unknown-origin managed Page can be released; agent-created Pages must be closed"};
    page = await task.release(args.label);
    if (page.targetId !== tab.targetId || page.openedBy !== tab.openedBy)
      throw new Error("native release changed Page identity or origin");
  } else throw new Error("unknown Page management action");
  return {ok:true,value:{label:page.label ?? null,targetId:page.targetId,openedBy:page.openedBy}};
}|js}

type page_management = Adopt of string option | Release
let manage_tab t ~tab_id operation =
  let pre message=Error (Live.Before_effect message) in
  let* ()=Input.admit t.input |> Result.map_error (fun detail -> Live.Before_effect detail) in
  let* previous=match List.find_opt (fun (_,id) -> id=tab_id) t.pages with
    | Some (page,_) -> Ok page
    | None -> pre "browser tab is no longer present; list this connection's tabs" in
  let* action,args=match operation,previous with
    | Adopt label,Unmanaged target_id -> Ok ("adopt_tab",
        ["targetId",str target_id] @ Option.to_list (Option.map (fun value -> "pageLabel",str value) label))
    | Release,Managed label -> Ok ("release_tab",["label",str label])
    | Adopt _,Managed _ -> pre "this tab is already managed; adoption is explicit and never repeated"
    | Release,Unmanaged _ -> pre "this tab is already unmanaged; release is never repeated" in
  let unknown="Page management may have completed; list the same Space's tabs before continuing; never replay this action" in
  let args=obj (("action",str action)::args) in
  match run_native_step t ~step:("space." ^ action) ~args
      ("    emit(await (" ^ page_management_script ^ ")(task,args));") with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let* provenance=Browser_surface.ego_page_of_json value
      |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
    let* next=match operation,previous,provenance with
      | Adopt requested,Unmanaged target_id,{label=Some label;target_id=observed;opened_by=Unknown_origin}
        when target_id=observed && (match requested with None -> true | Some requested -> requested=label) -> Ok (Managed label)
      | Release,Managed _,{label=None;target_id;opened_by=Unknown_origin} -> Ok (Unmanaged target_id)
      | (Adopt _|Release),(Managed _|Unmanaged _),
          {label=(None|Some _);opened_by=(Agent_created|Unknown_origin);_} ->
        Error (Live.Outcome_unknown ("invalid native Page management observation; " ^ unknown)) in
    t.pages <- List.map (fun (page,id) -> (if id=tab_id then next else page),id) t.pages;
    Ok (obj ["action",str action;"tabId",`Int tab_id;"spaceId",`Int t.space.id;
      "egoPage",Browser_surface.ego_page_to_json provenance])

let act ?actor t args =
  match Browser_lane.Action.parse args with
  | Error detail -> Error (Live.Before_effect detail)
  | Ok (Browser_lane.Action.Open_tab url) -> open_tab t url
  | Ok (Browser_lane.Action.Control Browser_lane.Action.Hand_off) -> hand_off t
  | Ok (Browser_lane.Action.Control Browser_lane.Action.Take_over) -> take_over t
  | Ok (Browser_lane.Action.Control (Browser_lane.Action.Wait_for_control options)) -> wait_for_control t options
  | Ok (Browser_lane.Action.Control Browser_lane.Action.Space_status) -> space_status t
  | Ok (Browser_lane.Action.Control (Browser_lane.Action.Finish_space keep)) -> finish_space t keep
  | Ok (Browser_lane.Action.Control (Browser_lane.Action.Adopt_tab {tab_id;label})) -> manage_tab t ~tab_id (Adopt label)
  | Ok (Browser_lane.Action.Control (Browser_lane.Action.Release_tab tab_id)) -> manage_tab t ~tab_id Release
  | Ok (Browser_lane.Action.Open_window _) ->
    Error (Live.Before_effect "an ego connection does not open windows")
  | Ok (Browser_lane.Action.On_tab {frame_path = _ :: _; _}) ->
    Error (Live.Before_effect frame_upload_refused)
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Close_tab}) -> close_tab t tab_id
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Reload}) -> reload t tab_id
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Back as interaction}) ->
    traverse t tab_id ~action:"back" ~delta:(-1) ~side:"earlier" interaction
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Forward as interaction}) ->
    traverse t tab_id ~action:"forward" ~delta:1 ~side:"later" interaction
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Accept_dialog text}) ->
    answer_dialog t tab_id ~accept:true text
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Dismiss_dialog}) ->
    answer_dialog t tab_id ~accept:false None
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Upload {target = Browser_lane.Action.File_input selector; paths}}) ->
    upload t tab_id ~selector ~paths
  | Ok (Browser_lane.Action.On_tab {tab_id; frame_path = []; interaction = Browser_lane.Action.Upload {target = Browser_lane.Action.Chooser_opener opener; paths}}) ->
    choose_files ?actor t tab_id ~opener ~paths
  | Ok (Browser_lane.Action.On_tab {frame_path = []; interaction = (Browser_lane.Action.Set_cookie _ | Browser_lane.Action.Delete_cookie _
      | Browser_lane.Action.Set_emulation _ | Browser_lane.Action.Clear_emulation
      | Browser_lane.Action.Block_requests _ | Browser_lane.Action.Unblock_requests); _}) ->
    Error (Live.Before_effect "an ego connection's page.act serves open_tab, close_tab, back, forward, reload, accept_dialog, dismiss_dialog, upload, hand_off, take_over, space_status, finish_space, wait_for_control, adopt_tab and release_tab only")

let workflow ?actor t args =
  let pre result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  let* request = pre (Browser_lane.Native_workflow.of_json args) in
  let* _ = pre (Browser_page_script.text_cap (Some request.max_chars)) in
  let* label = label_of t request.tab_id in
  let* () = Input.admit t.input |> Result.map_error (fun detail -> Live.Before_effect detail) in
  let arguments = match Browser_lane.Native_workflow.to_json request with
    | `Assoc fields -> obj (("label",str label)::("cursor",str (cursor_label ~actor ~verb:"workflow"))::fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> args in
  let holds_input=List.exists (fun (step : Browser_lane.Native_workflow.step) ->
    Browser_lane.Native_workflow.holds_input step.action) request.steps in
  let* ()=if holds_input then Input.begin_holding t.input ~tab_id:request.tab_id ~page_label:label ~operation:"native_workflow"
    |> Result.map_error (fun detail -> Live.Before_effect detail) else Ok () in
  let result = run_native_step t ~step:"page.native_workflow" ~args:arguments
      (String.concat "\n" [Browser_ego_workflow.script;unblocked_managed_page;
        "    const outcome = await nativeWorkflow(task.page(args.label), args);";
        "    emit({ok: true, value: outcome});";"  }"]) in
  match result with
  | Error error ->
    (match error with
     | Refused _|Unanswered (Unstarted _) -> if holds_input then Input.not_started t.input
     | Unreadable _|Failed _|Unanswered (Exited _|Signaled _|Timed_out|Output_exceeded|Unobserved _) -> ());
    Error (effect_failure ~unknown:"native workflow result is unknown; read the same tab before another step; never replay the workflow" error)
  | Ok value ->
    let unknown detail = Live.Outcome_unknown (detail ^ "; read the same tab and do not replay the workflow") in
    let* outcome=Browser_ego_workflow.decode request value |> Result.map_error unknown in
    if holds_input then (match outcome with
      | Browser_ego_workflow.Completed {input;_}|Stopped {input=Browser_ego_release.Settled input;_} -> settle_input t input
      | Stopped {input=Browser_ego_release.Unconfirmed _;_} -> ());
    let receipt_of value=match value with
      | `Assoc fields -> Ok (obj (("tabId",`Int request.tab_id)::("action",str "workflow")::fields))
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error (unknown "workflow receipt is not an object") in
    match outcome with
    | Browser_ego_workflow.Completed {reply=value;input=_} -> receipt_of value
    | Browser_ego_workflow.Stopped {receipt=value;message=detail;effect_started;completed_effect;input=_;native_error} ->
      let message=head detail ^ "; read the same tab before continuing; never replay the workflow" in
      if completed_effect then
        let* receipt=receipt_of value in Error (Live.Partial_failure {tab_id=request.tab_id;receipt;message})
      else match native_error with
        | Some _ ->
          let* receipt=receipt_of value in
          let disposition=if effect_started then Live.Uncertain else Live.Not_started in
          Error (Live.Observed_failure {disposition;message;receipt})
        | None -> if effect_started then Error (Live.Outcome_unknown message)
          else Error (Live.Before_effect message)

let dispatch_raw ?actor t ~verb args =
  let pre result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  match (verb : Live.verb) with
  | Browser_info -> Ok (obj ["name",str "ego lite";"version",str t.version])
  | Tabs_list -> pre (tab_rows t)
  | Page_read -> pre (read t args)
  | Page_elements -> pre (elements t args)
  | Page_scene -> pre (scene t args)
  | Page_capture -> pre (capture t args)
  | Page_goto -> goto t args
  | Page_context -> Error (Live.Before_effect "framePath reads are not supported on an ego connection")
  | Page_snapshot -> pre (snapshot t args)
  | Page_downloads -> pre (downloads t args)
  | Page_act -> act ?actor t args
  | Page_interact -> interact ?actor t args
  | Page_native_workflow -> workflow ?actor t args

let admit_after_finish t ~verb args =
  match t.finish_state with
  | Active -> Ok ()
  | Finish_uncertain|Finished _ ->
    match (verb : Live.verb) with
    | Browser_info -> Ok ()
    | Page_act -> (match Browser_lane.Action.parse args with
        | Ok (Control (Space_status|Finish_space _)) -> Ok ()
        | Ok (Open_tab _|Open_window _|Control (Hand_off|Take_over|Wait_for_control _|Adopt_tab _|Release_tab _)|On_tab _)
        | Error _ -> Error (Live.Before_effect "Space completion is terminal or uncertain; former Page/control work is refused; use space_status to reconcile"))
    | Tabs_list|Page_read|Page_elements|Page_scene|Page_capture|Page_goto|Page_context|Page_snapshot
    | Page_downloads|Page_interact|Page_native_workflow ->
      Error (Live.Before_effect "Space completion is terminal or uncertain; former Page work is refused; use space_status to reconcile")

let dispatch ?command_id ?actor t ~verb args =
  let command_id=match command_id with Some id -> id
    | None -> Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let annotate = function
    | `Assoc fields -> `Assoc (("inputReadiness",str (Input.provenance t.input)) :: List.remove_assoc "inputReadiness" fields)
    | value -> value in
  match Input.within_command t.input ~command_id (fun () -> let* ()=admit_after_finish t ~verb args in dispatch_raw ?actor t ~verb args) with
  | Error detail -> Error (Live.Before_effect detail)
  | Ok (Ok value) -> Ok (annotate value)
  | Ok (Error (Live.Partial_failure partial)) -> Error (Live.Partial_failure {partial with receipt=annotate partial.receipt})
  | Ok (Error (Live.Observed_failure observed)) ->
    Error (Live.Observed_failure {observed with receipt=annotate observed.receipt})
  | Ok (Error (Live.Before_effect _|Outcome_unknown _) as failure) -> failure
