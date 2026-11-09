module Live = Browser_live_peer
module Raw_type = Browser_ego_raw_type
module Page_events = Browser_ego_page_events
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
(* page.goto and page.reload wait for the page's load within ego's own bound
   unless the call names one, and the server sets no deadline on these steps
   (Browser_lane.ego_reply_policy). They name the command's reply window. *)
let navigation_timeout_ms verb = Float.to_int (Browser_lane.reply_timeout_sec verb *. 1000.)

(* A page script answers at most this many UTF-16 units; a longer answer is
   refused in the page, which answers with its length instead. ego 0.6.0.16
   carried a 3,000,003 unit answer line whole (2026-10-22). *)
let answer_limit_units = 2 * 1024 * 1024
(* The answer line carries the page's JSON text as one JSON string, at most
   three bytes a UTF-16 unit. The rest is the frame and ego's own lines, such
   as its update notice. *)
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
  mutable space_presence : Browser_ego_space_observation.presence;
  mutable pages : (page * int) list; mutable next_tab : int; mutable captures : int }

let space_id t = t.space.id
let space t = t.space
let space_observation t = t.space_observation
let space_presence t = t.space_presence
let input_status t = Input.status t.input

let remember t page = match List.assoc_opt page t.pages with
  | Some id -> id
  | None -> t.next_tab <- t.next_tab + 1; t.pages <- (page, t.next_tab) :: t.pages; t.next_tab

(* A run that ended without an answer, an answer that is not the frame's, a
   refusal the script made before it acted ([before: true]), an error
   thrown at a point the script does not know, caught by the frame, and the
   bound Space that did not open ([spaceOpen: "failed"]): taskSpace itself
   threw, so the body never ran. *)
type step_failure = Unanswered of run_failure | Unreadable of string | Refused of string | Failed of string
  | Space_unopened of string
let step_failure_message = function
  | Unanswered failure -> run_failure_message failure
  | Unreadable detail | Refused detail | Failed detail | Space_unopened detail -> detail

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
(* taskSpace is opened apart from the body. When it throws, the answer says
   so and the body does not run: where the script failed, not ego's words,
   tells the peer that nothing was done (ego gives this error no code). *)
let script ~step ~space ~holder ~args body =
  frame ~step ~args ([
    "  let task, opened = false;";
    "  try {";
    "    task = await taskSpace(" ^ Yojson.Safe.to_string space ^ ");";
    "    opened = true;";
    "  } catch (error) {";
    "    emit({ok: false, spaceOpen: \"failed\", error: String(error && error.message || error)});";
    "  }";
    "  if (opened) {" ] @ held_by holder body @ [ "  }" ])

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
    | json -> match field "ok" json, field "value" json, field "error" json, field "before" json, field "spaceOpen" json with
      | Some (`Bool true), Some value, None, None, None -> Ok value
      | Some (`Bool false), None, Some (`String error), Some (`Bool true), None -> Error (Refused (head error))
      | Some (`Bool false), None, Some (`String error), None, None -> Error (Failed (head error))
      | Some (`Bool false), None, Some (`String error), None, Some (`String "failed") -> Error (Space_unopened (head error))
      | _ -> Error (Unreadable "ego-browser nodejs answered outside its answer frame")

type spaces_failure = Spaces_failed of string | Spaces_malformed of string
let matching_spaces ~space output =
  let* value = match answer output with
    | Ok value -> Ok value
    (* ego threw inside the frame, for one that could not reach ego lite. *)
    | Error (Failed detail) -> Error (Spaces_failed detail)
    | Error (Unanswered failure) -> Error (Spaces_failed (run_failure_message failure))
    | Error (Unreadable detail | Refused detail | Space_unopened detail) -> Error (Spaces_malformed detail) in
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
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | listed :: rest ->
        let* named = row listed in
        loop (match named with Some named -> named :: acc | None -> acc) rest
    in
    loop [] spaces
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

(* SDK contract: only claimTaskSpace reclaims a Space whose task ended while
   the operator held it; takeOverTaskSpace on that Space ends the whole
   nodejs process instead of throwing (measured 2026-11-02, ego 0.6.2.5).
   The caller asks only after the operator said to continue in the Space. *)
let claim_space ~run ~space_id =
  let script = frame ~step:"space.claim" ~args:(obj ["spaceId",`Int space_id]) [
    "  const back = await claimTaskSpace(args.spaceId);";
    "  emit({ok: true, value: {spaceId: back.spaceId, name: back.name, ownership: back.ownership}});" ] in
  match run ~window_s:read_window_s script with
  | Error failure -> Error (run_failure_message failure)
  | Ok output ->
    let open Result.Syntax in
    let* claimed = Result.map_error step_failure_message (answer output) in
    match claimed with
    | `Assoc fields when List.sort String.compare (List.map fst fields)=["name";"ownership";"spaceId"] ->
      (match List.assoc_opt "spaceId" fields, List.assoc_opt "name" fields, List.assoc_opt "ownership" fields with
       | Some (`Int id), Some (`String name), Some (`String "agent")
         when id=space_id && String.trim name<>"" -> Ok (id,name)
       | Some (`Int id), Some name, Some ownership ->
         Error (Printf.sprintf "ego returned Space %d with name %s held by %s, not by an agent"
           id (Yojson.Safe.to_string name) (Yojson.Safe.to_string ownership))
       | _ -> Error "ego answered a claimed Space without its identity")
    | _ -> Error "ego answered a claimed Space outside the answer frame"

let asked run ~window_s ~step ~space ~holder ~args body = match run ~window_s (script ~step ~space ~holder ~args body) with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output
(* Every step carries the folder an agent page's downloads are saved in, so
   the step that arms a page's download wait saves there whichever ego
   process runs it. *)
let with_download_root t = function
  | `Assoc fields -> `Assoc (("downloads", str t.downloads.root) :: fields)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as args -> args
let run_native_script t source =
  match t.run_native source with
  | Error failure -> Error (Unanswered failure)
  | Ok output -> answer output

(* ego's task spaces, read for the bound Space alone. Only a list that
   answered can establish absence; a failed read leaves presence unknown. *)
let space_status_script ~space_id = frame ~step:"space.status" ~args:(obj ["spaceId",`Int space_id]) [
  "  const spaces = await listTaskSpaces();";
  "  emit({ok: true, value: Array.isArray(spaces)";
  "    ? spaces.map(space => space !== null && typeof space === \"object\"";
  "        ? {spaceId: space.id, name: space.name, ownership: space.ownership} : space)";
  "    : spaces});" ]
let presence_of t listed = match listed with
  | Ok value -> Browser_ego_space_observation.inventory ~expected_id:t.space.id ~observed_at:(t.now ()) value
  | Error failure ->
    {Browser_ego_space_observation.space_id=t.space.id;observed_at=t.now ();
     state=Unknown (Transport_unavailable (step_failure_message failure))},None
let space_missing_refused = "the original bound Space is missing from the native inventory; no replacement was opened; this connection ends, and take_over with lane=live and no clientId asks its worker to open the configured Space again, which works only when the worker names the Space rather than its number"
let unknown_presence_message = function
  | Browser_ego_space_observation.Transport_unavailable detail | Invalid_inventory detail -> "Space presence is unknown: " ^ detail
  | Ambiguous_inventory -> "Space presence is unknown: the native inventory lists the original ID more than once"

(* A bound Space that did not open is looked up in ego's list once, within a
   read's window. A list that settles it becomes the connection's presence,
   as space_status keeps it, so a Space ego no longer lists leaves automatic
   selection. A list that does not settle it leaves the earlier presence and
   says why in the answer. The body did not run either way. *)
let settle_open t = function
  | Error (Space_unopened detail) ->
    let listed=match t.run ~window_s:read_window_s (space_status_script ~space_id:t.space.id) with
      | Error failure -> Error (Unanswered failure)
      | Ok output -> answer output in
    let presence,observation=presence_of t listed in
    let keep ()=t.space_presence <- presence; t.space_observation <- observation in
    (match presence.state with
     | Browser_ego_space_observation.Missing -> keep (); Error (Space_unopened space_missing_refused)
     | Present -> keep (); Error (Space_unopened detail)
     | Unknown reason -> Error (Space_unopened (detail ^ "; " ^ unknown_presence_message reason)))
  | (Ok _ | Error (Unanswered _ | Unreadable _ | Refused _ | Failed _)) as answered -> answered
let run_step t ~window_s ~step ~args body =
  asked t.run ~window_s ~step ~space:(`Int t.space.id) ~holder:Agent_holds ~args:(with_download_root t args) body
  |> settle_open t
let run_native_step t ~step ~args body =
  run_native_script t (script ~step ~space:(`Int t.space.id) ~holder:Agent_holds ~args:(with_download_root t args) body)
  |> settle_open t
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
    | Named_space name when not (String.equal name bound_space.name) ->
        Error "ego answered a different Space name; no replacement or fallback is permitted"
    | Existing_space _|Named_space _ -> Ok () in
  let* observation=Browser_ego_space_observation.of_sdk ~expected_id:bound_space.id ~observed_at:(now ()) opened in
  match List.assoc_opt "ownership" fields with
  | Some (`String ownership) ->
    (match space_owner_of_wire ownership with
     | Some (Agent_owner | Handed_to_operator) ->
       let input=Input.create ~space_id:bound_space.id in
       Ok {run; run_native; now; space=bound_space; version; capture_directory; downloads; published = Hashtbl.create 16;
         uploads = Browser_lane.Upload_lease.create_owner ();
         input; finish_state=Active; space_observation=Some observation;
         space_presence={space_id=bound_space.id;observed_at=observation.observed_at;state=Present}; pages=[]; next_tab=0; captures=0}
     | Some Operator_owner | None ->
       Error (Printf.sprintf "ego task space %s belongs to %s, not to an agent" (Yojson.Safe.to_string reference) ownership))
  | _ -> Error "ego answered the task space without its owner"

let retirement_settlement t = match t.finish_state, t.space_presence.state with
  | Active, Browser_ego_space_observation.Missing ->
    Error (Printf.sprintf "ego task space %d was gone from ego before its connection ended; its completion is unconfirmed, so its files are kept" t.space.id)
  | Active, (Present | Unknown _) -> Error "ego Space retained; connection retirement is not task completion"
  | Finish_uncertain, _ -> Error "ego Space completion is unconfirmed; preserve files and never replay finish"
  | Finished {settlement;_}, _ -> settlement

(* A page blocked on a JavaScript dialog runs no page script until the
   dialog is answered: ego 0.6.0.16 refuses page.evaluate then, and a move
   would leave the dialog's answer to the browser. Reads, moves and input
   are refused before any effect; closing the tab and answering the dialog
   are not. ego's page.info() names the open dialog. *)
let dialog_blocked = "is blocked on a JavaScript dialog; read mode=dialog on this tab if metadata is needed (it can be unavailable after SDK-session replacement), and answer with accept_dialog or dismiss_dialog before another step"
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

(* Native inventory is independent of renderer-backed Page.info. A modal
   retained across SDK-session replacement must not hide its Page identity.
   The window comes from the browser process as well: Browser.getWindowForTarget
   answered while the Page's renderer was busy. A tab ego does not place in a
   window, such as one closing during the read, is listed without windowId. *)
let tab_inventory_script = {js|async function(task) {
  const windowOf = async tab => {
    try {
      const found = await task.cdp("Browser.getWindowForTarget", {targetId: tab.targetId});
      return found && Number.isSafeInteger(found.windowId) && found.windowId >= 0 ? {windowId: found.windowId} : {};
    } catch (error) { return {}; }
  };
  return Promise.all((await task.tabs()).map(async tab => ({
    label: tab.label ?? null, targetId: tab.targetId, openedBy: tab.openedBy,
    title: tab.title, url: tab.url, active: tab.active, ...(await windowOf(tab))
  })));
}|js}
type listed_tab = { page : page; title : string; url : string; active : bool;
  window_id : int option; provenance : Browser_surface.ego_page }
let tab_rows t =
  let* listed = ask t ~step:"tabs.list" ~args:`Null
      ("  emit({ok: true, value: await (" ^ tab_inventory_script ^ ")(task)});") in
  let row json =
    let* ()=match json with
      | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok ()
      | _ -> Error "ego listed duplicate or invalid tab fields" in
    let* provenance=match field "label" json,field "targetId" json,field "openedBy" json with
      | Some label,Some target_id,Some opened_by -> Browser_surface.ego_page_of_json
          (obj ["label",label;"targetId",target_id;"openedBy",opened_by])
      | _ -> Error "ego listed a tab without Page provenance" in
    let page=match provenance.label with Some label -> Managed label | None -> Unmanaged provenance.target_id in
    let* window_id=match field "windowId" json with
      | None -> Ok None
      | Some (`Int id) when id >= 0 -> Ok (Some id)
      | Some _ -> Error "ego listed a tab whose window is not a nonnegative integer" in
    match field "title" json, field "url" json, field "active" json with
    | Some (`String title), Some (`String url), Some (`Bool active) ->
        Ok {page;title;url;active;window_id;provenance}
    | _ -> Error "ego listed a tab without its title, URL or active state" in
  let* rows = match listed with
    | `List rows ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | json :: rest -> let* row = row json in collect (row :: acc) rest in
      collect [] rows
    | _ -> Error "ego answered a tab list that is not a list" in
  let numbered = List.map (fun row -> remember t row.page, row) rows in
  t.pages <- List.filter (fun (page, _) -> List.exists (fun row -> row.page=page) rows) t.pages;
  Ok (`List (List.mapi (fun index (id,row) ->
    obj (["id",`Int id;"index",`Int index;"url",str row.url;"title",str row.title;"active",`Bool row.active]
      @ (match row.window_id with Some window_id -> ["windowId",`Int window_id] | None -> [])
      @ ["egoPage",Browser_surface.ego_page_to_json row.provenance]
      @ Browser_surface.dialog_observation_fields Unobserved)) numbered))

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
  match field "includeHtml" args with
  | None | Some (`Bool false) ->
    let* id,page = evaluate t args ~step:"page.read" Browser_page_script.text (`Int cap) in
    with_tab id page
  (* The document helper the other connections run: it drops HTML over 1 MiB
     and says so, instead of returning a cut document. *)
  | Some (`Bool true) ->
    let* id,page = evaluate t args ~step:"page.document"
        (Browser_page_script.parsed (Browser_lane.Document.runtime ^ "\nreturn browserDocument();")) `Null in
    if Option.is_some (field "documentLoading" page) then Error Browser_page_script.document_loading_refused
    else with_tab id page
  | Some _ -> Error "invalid includeHtml"

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
        Ok (Browser_downloads.Completed path)
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
  let verify = Browser_downloads.verify_file ~root:t.downloads.root in
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
   and viewport are read on each side of it. *)
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
  | Refused detail | Space_unopened detail | Unanswered (Unstarted detail) -> Live.Before_effect detail
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
       | Refused _|Space_unopened _|Unanswered (Unstarted _) -> t.finish_state <- Active
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
  let timeout = navigation_timeout_ms (Browser_lane.Page_act (Browser_lane.Action.Open_tab url)) in
  match run_native_step t ~step:"page.open" ~args:(obj ["url",str url;"timeoutMs",`Int timeout]) (String.concat "\n" [
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
      "    try { await page.goto(args.url, {timeout: args.timeoutMs}); } catch (error) { failure = reason(error); }";
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
   with a row is a known partial effect; without a row the outcome is
   unknown. *)
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
  let timeout = navigation_timeout_ms (Browser_lane.Page_goto {url; tab_id = Some id}) in
  settled ~id ~action:"goto" (run_native_step t ~step:"page.goto" ~args:(obj ["label",str label;"url",str url;"tabId",`Int id;"timeoutMs",`Int timeout]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    let failure = null;";
      "    try { await task.page(args.label).goto(args.url, {timeout: args.timeoutMs}); } catch (error) { failure = reason(error); }";
      moved_page_answer;
      "  }" ]))

(* Recovery must not enter unblocked_managed_page: its Page.info preflight
   cannot answer while navigation has not committed. The native Space inventory
   and managed Page properties retain identity without observing that document.
   This command does not enter, release, or reset the input-holding state. *)
let stop_loading t id =
  let* label = label_of t id in
  let unknown = "native stop_loading may have taken effect; inspect the same Space and Page before further work; never replay recovery automatically" in
  match run_native_step t ~step:"page.stop_loading" ~args:(obj ["label",str label])
      (String.concat "\n" [Browser_ego_recovery.script;
        "    emit(await stopNativeLoading(task,args));"]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value -> Browser_ego_recovery.receipt ~space_id:t.space.id ~tab_id:id ~label value
      |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown))

let tab_window id interaction =
  window_s (Browser_lane.Page_act (Browser_lane.Action.On_tab {tab_id = id; interaction}))

let reload t id =
  let* label = label_of t id in
  let timeout = navigation_timeout_ms (Browser_lane.Page_act (Browser_lane.Action.On_tab {tab_id = id; interaction = Browser_lane.Action.Reload})) in
  settled ~id ~action:"reload" (run_native_step t ~step:"page.reload" ~args:(obj ["label",str label;"tabId",`Int id;"timeoutMs",`Int timeout]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    let failure = null;";
      "    try { await task.page(args.label).reload({timeout: args.timeoutMs}); } catch (error) { failure = reason(error); }";
      moved_page_answer;
      "  }" ]))

(* Location, locale and time zone go through the Page's CDP session, as the
   viewport does (RFC-browser-ego-cdp-capabilities §3.3). The page's own Intl
   first names the time zone and locale it would take: Chromium answers an
   unknown or differently cased time zone with no error and keeps the old
   one (ego lite 0.6.2.7), so a name the page does not know is refused before
   anything changes, and the zone the page reports afterwards must be the one
   sent. The locale override changes Intl only; navigator.language and
   Accept-Language stay. A location also grants the page's origin geolocation
   with Browser.setPermission, which ego takes on a Page session and refuses
   on the task's; the grant covers every tab of that origin in the operator's
   ego profile. Overrides and grant end with the SDK process that set them
   (sdkProcessStartedAt); clearing restores the overrides and leaves the
   grant. *)
let emulation_script = {js|async function(page, args, reason) {
  const read = () => page.evaluate(`(async () => ({
    origin: location.origin,
    locale: Intl.DateTimeFormat().resolvedOptions().locale,
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    geolocationPermission: (await navigator.permissions.query({name: "geolocation"})).state
  }))()`);
  let before;
  try { before = await read(); }
  catch (error) { return {ok: false, before: true, error: "the page could not be read before emulation: " + reason(error)}; }
  const applied = [];
  const stop = (step, error, observed) => applied.length === 0 && observed === null
    ? {ok: false, before: true, error: step + ": " + error}
    : {ok: true, value: {applied, failed: {step, error}, before, observed}};
  const steps = [];
  let canonical = {};
  if (args.clear) {
    steps.push(["geolocation", "Emulation.clearGeolocationOverride", {}],
      ["locale", "Emulation.setLocaleOverride", {}],
      ["timezone", "Emulation.setTimezoneOverride", {timezoneId: ""}]);
  } else {
    try {
      canonical = await page.evaluate(`(() => {
        const zone = ${JSON.stringify(args.timezone)}, locale = ${JSON.stringify(args.locale)}, out = {};
        if (zone !== null) {
          try { out.timezone = new Intl.DateTimeFormat("en-US", {timeZone: zone}).resolvedOptions().timeZone; }
          catch (error) { out.timezoneError = String(error && error.message || error); }
        }
        if (locale !== null) {
          try { out.locale = Intl.getCanonicalLocales(locale)[0]; }
          catch (error) { out.localeError = String(error && error.message || error); }
        }
        return out;
      })()`);
    } catch (error) { return {ok: false, before: true, error: "the page could not check the locale and time zone: " + reason(error)}; }
    if (canonical.timezoneError !== undefined)
      return {ok: false, before: true, error: "the page knows no time zone " + JSON.stringify(args.timezone) + ": " + canonical.timezoneError};
    if (canonical.localeError !== undefined)
      return {ok: false, before: true, error: "the page takes no locale " + JSON.stringify(args.locale) + ": " + canonical.localeError};
    if (canonical.locale !== undefined) steps.push(["locale", "Emulation.setLocaleOverride", {locale: canonical.locale}]);
    if (canonical.timezone !== undefined) steps.push(["timezone", "Emulation.setTimezoneOverride", {timezoneId: canonical.timezone}]);
    if (args.geolocation !== null) {
      if (before.origin !== "null")
        steps.push(["geolocation_grant", "Browser.setPermission",
          {permission: {name: "geolocation"}, setting: "granted", origin: before.origin}]);
      steps.push(["geolocation", "Emulation.setGeolocationOverride", {latitude: args.geolocation.latitude,
        longitude: args.geolocation.longitude, accuracy: args.geolocation.accuracy}]);
    }
  }
  for (const [step, method, params] of steps) {
    try { await page.cdp(method, params); applied.push(step); }
    catch (error) { return stop(step, reason(error), null); }
  }
  let observed;
  try { observed = await read(); }
  catch (error) { return stop("observe", reason(error), null); }
  if (canonical.timezone !== undefined && observed.timeZone !== canonical.timezone)
    return stop("timezone", "the page reports " + observed.timeZone + " after the override to " + canonical.timezone, observed);
  return {ok: true, value: {applied, before, observed,
    geolocationGrant: applied.includes("geolocation_grant") ? before.origin : null,
    emulated: args.clear ? null : {locale: canonical.locale ?? null, timezone: canonical.timezone ?? null,
      geolocation: args.geolocation}}};
}|js}

let emulation_note = function
  | `Set -> "a page that already read its location, language or time zone keeps what it read; reload to see the new ones. \
      The locale changes Intl only, not navigator.language or Accept-Language. \
      Overrides and a geolocation grant last until the ego SDK process that set them ends (sdkProcessStartedAt changes); \
      the grant covers every tab of that origin in the ego profile and stays after clear_emulation"
  | `Clear -> "clearing restores the location, locale and time zone overrides only; \
      a geolocation grant stays until the ego SDK process that gave it ends (sdkProcessStartedAt changes)"

let emulation_receipt ~id ~action ~kind value =
  let unknown detail = Error (Live.Outcome_unknown (Printf.sprintf
    "%s; the %s may have changed tab %d: read its environment before another emulation step" detail action id)) in
  match value with
  | `Assoc fields ->
    let answered extra = `Assoc ((("action",str action) :: ("tabId",`Int id) :: fields) @ extra) in
    (match List.assoc_opt "failed" fields, List.assoc_opt "applied" fields with
     | None, Some (`List _) ->
       let cleared = match kind with
         | `Set -> []
         | `Clear -> ["cleared",`Bool true;"permissionsUnchanged",`Bool true] in
       Ok (answered (cleared @ ["lifetime",str "ego_sdk_process";"localeScope",str "intl_only";
         "note",str (emulation_note kind)]))
     | Some (`Assoc failed), Some (`List applied) ->
       let* message = match List.assoc_opt "step" failed, List.assoc_opt "error" failed with
         | Some (`String step), Some (`String error) -> Ok (step ^ ": " ^ error)
         | (None | Some _), (None | Some _) -> unknown "ego answered a failed emulation step without its step and error" in
       (match applied with
        | [] -> Error (Live.Observed_failure {disposition=Live.Uncertain; message; receipt=answered []})
        | _ :: _ -> Error (Live.Partial_failure {tab_id=id; message; receipt=answered []}))
     | (None | Some _), (None | Some _) -> unknown "ego answered an emulation receipt without its applied steps")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> unknown "the emulation receipt is not an object"

let emulate t id emulation =
  let* label = label_of t id in
  let interaction, action, kind, request = match emulation with
    | Some ({Browser_lane.Action.geolocation; locale; timezone} as emulation) ->
      let text = function Some value -> str value | None -> `Null in
      Browser_lane.Action.Set_emulation emulation, "set_emulation", `Set,
      ["clear",`Bool false;"locale",text locale;"timezone",text timezone;
       "geolocation",(match geolocation with
         | Some {Browser_lane.Action.latitude; longitude; accuracy_m} ->
           obj ["latitude",`Float latitude;"longitude",`Float longitude;"accuracy",`Float accuracy_m]
         | None -> `Null)]
    | None -> Browser_lane.Action.Clear_emulation, "clear_emulation", `Clear, ["clear",`Bool true] in
  let unknown = Printf.sprintf "the %s may have changed tab %d: read its environment before another emulation step" action id in
  match run_step t ~window_s:(tab_window id interaction) ~step:"page.emulation"
      ~args:(obj (("label",str label) :: ("tabId",`Int id) :: request)) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    emit(await (" ^ emulation_script ^ ")(task.page(args.label), args, reason));";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value -> emulation_receipt ~id ~action ~kind value

(* Request blocking goes through the Page's CDP session with
   Network.setBlockedURLs urlPatterns (RFC-browser-ego-cdp-capabilities §3.3).
   Each call replaces the Page's list (ego lite 0.6.2.7), so the SDK process
   keeps the hosts it blocked for each Page label and every block_requests
   sends their union: blocks add up, and they end with the SDK process, as
   the setting does. The pattern *://host:*/* matches that host on any port,
   the default one included, and no other host; the deprecated urls globs
   also matched a URL that carried the host in its query. Only subresource
   requests are blocked: a navigation of the tab or of a frame still loads,
   and a cross-site frame, which runs in its own process, is not covered
   (L6 evidence). A CDP call that threw may or may not have taken effect, so
   the list kept for the Page changes only when the call answered. *)
let request_block_script = {js|async function(page, args, reason) {
  const registry = globalThis.mascBlockedHosts ??= new Map();
  const before = registry.get(args.label) ?? [];
  const hosts = args.hosts === null ? [] : [...new Set([...before, ...args.hosts])].sort();
  try {
    await page.cdp("Network.setBlockedURLs",
      {urlPatterns: hosts.map(host => ({urlPattern: "*://" + host + ":*/*", block: true}))});
  } catch (error) {
    return {ok: false, error: "Network.setBlockedURLs failed: " + reason(error)};
  }
  if (hosts.length === 0) registry.delete(args.label); else registry.set(args.label, hosts);
  return {ok: true, value: args.hosts === null ? {unblocked: before.length} : {blocked: hosts}};
}|js}

let request_block_note = function
  | `Block -> "the tab's subresource requests to these hosts, and its same-origin frames', now fail as network errors. \
      Navigations and frames of another site are not blocked, and a request already sent is not affected. \
      The blocks last until unblock_requests or until the ego SDK process that set them ends (sdkProcessStartedAt changes)"
  | `Unblock -> "every block on the tab is lifted"

let request_block_receipt ~id ~action ~kind ~unknown value =
  let answered fields = Ok (obj ((("action",str action) :: ("tabId",`Int id) :: fields)
    @ ["refsInvalidated",`Bool true;"note",str (request_block_note kind)])) in
  let hosts = List.for_all (function `String _ -> true | _ -> false) in
  match kind, value with
  | `Block, `Assoc ["blocked",`List blocked] when blocked <> [] && hosts blocked ->
    answered ["blocked",`List blocked;"lifetime",str "ego_sdk_process"]
  | `Unblock, `Assoc ["unblocked",`Int count] when count >= 0 -> answered ["unblocked",`Int count]
  | (`Block | `Unblock), _ ->
    Error (Live.Outcome_unknown ("ego answered a request block receipt of another shape; " ^ unknown))

(* Cookie writes (Browser_ego_cookie_write) change the operator's ego
   profile and never answer a value. *)
let cookie_write t id interaction =
  let* label = label_of t id in
  let step, args, unknown, receipt = match interaction with
    | `Set (cookie : Browser_lane.Action.cookie) ->
      "page.set_cookie", Browser_ego_cookie_write.set_args ~label ~tab:id cookie,
      Browser_ego_cookie_write.unknown_set ~tab:id ~name:cookie.name, Browser_ego_cookie_write.set_receipt ~tab:id ~cookie
    | `Delete name ->
      "page.delete_cookie", Browser_ego_cookie_write.delete_args ~label ~tab:id ~name,
      Browser_ego_cookie_write.unknown_delete ~tab:id ~name, Browser_ego_cookie_write.delete_receipt ~tab:id ~name in
  let action = match interaction with
    | `Set cookie -> Browser_lane.Action.Set_cookie cookie | `Delete name -> Browser_lane.Action.Delete_cookie name in
  match run_step t ~window_s:(tab_window id action) ~step ~args (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    emit(await (" ^ Browser_ego_cookie_write.script ^ ")(task.page(args.label), args, reason));";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value -> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) (receipt value)

let block_requests t id hosts =
  let* label = label_of t id in
  let interaction, action, kind, wire = match hosts with
    | Some hosts -> Browser_lane.Action.Block_requests hosts, "block_requests", `Block, `List (List.map str hosts)
    | None -> Browser_lane.Action.Unblock_requests, "unblock_requests", `Unblock, `Null in
  let unknown = Printf.sprintf "the %s may have changed the blocked hosts of tab %d: unblock_requests lifts every block" action id in
  match run_step t ~window_s:(tab_window id interaction) ~step:"page.block_requests"
      ~args:(obj ["label",str label;"tabId",`Int id;"hosts",wire]) (String.concat "\n" [
      "  const reason = " ^ message ^ ";";
      unblocked_managed_page;
      "    emit(await (" ^ request_block_script ^ ")(task.page(args.label), args, reason));";
      "  }" ]) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value -> request_block_receipt ~id ~action ~kind ~unknown value

(* Cookie and storage names (RFC-browser-ego-cdp-capabilities §3.3
   read_storage). The page reads its web storage keys and IndexedDB database
   names and answers its URL; the Page's CDP session then lists the cookies
   for that URL. Network.getCookies without a URL also lists the cookies of
   every frame's URL, a cross-site frame's own cookies included, which that
   frame cannot see (L7 evidence), so the step names the top document's URL.
   A cookie value is a credential: the script drops it inside the SDK
   process, and the answer keeps the name and the attributes that scope the
   cookie. Web storage values are never read. A page that does not answer
   its IndexedDB names within [storage_indexed_db_wait_ms] answers a timeout
   for them. *)
let storage_indexed_db_wait_ms = 2000
let storage_limits = obj ["cookies",`Int Browser_lane.storage_cookies_limit;"names",`Int Browser_lane.storage_names_limit;
  "nameChars",`Int Browser_lane.storage_name_chars;"indexedDbWaitMs",`Int storage_indexed_db_wait_ms]

let storage_names_script = {js|async function(page, args, reason) {
  let seen;
  try {
    seen = await page.evaluate(async limits => {
      const cut = text => String(text).slice(0, limits.nameChars);
      const failure = error => ({error: cut(error && error.name || error)});
      const area = name => {
        try {
          const store = window[name];
          const count = store.length;
          const keys = [];
          for (let index = 0; index < Math.min(count, limits.names); index++) keys.push(cut(store.key(index)));
          return {count, keys, truncated: count > limits.names};
        } catch (error) { return failure(error); }
      };
      const databases = async () => {
        try {
          if (typeof indexedDB === "undefined" || typeof indexedDB.databases !== "function") return {unsupported: true};
          let timer;
          const listed = await Promise.race([indexedDB.databases(),
            new Promise(resolve => { timer = setTimeout(() => resolve(null), limits.indexedDbWaitMs); })]);
          clearTimeout(timer);
          if (listed === null) return {error: "timeout"};
          return {count: listed.length, names: listed.slice(0, limits.names).map(database => cut(database.name)),
            truncated: listed.length > limits.names};
        } catch (error) { return failure(error); }
      };
      return {url: location.href, origin: location.origin, localStorage: area("localStorage"),
        sessionStorage: area("sessionStorage"), indexedDb: await databases()};
    }, args.limits);
  } catch (error) {
    return {ok: false, error: "the page's storage names were not read: " + reason(error)};
  }
  if (seen === null || typeof seen !== "object" || typeof seen.url !== "string")
    return {ok: false, error: "the page answered its storage names without its URL"};
  let listed;
  try {
    listed = await page.cdp("Network.getCookies", {urls: [seen.url]});
  } catch (error) {
    return {ok: false, error: "Network.getCookies failed: " + reason(error)};
  }
  if (listed === null || typeof listed !== "object" || !Array.isArray(listed.cookies))
    return {ok: false, error: "Network.getCookies answered without a cookie list"};
  const cookies = listed.cookies.map(cookie => ({
    name: cookie.name, domain: cookie.domain, path: cookie.path, secure: cookie.secure, httpOnly: cookie.httpOnly,
    ...(cookie.sameSite === undefined ? {} : {sameSite: cookie.sameSite}),
    ...(cookie.session === false ? {expiry: Math.floor(cookie.expires)} : {})}));
  return {ok: true, value: {cookies: cookies.slice(0, args.limits.cookies), total: cookies.length,
    storage: {origin: seen.origin, localStorage: seen.localStorage, sessionStorage: seen.sessionStorage,
      indexedDb: seen.indexedDb}}};
}|js}

type listed_cookie = { cookie_name : string; cookie_domain : string; cookie_path : string; cookie_secure : bool;
  cookie_http_only : bool; cookie_same_site : Browser_lane.Action.same_site option; cookie_expiry : int option }
type listed_names = { names_held : int; names_listed : string list; names_truncated : bool }
type storage_area = Area_names of listed_names | Area_unreadable of string
type database_listing = Database_names of listed_names | Databases_unsupported | Databases_unreadable of string

let storage_shape what = "ego answered " ^ what ^ " in another shape"
let unique_keys fields = let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
let has_keys expected fields =
  unique_keys fields && List.sort String.compare (List.map fst fields) = List.sort String.compare expected
let strings items = List.fold_right (fun item collected ->
    let* collected = collected in
    match item with `String text -> Ok (text :: collected) | _ -> Error ()) items (Ok [])

let listed_cookie = function
  | `Assoc fields when unique_keys fields
      && List.for_all (fun (key, _) -> List.mem key ["name";"domain";"path";"secure";"httpOnly";"sameSite";"expiry"]) fields ->
    let refused () = Error (storage_shape "a cookie") in
    (match List.assoc_opt "name" fields, List.assoc_opt "domain" fields, List.assoc_opt "path" fields,
           List.assoc_opt "secure" fields, List.assoc_opt "httpOnly" fields with
     | Some (`String cookie_name), Some (`String cookie_domain), Some (`String cookie_path), Some (`Bool cookie_secure),
       Some (`Bool cookie_http_only) ->
       let* cookie_same_site = match List.assoc_opt "sameSite" fields with
         | None -> Ok None
         | Some (`String wire) -> (match Browser_lane.Action.same_site_of_wire wire with Some value -> Ok (Some value) | None -> refused ())
         | Some _ -> refused () in
       let* cookie_expiry = match List.assoc_opt "expiry" fields with
         | None -> Ok None
         | Some (`Int seconds) -> Ok (Some seconds)
         | Some _ -> refused () in
       Ok {cookie_name; cookie_domain; cookie_path; cookie_secure; cookie_http_only; cookie_same_site; cookie_expiry}
     | _ -> refused ())
  | _ -> Error (storage_shape "a cookie")

(* [names_held] is how many the page held, [names_listed] the first of them. *)
let listed_names ~what ~key = function
  | `Assoc fields when has_keys ["count";key;"truncated"] fields ->
    (match List.assoc "count" fields, List.assoc key fields, List.assoc "truncated" fields with
     | `Int count, `List items, `Bool truncated
       when count >= 0 && List.length items = min count Browser_lane.storage_names_limit
            && Bool.equal truncated (count > Browser_lane.storage_names_limit) ->
       Result.map_error (fun () -> storage_shape what) (strings items)
       |> Result.map (fun names_listed -> {names_held = count; names_listed; names_truncated = truncated})
     | _ -> Error (storage_shape what))
  | _ -> Error (storage_shape what)

let storage_area ~what = function
  | `Assoc ["error",`String reason] -> Ok (Area_unreadable reason)
  | json -> Result.map (fun names -> Area_names names) (listed_names ~what ~key:"keys" json)

let database_listing = function
  | `Assoc ["unsupported",`Bool true] -> Ok Databases_unsupported
  | `Assoc ["error",`String reason] -> Ok (Databases_unreadable reason)
  | json -> Result.map (fun names -> Database_names names) (listed_names ~what:"IndexedDB names" ~key:"names" json)

let listed_names_json ~key {names_held; names_listed; names_truncated} =
  obj ["count",`Int names_held; key,`List (List.map str names_listed);"truncated",`Bool names_truncated]
let storage_area_json = function
  | Area_names names -> listed_names_json ~key:"keys" names
  | Area_unreadable reason -> obj ["error",str reason]
let database_listing_json = function
  | Database_names names -> listed_names_json ~key:"names" names
  | Databases_unsupported -> obj ["unsupported",`Bool true]
  | Databases_unreadable reason -> obj ["error",str reason]
let listed_cookie_json {cookie_name; cookie_domain; cookie_path; cookie_secure; cookie_http_only; cookie_same_site; cookie_expiry} =
  obj (["name",str cookie_name;"domain",str cookie_domain;"path",str cookie_path;"secure",`Bool cookie_secure;
        "httpOnly",`Bool cookie_http_only]
    @ Option.to_list (Option.map (fun value -> "sameSite",str (Browser_lane.Action.same_site_to_wire value)) cookie_same_site)
    @ Option.to_list (Option.map (fun seconds -> "expiry",`Int seconds) cookie_expiry))

(* The answer is rebuilt from what was parsed, so a field the script did not
   name, a cookie value included, never reaches the caller. *)
let storage_receipt ~tab = function
  | `Assoc fields when has_keys ["cookies";"total";"storage"] fields ->
    (match List.assoc "cookies" fields, List.assoc "total" fields, List.assoc "storage" fields with
     | `List rows, `Int total, `Assoc storage
       when List.length rows = min total Browser_lane.storage_cookies_limit
            && has_keys ["origin";"localStorage";"sessionStorage";"indexedDb"] storage ->
       let* cookies = List.fold_right (fun row collected ->
           let* collected = collected in
           let* cookie = listed_cookie row in
           Ok (cookie :: collected)) rows (Ok []) in
       let* origin = match List.assoc "origin" storage with
         | `String origin -> Ok origin
         | _ -> Error (storage_shape "the page origin") in
       let* local = storage_area ~what:"localStorage names" (List.assoc "localStorage" storage) in
       let* session = storage_area ~what:"sessionStorage names" (List.assoc "sessionStorage" storage) in
       let* databases = database_listing (List.assoc "indexedDb" storage) in
       Ok (obj ["tabId",`Int tab;"cookies",`List (List.map listed_cookie_json cookies);"total",`Int total;
                "valuesWithheld",`Bool true;
                "storage",obj ["origin",str origin;"localStorage",storage_area_json local;
                               "sessionStorage",storage_area_json session;"indexedDb",database_listing_json databases];
                "storageValuesWithheld",`Bool true])
     | _ -> Error (storage_shape "cookie and storage names"))
  | _ -> Error (storage_shape "cookie and storage names")

let storage_names t args =
  let* tab = match field "tabId" args with
    | Some (`Int tab) -> Ok tab
    | Some _ | None -> Error "cookie and storage names are read for one tab; give its tabId" in
  let* label = target t args in
  let* value = ask t ~step:"page.cookies" ~args:(obj ["label",label;"limits",storage_limits])
      (on_page (String.concat "\n" [
         "    const reason = " ^ message ^ ";";
         "    emit(await (" ^ storage_names_script ^ ")(page, args, reason));" ])) in
  storage_receipt ~tab value

(* The tab's network log (RFC-browser-ego-cdp-capabilities §3.4). ego's Page
   session already has the Network domain on, so the step only drains the
   Page's event buffer through the shared Page_events script and answers the
   log it keeps for the Page in this SDK process. The drain keeps every other
   event for the next workflow events step or native typing, so the read
   takes nothing from them. *)
let network_log t args =
  let* tab = match field "tabId" args with
    | Some (`Int tab) -> Ok tab
    | Some _ | None -> Error "a network log is read for one tab; give its tabId" in
  let* label = target t args in
  let* value = ask t ~step:"page.network" ~args:(obj ["label",label])
      (on_page (String.concat "\n" [
         Page_events.script;
         "    const reason = " ^ message ^ ";";
         "    let log;";
         "    try { log = await mascNetworkLog(page); }";
         "    catch (error) { log = {failed: \"the tab's network log was not read: \" + reason(error)}; }";
         "    emit(log.failed === undefined ? {ok: true, value: log} : {ok: false, error: log.failed});" ])) in
  Page_events.receipt ~tab value

(* The tab's console (RFC-browser-ego-cdp-capabilities §3.3 read_console).
   The step turns ego's console hiding off, replays what the browser kept of
   the document's console and turns the hiding back on (Browser_ego_console).
   A failure after the hiding came back on changed nothing; one that may have
   left it off is an unknown outcome until the next console read or a new
   SDK process. *)
let console_read t args =
  let refuse message = Error (Live.Before_effect message) in
  let* tab = match field "tabId" args with
    | Some (`Int tab) -> Ok tab
    | Some _ | None -> refuse "a console is read for one tab; give its tabId" in
  let* label = Result.map_error (fun message -> Live.Before_effect message) (target t args) in
  let unknown = Printf.sprintf "ego's console hiding for tab %d may still be off; it comes back with the next console read \
    or when the ego SDK process ends (sdkProcessStartedAt changes)" tab in
  match run_step t ~window_s:read_window_s ~step:"page.console" ~args:(obj ["label",label])
      (on_page (String.concat "\n" [
         Page_events.script;
         Browser_ego_console.script ~answer_units:answer_limit_units;
         "    const reason = " ^ message ^ ";";
         "    emit(await mascConsoleRead(page, reason));" ])) with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) (Browser_ego_console.receipt ~tab value)

(* ego's Page API has no back or forward, so the step goes through the
   page's CDP session: it reads the tab's history, refuses before acting when
   there is no entry that way, moves to the entry, and waits until the tab's
   current entry is that one and its document has loaded. The entry's index
   says the move happened even when the page at it has the same URL. A read
   while waiting can fail as the page changes renderer (ego lite 0.6.0.16
   answered "Not attached to an active page" once on a move back to
   chrome://new-tab-page/, and the next read was on the entry); such a
   failure says nothing about the move, so the wait goes on. Both waits, for
   the entry and for its load, end a delivery margin before the run is
   stopped ([runStopsAt]), so a move that does not land or a load that
   outlasts the window still answers where the tab is instead of losing the
   run. The load wait names at least a millisecond, because ego documents its
   timeout only as a maximum duration and does not say what 0 means. *)
let history_poll_ms = 50
let traverse t id ~action ~delta ~side interaction =
  let* label = label_of t id in
  settled ~id ~action (run_step t ~window_s:(tab_window id interaction)
    ~step:"page.history" ~args:(obj ["label",str label;"tabId",`Int id;"delta",`Int delta;"side",str side;"pollMs",`Int history_poll_ms;
      "answerMarginMs",`Int (Float.to_int (delivery_margin_s *. 1000.))])
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
      "        const answerBy = runStopsAt - args.answerMarginMs;";
      "        while (!(await landed())) {";
      "          if (Date.now() >= answerBy) throw new Error(\"tab \" + args.tabId + \" did not reach the \" + args.side + \" history entry within its run's window\");";
      "          await page.waitForTimeout(args.pollMs);";
      "        }";
      "        await page.waitForLoadState(undefined, {timeout: Math.max(1, answerBy - Date.now())});";
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

(* Both explicit dialog reads and answers bind the same canonical Page from
   fresh native inventory. Neither resolves it through renderer-backed info. *)
let dialog_page_script = {js|async function(task, args) {
  const rows = await task.tabs();
  if (!Array.isArray(rows)) return {error: "native tab inventory is not an array"};
  const matches = rows.filter(row => row && row.label === args.label);
  if (matches.length !== 1) return {error: "managed Page is absent or ambiguous in native inventory"};
  const row = matches[0], page = row.page;
  if (task.spaceId !== args.spaceId || typeof row.targetId !== "string" || row.targetId.trim() === ""
      || (row.openedBy !== "agent" && row.openedBy !== "unknown")
      || !page || page.spaceId !== args.spaceId || page.label !== args.label
      || page.targetId !== row.targetId || page.openedBy !== row.openedBy)
    return {error: "native dialog Page identity or origin changed"};
  return {page};
}|js}
let dialog_read_script = {js|async function(task, args, resolve) {
  const resolved = await resolve(task, args);
  if (resolved.error) return {ok: false, before: true, error: resolved.error};
  const info = await resolved.page.info();
  if (info === null || typeof info !== "object" || Array.isArray(info))
    return {ok: false, before: true, error: "native Page.info returned invalid state"};
  if (Object.hasOwn(info, "dialog")) {
    if (info.dialog === null || typeof info.dialog !== "object" || Array.isArray(info.dialog))
      return {ok: false, before: true, error: "native Page.info returned invalid dialog state"};
    return {ok: true, value: {dialog: info.dialog}};
  }
  if (typeof info.url !== "string" || typeof info.title !== "string"
      || !["w", "h", "sx", "sy", "pw", "ph"].every(key => typeof info[key] === "number" && Number.isFinite(info[key])))
    return {ok: false, before: true, error: "native Page.info omitted its dialog and document observation"};
  return {ok: true, value: {dialog: null}};
}|js}
let dialog_answer_script = {js|async function(task, args, resolve, watchDownloads) {
  const resolved = await resolve(task, args);
  if (resolved.error) return {ok: false, before: true, error: resolved.error};
  const page = resolved.page;
  watchDownloads(page, args.label);
  const answered = !args.accept ? await page.dismissDialog()
    : args.text === null ? await page.acceptDialog() : await page.acceptDialog(args.text);
  if (answered === false) return {ok: false, before: true, error: "no dialog is open in this tab"};
  if (answered === true) return {ok: true, value: {answered: true}};
  return {ok: false, error: "native dialog answer did not return a boolean"};
}|js}
let dialog_args t id label = ["spaceId",`Int t.space.id;"label",str label;"tabId",`Int id]
let dialog_read t args =
  let* id=match field "tabId" args with Some (`Int id) -> Ok id | _ -> Error "an observed tabId is required" in
  let* ()=match field "mode" args with
    | Some (`String "dialog") -> Ok ()
    | None|Some _ -> Error "an ego contextual read serves mode dialog only" in
  let* label=label_of t id |> Result.map_error (function
    | Live.Before_effect detail|Outcome_unknown detail -> detail
    | Partial_failure {message;_}|Observed_failure {message;_} -> message) in
  let* value=ask t ~step:"page.context" ~args:(obj (dialog_args t id label))
      ("  emit(await (" ^ dialog_read_script ^ ")(task, args, " ^ dialog_page_script ^ ")); ") in
  let* observation=match field "dialog" value with
    | Some `Null -> Ok (Browser_surface.Observed None)
    | Some dialog -> ego_dialog dialog |> Result.map (fun dialog -> Browser_surface.Observed (Some dialog))
    | None -> Error "native dialog read omitted its observation" in
  Ok (obj (("tabId",`Int id)::Browser_surface.dialog_observation_fields observation))
let answer_dialog t id ~accept text =
  let* label = label_of t id in
  let action, interaction = if accept then "accept_dialog", Browser_lane.Action.Accept_dialog text
    else "dismiss_dialog", Browser_lane.Action.Dismiss_dialog in
  match run_step t ~window_s:(tab_window id interaction) ~step:"page.dialog"
          ~args:(obj (dialog_args t id label @ ["accept",`Bool accept;
            "text",(match text with Some text -> str text | None -> `Null)])) (String.concat "\n" [
      download_watch;
      "  emit(await (" ^ dialog_answer_script ^ ")(task, args, " ^ dialog_page_script ^ ", watchDownloads));" ]) with
  | Error failure ->
    Error (effect_failure ~unknown:(Printf.sprintf "the dialog of tab %d may have been answered: list this connection's tabs" id) failure)
  | Ok value ->
    if field "answered" value <> Some (`Bool true) then
      Error (Live.Outcome_unknown (Printf.sprintf
        "the dialog of tab %d may have been answered: native boolean receipt is missing or invalid; list this connection's tabs" id))
    else Ok (obj (["tabId",`Int id;"action",str action;"answered",`Bool true]
      @ Browser_surface.dialog_observation_fields Unobserved))

(* ego shows a mouse step's [label] beside its own cursor highlight. It says
   who acts and what: MASC, the actor, the interaction. *)
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
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | path :: rest ->
        match chosen_file path with
        | Some row -> loop (row :: acc) rest
        | None -> Error (Live.Before_effect ("the upload file " ^ Filename.basename path ^ " is not there"))
    in
    loop [] paths
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
   The shared page scripts find the target, check that the document, URL and
   viewport are the observed ones, and make the DOM edits; ego moves the mouse
   and presses the keys. *)

(* ego reads and acts inside frames through its snapshot: the viewport
   snapshot holds each iframe's content with refs, a subtree snapshot rooted
   at the iframe's ref reads one frame, a ref from it acts inside that frame,
   and a role or text target is looked for in frames when the top document
   has none (cross-origin frames included, 0.6.0.16). *)

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

(* Touch through the Page's CDP session, with no touch emulation. On ego lite
   0.6.2.7 the page got trusted touch and pointer events without it, and
   turning it on changed the page's maxTouchPoints and pointer media until it
   was turned off (RFC-browser-ego-cdp-capabilities §3.3). A touch left down
   turns the next touchStart into a move of it, so a gesture that fails after
   its press sends touchCancel; a new SDK process starts with no touch down. *)
let touch_lines = [
  "        const touch = (type, points) => page.cdp(\"Input.dispatchTouchEvent\", {type, touchPoints: points.map(([x, y]) => ({x, y}))});";
  "        try {";
  "          await touch(\"touchStart\", [args.start]);";
  "          for (const [x, y, waitMs] of args.moves) {";
  "            if (waitMs > 0) await new Promise(resolve => setTimeout(resolve, waitMs));";
  "            await touch(\"touchMove\", [[x, y]]);";
  "          }";
  "          await touch(\"touchEnd\", []);";
  "        } catch (error) {";
  "          let cancelled = true;";
  "          try { await touch(\"touchCancel\", []); } catch (cancelError) { cancelled = false; }";
  "          throw new Error((cancelled ? \"the touch was cancelled after \" : \"touchCancel failed, so a touch may stay down on this Page until its SDK process ends, after \") + String(error && error.message || error));";
  "        }" ]

(* CDP sends only the touch points it is given, while a WebDriver pointerMove
   fills its segment in over its duration. A swipe takes the BiDi peer's
   segments (Pointer.drag_waypoints, then the destination), each
   [duration_ms] long, and fills each with a point every
   [touch_move_interval_ms]; a 0 ms segment is one point. Each point carries
   the wait before it, and a segment's waits add up to [duration_ms]. *)
let touch_move_interval_ms = 16
let touch_segments ~start ~via ~destination = Browser_lane.Pointer.drag_waypoints ~start ~destination via @ [destination]
let touch_moves ~start ~via ~destination ~duration_ms =
  let segment (from : Browser_lane.Pointer.point) (target : Browser_lane.Pointer.point) =
    let steps = max 1 ((duration_ms + touch_move_interval_ms - 1) / touch_move_interval_ms) in
    List.init steps (fun index ->
      let fraction = float_of_int (index + 1) /. float_of_int steps in
      let wait_ms = duration_ms * (index + 1) / steps - duration_ms * index / steps in
      ({Browser_lane.Pointer.x = from.x +. (target.x -. from.x) *. fraction;
        y = from.y +. (target.y -. from.y) *. fraction}, wait_ms)) in
  let _, moves = List.fold_left (fun (from, moves) target -> (target, moves @ segment from target))
      (start, []) (touch_segments ~start ~via ~destination) in
  moves

(* ego takes a chord as Playwright writes one: the modifiers, then the key,
   joined by "+". It presses the named keys and printable ASCII, up to "~";
   ego 0.6.0.16 refused é, ß and € as an unknown key (2026-10-23). *)
let last_pressable_character = 0x7e
let press_refused = "an ego connection presses named keys and printable ASCII characters; explicitly choose native workflow fill, keyboard.insertText or keyboard.paste for other text"
let keys_fields (chord : Browser_lane.Keyboard.t) =
  ["keys",str (String.concat "+"
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
   refuses before any effect if not, the input or effect is sent, and the
   receipt script reads where the page is. *)
(* How long a cleared viewport is waited for. On ego lite 0.6.2.7 a read right
   after Emulation.clearDeviceMetricsOverride saw the old size 13 times in 100;
   the size moved after at most 1,074 ms (p90 63 ms), polled every 10 ms
   (docs/evidence/ego-cdp-capabilities-2026-11-06/l2-viewport). *)
let viewport_restore_wait_ms = 2000

let guarded_input t ~id ~label ~deadline ~verb ~step ~guard ~receipt ~input ~lines ~fields =
  let unknown = Printf.sprintf "read tab %d before another step" id in
  let response = run_step t ~window_s:(left t deadline) ~step
          ~args:(obj (["label",str label;"tabId",`Int id;"guard",str (page_function guard);
            "input",str (Yojson.Safe.to_string input);
            "receipt",str (page_function receipt)] @ fields))
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
  match response with
  | Error failure -> Error (effect_failure ~unknown failure)
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
       | _ -> Error (Live.Outcome_unknown (verb ^ " was sent and its guard or receipt lacks the page URL; " ^ unknown)))
    | (Ok _ | Error _), Some (`String error), (Ok _ | Error _) -> Error (Live.Outcome_unknown (head error ^ "; " ^ unknown))
    | Error detail, Some `Null, _ | Ok _, Some `Null, Error detail ->
      Error (Live.Outcome_unknown (verb ^ " was sent and " ^ detail ^ "; " ^ unknown))
    | (Ok _ | Error _), (None | Some _), (Ok _ | Error _) ->
      Error (Live.Outcome_unknown ("ego answered " ^ verb ^ " outside its answer frame; " ^ unknown))

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
  let receipt = null, failure = null, thrown = null;
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
    // duplicate the SDK's original mouseup. Never release here. Hand the
    // error's declared name and kind to the host, which alone judges them.
    thrown = {
      name: typeof error?.name === "string" ? error.name : null,
      kind: typeof error?.kind === "string" ? error.kind : null
    };
  }
  return {urlBefore, receipt, error: failure, thrown};
}|js}
(* An input the SDK showed released is settled. One that was never held keeps the readiness it had. *)
let settle_input t pending settled = match pending with
  | None -> Ok ()
  | Some (pending:Input.pending) -> match settled with
    | Browser_ego_release.No_hold -> Input.not_started t.input ~generation:pending.generation
    | Browser_ego_release.Released proof -> Input.command_settled t.input ~generation:pending.generation proof
let refusable_gesture = function
  | Target_click -> Some Browser_ego_release.Click
  | Target_double_click -> Some Browser_ego_release.Double_click
  | Target_drag _ -> Some Browser_ego_release.Drag_and_drop
  | Target_fill _ | Target_hover | Target_select _ -> None
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
  let holds_button = match operation with
    | Target_click | Target_double_click | Target_drag _ -> true
    | Target_fill _ | Target_hover | Target_select _ -> false in
  let* pending=if holds_button then Input.begin_holding t.input ~scope:Input.Page_scope ~page_label:label
    |> Result.map Option.some |> Result.map_error (fun detail -> Live.Before_effect detail) else Ok None in
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
  let* ()=match pending,response with
    | Some pending,Error (Refused _ | Space_unopened _ | Unanswered (Unstarted _)) ->
        Input.not_started t.input ~generation:pending.generation |> Result.map_error (fun detail -> Live.Before_effect detail)
    | None,_ | Some _,(Ok _ | Error (Unanswered (Exited _ | Signaled _ | Timed_out | Output_exceeded | Unobserved _) | Failed _ | Unreadable _)) -> Ok () in
  match response with
  | Error failure -> Error (effect_failure ~unknown failure)
  | Ok value ->
    let outcome detail = Error (Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
    match field "error" value, field "urlBefore" value, field "receipt" value, field "tab" value with
    | Some (`String error), _, _, _ ->
      (* A gesture the SDK refused before its press holds nothing: the input
         keeps the readiness it had. Only a frame with no receipt can be such
         a refusal. The effect stays uncertain, because the SDK may have
         scrolled the target or, for a double click, finished a first click
         and its release before it gave up. *)
      (match pending, refusable_gesture operation, field "receipt" value with
       | Some _, Some gesture, Some `Null ->
         (match Browser_ego_release.answer_of_refusal gesture
                  (Option.value (field "thrown" value) ~default:`Null) with
          | Browser_ego_release.Refused_before_press resolution as answer ->
            (match Browser_ego_release.judge [0,answer] with
             | Browser_ego_release.Settled settled ->
               let* () = settle_input t pending settled
                 |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown)) in
               Error (Live.Observed_failure {disposition=Live.Uncertain;message=head error ^ "; " ^ unknown;
                 receipt=obj (["tabId",`Int id;"action",str verb] @ reference
                   @ ["refusedBeforePress",obj ["kind",str (Browser_ego_release.resolution_to_wire resolution)]])})
             | Browser_ego_release.Unconfirmed _ -> outcome (head error))
          | Browser_ego_release.Receipt_without_dialog | Browser_ego_release.Native_window_tail _
          | Browser_ego_release.Unreleased _ -> outcome (head error))
       | (None | Some _), (None | Some _), (None | Some _) -> outcome (head error))
    | Some `Null, Some (`String url_before), Some (`Assoc receipt), Some ((`Null | `Assoc _) as tab) ->
      (* Click, double-click and dragAndDrop settle only from the SDK's receipt read whole. A receipt
         with a member the SDK does not declare is not an answer, so it is read as neither released nor served. *)
      let answer = Browser_ego_release.answer_of_json (`Assoc receipt) in
      let declared = match operation with
        | Target_click | Target_double_click | Target_drag _ ->
          (match answer with
           | Browser_ego_release.Native_window_tail _ | Browser_ego_release.Refused_before_press _
           | Browser_ego_release.Unreleased (Browser_ego_release.Undeclared_answer
               | Native_window_unconfirmed _ | Conflicting_evidence) ->
             Error "ego answered the input with a receipt the SDK does not declare"
           | Browser_ego_release.Receipt_without_dialog
           | Browser_ego_release.Unreleased (Browser_ego_release.Receipt_with_dialog | Void_answer | Never_returned) -> Ok ())
        | Target_fill _ | Target_hover | Target_select _ -> Ok () in
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
         let* ()=if holds_button then (match Browser_ego_release.judge [0,answer] with
           | Browser_ego_release.Settled settled -> settle_input t pending settled
               |> Result.map_error (fun detail -> Live.Outcome_unknown (detail ^ "; " ^ unknown ^ "; never replay the input"))
           | Browser_ego_release.Unconfirmed _ -> Ok ()) else Ok () in
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

let managed_source t ~tab_id ~label =
  let* rows=tab_rows t in
  let* tab=Browser_surface.inventory_tab ~tab_id rows in
  match tab.ego_page with
  | Some {label=Some observed;target_id;opened_by} when observed=label ->
    Ok {Browser_ego_workflow.space_id=t.space.id;label;target_id;opened_by}
  | None|Some _ -> Error "source is not the exact managed Page in the native inventory"

let window_page (identity:Browser_ego_workflow.page_identity) =
  {Browser_ego_native_window.space_id=identity.space_id;
    native={Browser_surface.label=Some identity.label;target_id=identity.target_id;opened_by=identity.opened_by}}

let source_page_json (identity:Browser_ego_workflow.page_identity) =
  obj (("spaceId",`Int identity.space_id)::Browser_surface.ego_page_fields
    {label=Some identity.label;target_id=identity.target_id;opened_by=identity.opened_by})

let native_type_guard_script = {js|async function nativeTypeGuard(page, args) {
  const checked = await page.evaluate(pageCall(args.guard, args.input));
  const refuse = () => { throw new Error('native input guard refused'); };
  if (!checked || typeof checked !== 'object' || Array.isArray(checked)
      || Object.keys(checked).length !== 1 || !Object.hasOwn(checked,'answer')
      || typeof checked.answer !== 'string') refuse();
  let observed;
  try { observed = JSON.parse(checked.answer); } catch (_) { refuse(); }
  const expected = JSON.parse(args.input);
  const members = ['url','title','scrollX','scrollY'];
  if (!observed || typeof observed !== 'object' || Array.isArray(observed)
      || Object.keys(observed).length !== members.length
      || !Object.keys(observed).every(key => members.includes(key))
      || observed.url !== expected.expectedUrl || typeof observed.title !== 'string'
      || !Number.isFinite(observed.scrollX) || !Number.isFinite(observed.scrollY)) refuse();
}|js}

let native_type t ~id ~label ~expected_url ~document_id ~text =
  let before result=Result.map_error (fun message->Live.Before_effect message) result in
  let* source=before (managed_source t ~tab_id:id ~label) in
  let current=window_page source in
  let* pending=before (Input.begin_holding t.input ~scope:Input.Page_scope ~page_label:label) in
  let* context=match Raw_type.prepare ~command_id:pending.command_id ~generation:pending.generation ~source:current ~indices:[0] with
    | Ok context->Ok context
    | Error _ -> let* ()=before (Input.not_started t.input ~generation:pending.generation) in
      Error (Live.Before_effect "native typing context could not be prepared") in
  let input=Browser_lane.interaction_args ~tab_id:id ~expected_url
    (Browser_lane.Type_text {document_id;text}) in
  let arguments=obj ["label",str label;"text",str text;"nativeInputWindows",Raw_type.arguments context;
    "expectedSourcePage",source_page_json source;
    "guard",str (page_function Browser_interaction.keyboard_guard_script);
    "input",str (Yojson.Safe.to_string input)] in
  let response=run_native_step t ~step:"page.native_type" ~args:arguments (String.concat "\n" [
    Browser_ego_workflow.native_error_script;Page_events.script;Raw_type.script;page_call;native_type_guard_script;unblocked_managed_page;
    "    const guard = page => nativeTypeGuard(page, args);";
    "    const outcome = await nativeTypeWindow(task, task.page(args.label), args.nativeInputWindows, 0, args.text, undefined, args.expectedSourcePage, args.expectedSourcePage, guard);";
    "    const nativeError = nativeErrorObservation(outcome.error);";
    "    emit({ok:true,value:{capture:outcome.capture,...(nativeError === undefined ? {} : {nativeError})}});";"  }"]) in
  let unknown=Live.Outcome_unknown "native typing result is unconfirmed; inspect the same Page and never replay the input" in
  match response with
  | Error (Refused _|Unanswered (Unstarted _)) ->
    let* ()=before (Input.not_started t.input ~generation:pending.generation) in
    Error (Live.Before_effect "native typing was refused before its producer ran")
  | Error (Space_unopened detail) ->
    let* ()=before (Input.not_started t.input ~generation:pending.generation) in
    Error (Live.Before_effect detail)
  | Error (Unreadable _|Failed _|Unanswered (Exited _|Signaled _|Timed_out|Output_exceeded|Unobserved _)) -> Error unknown
  | Ok value ->
    let* fields=match value with
      | `Assoc fields when List.for_all (fun (key,_)->List.mem key ["capture";"nativeError"]) fields
          && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
      | `Assoc _|`Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> Error unknown in
    let* capture=match List.assoc_opt "capture" fields with Some capture->Ok capture|None->Error unknown in
    let* outcome=Raw_type.decode context ~index:0 ~current capture |> Result.map_error (fun _->unknown) in
    let* diagnostic=match List.assoc_opt "nativeError" fields with
      | None->Ok []
      | Some error->(match Browser_ego_workflow.validate_native_error error,outcome with
        | Ok value,_->Ok ["nativeError",value]
        (* An unreadable cleanup diagnostic cannot erase an independently
           verified interval. The caller still reports cleanup as partial. *)
        | Error _,Raw_type.Completed {cleanup=(Not_attempted|Unconfirmed);_}->Ok []
        | Error _,(Raw_type.Completed {cleanup=Returned;_}|Not_entered _|Entered_unconfirmed _)->Error unknown) in
    let failure failed = Error (Live.Observed_failure {disposition=Live.Uncertain;
      message="native typing window is unconfirmed; inspect the same Page and never replay the input";
      receipt=obj (["tabId",`Int id;"action",str "type_text";"effectStarted",`Bool true;
        "nativeInputFailure",Raw_type.public_failure failed] @ diagnostic)}) in
    match outcome with
    | Raw_type.Not_entered failed ->
      let* ()=before (Input.not_started t.input ~generation:pending.generation) in failure failed
    | Raw_type.Entered_unconfirmed failed -> failure failed
    | Raw_type.Completed {expected;completion;cleanup} ->
      let* answer=Browser_ego_release.answer_of_window ~expected completion |> Result.map_error (fun _->unknown) in
      let* ()=match Browser_ego_release.judge [0,answer] with
        | Browser_ego_release.Unconfirmed _ -> Error unknown
        | Settled settled -> settle_input t (Some pending) settled |> Result.map_error (fun _->unknown) in
      let receipt=obj (["tabId",`Int id;"action",str "type_text";"receipt",`Null;
        "nativeCompletion",Browser_ego_native_window.public_summary completion] @ diagnostic) in
      match cleanup with
      | Raw_type.Returned -> Ok receipt
      | Not_attempted|Unconfirmed -> Error (Live.Partial_failure {tab_id=id;receipt;
          message="native typing completed but native instrumentation cleanup is unconfirmed; never replay the input"})

let interact ?actor t args =
  let before result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  let unavailable_input reason = Error (Live.Before_effect (Browser_lane.Native_input.message reason)) in
  let* fields = before (match args with `Assoc fields -> Ok fields | _ -> Error "invalid interaction") in
  let* request = before (Browser_interaction.parse (obj (("lane",str Browser_lane.Lane_name.(to_wire Live)) :: fields))) in
  let* () = match Browser_lane.Native_input.unavailable (Browser_lane.ego_input_contract request.action) with
    | None -> Ok ()
    | Some reason -> unavailable_input reason in
  let id = request.tab_id in
  let verb = Browser_lane.interaction_verb request.action in
  let* label = label_of t id in
  let deadline = command_deadline t (Browser_lane.Page_interact {tab_id = id; expected_url = request.expected_url; action = request.action}) in
  let input ~expected_url action = Browser_lane.interaction_args ~tab_id:id ~expected_url action in
  let* expected_url, action =
    let needs_resolution = match request.action with
      | Browser_lane.Click _ -> false
      | Browser_lane.Hover target | Browser_lane.Double_click target ->
        (match target with Browser_lane.Selector _ -> false | Browser_lane.Scene_node _ -> true)
      | Browser_lane.Drag_to _ -> false
      | Browser_lane.Activate_tab | Browser_lane.Fill _ | Browser_lane.Select_option _
      | Browser_lane.Set_viewport _ | Browser_lane.Type_text _ | Browser_lane.Press_key _
      | Browser_lane.Scroll _ | Browser_lane.Hover_at _
      | Browser_lane.Tap_at _ | Browser_lane.Swipe _ | Browser_lane.Click_at _ | Browser_lane.Double_click_at _
      | Browser_lane.Scroll_at _ | Browser_lane.Follow_link _ | Browser_lane.Click_node _
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
      ~receipt:Browser_interaction.pointer_receipt_script
      ~input:(input ~expected_url action) ~lines:(motion_lines motion) ~fields:(["x",`Int x;"y",`Int y;cursor] @ motion_fields motion) in
  let keyboard chord =
    guarded_input t ~id ~label ~deadline ~verb ~step:"page.keyboard" ~guard:Browser_interaction.keyboard_guard_script
      ~receipt:Browser_interaction.pointer_receipt_script
      ~input:(input ~expected_url action) ~lines:["        await page.keyboard.press(args.keys);"] ~fields:(keys_fields chord) in
  (* The page viewport through the Page's CDP session. The override stays
     while the SDK process that set it runs, across commands that reopen the
     task space, moves and reloads; a new process starts without it, which
     the answer's sdkProcessStartedAt tells (RFC-browser-ego-cdp-capabilities
     §3.2). ego says raw CDP invalidates snapshot refs. A set size is the
     page's size when the command returns; a cleared one is not always, so
     the receipt waits until the size moves off the override, up to
     [viewport_restore_wait_ms]. *)
  let viewport size =
    let metrics, lifetime = match size with
      | Browser_lane.Fit {width;height} -> obj ["width",`Int width;"height",`Int height], ["lifetime",str "ego_sdk_process"]
      | Browser_lane.Browser_default -> `Null, [] in
    let* receipt = guarded_input t ~id ~label ~deadline ~verb ~step:"page.viewport" ~guard:Browser_interaction.url_guard_script
      ~receipt:Browser_interaction.viewport_receipt_script
      ~input:(input ~expected_url action) ~fields:["metrics",metrics;"restoreWaitMs",`Int viewport_restore_wait_ms]
      ~lines:["        if (args.metrics === null) {";
              "          const [width, height] = await page.evaluate(\"[innerWidth, innerHeight]\");";
              "          await page.cdp(\"Emulation.clearDeviceMetricsOverride\", {});";
              "          await page.evaluate(\"new Promise(resolve => { const start = performance.now(); const tick = () => innerWidth !== \" + JSON.stringify(width) + \" || innerHeight !== \" + JSON.stringify(height) + \" || performance.now() - start > \" + JSON.stringify(args.restoreWaitMs) + \" ? resolve(null) : setTimeout(tick, 10); tick(); })\");";
              "        } else await page.cdp(\"Emulation.setDeviceMetricsOverride\", {width: args.metrics.width, height: args.metrics.height, deviceScaleFactor: 0, mobile: false});"] in
    match receipt with
    | `Assoc fields -> Ok (`Assoc (fields @ ("refsInvalidated",`Bool true) :: lifetime))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Live.Outcome_unknown (Printf.sprintf "the set_viewport receipt is not an object; read tab %d before another step" id)) in
  (* Each Input.dispatchTouchEvent answer came after the page handled the
     event; ego says raw CDP invalidates snapshot refs. *)
  let touch (viewport : Browser_lane.Pointer.viewport) start moves =
    let pixels ?(wait = []) point =
      let x, y = Browser_lane.Pointer.viewport_pixels viewport point in `List ([`Int x; `Int y] @ wait) in
    let* receipt = guarded_input t ~id ~label ~deadline ~verb ~step:"page.touch" ~guard:Browser_interaction.pointer_guard_script
      ~receipt:Browser_interaction.pointer_receipt_script ~input:(input ~expected_url action) ~lines:touch_lines
      ~fields:["start",pixels start;"moves",`List (List.map (fun (point, wait_ms) -> pixels ~wait:[`Int wait_ms] point) moves)] in
    match receipt with
    | `Assoc fields -> Ok (`Assoc (fields @ ["refsInvalidated",`Bool true]))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Live.Outcome_unknown (Printf.sprintf "the %s receipt is not an object; read tab %d before another step" verb id)) in
  (* The whole swipe runs inside the command's window, or not at all. *)
  let swipe ~from ~to_ ~viewport ~via ~duration_ms =
    let segments = List.length (touch_segments ~start:from ~via ~destination:to_) in
    let total_s = float_of_int duration_ms *. float_of_int segments /. 1000. in
    if total_s >= left t deadline then
      Error (Live.Before_effect (Printf.sprintf
        "this swipe takes %.3f s (%d segments of durationMs %d), not less than the %.3f s left in the command's window; use a shorter durationMs"
        total_s segments duration_ms (left t deadline)))
    else touch viewport from (touch_moves ~start:from ~via ~destination:to_ ~duration_ms) in
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
  | Browser_lane.Drag_to {source;destination} ->
    native_input t ~id ~label ~cursor:cursor_text ~expected_url ~locator:source
      ~reference:["source",obj ["selector",str source];"destination",obj ["selector",str destination]]
      ~operation:(Target_drag destination)
  | Browser_lane.Click_at {point; viewport; button} -> pointer viewport point (Press {button; count = 1})
  | Browser_lane.Double_click_at {point; viewport} -> pointer viewport point (Press {button = Browser_lane.Pointer.Primary; count = 2})
  | Browser_lane.Hover_at {point; viewport} -> pointer viewport point Move
  | Browser_lane.Scroll_at {point; viewport; x; y} -> pointer viewport point (Wheel {x; y})
  | Browser_lane.Type_text {document_id;text} -> native_type t ~id ~label ~expected_url ~document_id ~text
  | Browser_lane.Press_key {key; _} ->
    (match key.key with
     | Browser_lane.Keyboard.Character scalar when Uchar.to_int scalar > last_pressable_character ->
       Error (Live.Before_effect press_refused)
     | Browser_lane.Keyboard.Character _ | Browser_lane.Keyboard.Named _ -> keyboard key)
  | Browser_lane.Fill_node _ | Browser_lane.Scroll _ | Browser_lane.Follow_link _ ->
    dom_input t ~id ~label ~deadline ~verb (input ~expected_url action)
  | Browser_lane.Click_node _ | Browser_lane.Hover (Browser_lane.Scene_node _) | Browser_lane.Double_click (Browser_lane.Scene_node _) ->
    Error (Live.Before_effect "unresolved semantic pointer target")
  | Browser_lane.Click_target target -> on_target ~target Target_click
  | Browser_lane.Fill_target {target; text} -> on_target ~target (Target_fill text)
  | Browser_lane.Hover_target target -> on_target ~target Target_hover
  | Browser_lane.Double_click_target target -> on_target ~target Target_double_click
  | Browser_lane.Set_viewport size -> viewport size
  | Browser_lane.Tap_at {point; viewport} -> touch viewport point []
  | Browser_lane.Swipe {from; to_; viewport; via; duration_ms} -> swipe ~from ~to_ ~viewport ~via ~duration_ms

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
      ~holder:Operator_holds ~args:(obj ["spaceId",`Int t.space.id]) Browser_ego_takeover.script)
        |> settle_open t with
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
   Both the caller and native runner use executor-owned waits. Forward the
   caller's options unchanged; omitted options retain the SDK defaults. *)
let wait_for_control t (options : Browser_lane.Action.control_wait) =
  t.space_observation <- None;
  let args=obj ["controlOptions",Browser_lane.Action.control_wait_to_json options] in
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

let space_status t =
  (* Only an authoritative inventory can establish absence. A failed query
     remains unknown; neither outcome changes the original attachment. *)
  let module Observation=Browser_ego_space_observation in
  t.space_observation <- None;
  let presence,observation=presence_of t (run_native_script t (space_status_script ~space_id:t.space.id)) in
  t.space_presence <- presence;
  t.space_observation <- observation;
  match presence.state,observation with
  | Present,Some observation ->
    (match Observation.to_json observation with
     | `Assoc fields -> Ok (obj (("action",str "space_status")::fields))
     | _ -> Error (Live.Before_effect "invalid encoded Space observation"))
  | Missing,None -> Error (Live.Before_effect space_missing_refused)
  | Unknown reason,None -> Error (Live.Before_effect (unknown_presence_message reason))
  | (Present,None)|((Missing|Unknown _),Some _) -> Error (Live.Before_effect "inconsistent native Space presence observation")

let page_management_script = {js|async (task, args) => {
  const tabs = await task.tabs();
  let page;
  if (args.action === "adopt_tab") {
    const tab = tabs.find(row => row.targetId === args.targetId);
    // Native inventory omits unmanaged labels; only our public JSON uses null.
    if (!tab || tab.label !== undefined || tab.openedBy !== "unknown")
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
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Close_tab}) -> close_tab t tab_id
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Stop_loading}) -> stop_loading t tab_id
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Reload}) -> reload t tab_id
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Back as interaction}) ->
    traverse t tab_id ~action:"back" ~delta:(-1) ~side:"earlier" interaction
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Forward as interaction}) ->
    traverse t tab_id ~action:"forward" ~delta:1 ~side:"later" interaction
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Accept_dialog text}) ->
    answer_dialog t tab_id ~accept:true text
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Dismiss_dialog}) ->
    answer_dialog t tab_id ~accept:false None
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Upload {target = Browser_lane.Action.File_input selector; paths}}) ->
    upload t tab_id ~selector ~paths
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Upload {target = Browser_lane.Action.Chooser_opener opener; paths}}) ->
    choose_files ?actor t tab_id ~opener ~paths
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Set_emulation emulation}) ->
    emulate t tab_id (Some emulation)
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Clear_emulation}) ->
    emulate t tab_id None
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Block_requests hosts}) ->
    block_requests t tab_id (Some hosts)
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Unblock_requests}) ->
    block_requests t tab_id None
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Set_cookie cookie}) ->
    cookie_write t tab_id (`Set cookie)
  | Ok (Browser_lane.Action.On_tab {tab_id; interaction = Browser_lane.Action.Delete_cookie name}) ->
    cookie_write t tab_id (`Delete name)

let workflow ?actor t args =
  let pre result = Result.map_error (fun detail -> Live.Before_effect detail) result in
  let* request = pre (Browser_lane.Native_workflow.of_json args) in
  let* () = Browser_lane.Native_workflow.validate_input_contract request
    |> Result.map_error (fun reason -> Live.Before_effect (Browser_lane.Native_workflow.unavailable_input_message reason)) in
  let* _ = pre (Browser_page_script.text_cap (Some request.max_chars)) in
  let* label = label_of t request.tab_id in
  let holds_input=List.exists (fun (step : Browser_lane.Native_workflow.step) ->
    Browser_lane.Native_workflow.holds_input step.action) request.steps in
  let raw_indices=List.filter_map (fun (index,(step:Browser_lane.Native_workflow.step)) ->
    match step.action with Browser_lane.Native_workflow.Keyboard_type _ -> Some index
    | Click _|Click_and_wait_for_popup _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
    | Fill _|Press _|Focus _|Reload|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
    | Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
    | Evaluate _|Wait_for_function _|Fetch _|Cancel_download _|Url|Title|Info|Snapshot|Events|Wait_for_timeout _ -> None)
      (List.mapi (fun index step->index,step) request.steps) in
  let scope=if List.exists (fun (step:Browser_lane.Native_workflow.step) -> match step.action with
      | Click_and_wait_for_popup _ -> true
      | Click _|Double_click _|Hover _|Drag_and_drop _|Mouse_click _|Mouse_move _|Mouse_wheel _
      | Fill _|Press _|Focus _|Reload|Keyboard_type _|Keyboard_insert_text _|Keyboard_paste _|Keyboard_press _
      | Select_option _|Goto _|Wait_for_url _|Wait_for_selector _|Wait_for_load_state _
      | Evaluate _|Wait_for_function _|Fetch _|Cancel_download _|Url|Title|Info|Snapshot|Events|Wait_for_timeout _ -> false) request.steps
    then Input.Space_scope else Input.Page_scope in
  let* source=match scope,raw_indices with
    | Input.Page_scope,[] -> Ok None
    | Input.Space_scope,_ | Input.Page_scope,(_::_) ->
      pre (managed_source t ~tab_id:request.tab_id ~label) |> Result.map Option.some in
  let* pending=if holds_input then Input.begin_holding t.input ~scope ~page_label:label
    |> Result.map Option.some |> Result.map_error (fun detail -> Live.Before_effect detail) else Ok None in
  let* windows=match raw_indices,source,pending with
    | [],_,_ -> Ok None
    | (_::_),Some source,Some pending ->
      (match Raw_type.prepare ~command_id:pending.command_id ~generation:pending.generation
          ~source:(window_page source) ~indices:raw_indices with
       | Ok context -> Ok (Some context)
       | Error _ ->
         let* ()=pre (Input.not_started t.input ~generation:pending.generation) in
         Error (Live.Before_effect "native workflow typing context could not be prepared"))
    | (_::_),_,pending ->
      let* ()=match pending with None->Ok ()|Some pending->pre (Input.not_started t.input ~generation:pending.generation) in
      Error (Live.Before_effect "native workflow typing requires its exact input intent and source Page") in
  let arguments = match Browser_lane.Native_workflow.to_json request with
    | `Assoc fields ->
      let expected=match source with
        | None -> []
        | Some identity -> ["expectedSourcePage",source_page_json identity] in
      let native=match windows with None->[]|Some context->["nativeInputWindows",Raw_type.arguments context] in
      obj (native @ expected @ ["inputReceiptContract",Browser_ego_release.receipt_contract;
        "label",str label;"cursor",str (cursor_label ~actor ~verb:"workflow")] @ fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> args in
  let result = run_native_step t ~step:"page.native_workflow" ~args:arguments
      (String.concat "\n" [Browser_ego_workflow.native_error_script;Page_events.script;Raw_type.script;Browser_ego_workflow.script;unblocked_managed_page;
        "    const outcome = await nativeWorkflow(task.page(args.label), args, task, watchDownloads);";
        "    emit({ok: true, value: outcome});";"  }"]) in
  match result with
  | Error error ->
    let* ()=match pending,error with
     | Some pending,(Refused _|Space_unopened _|Unanswered (Unstarted _)) -> Input.not_started t.input ~generation:pending.generation
         |> Result.map_error (fun detail -> Live.Before_effect detail)
     | None,_ | Some _,(Unreadable _|Failed _|Unanswered (Exited _|Signaled _|Timed_out|Output_exceeded|Unobserved _)) -> Ok () in
    (match windows,error with
     | Some _,(Refused _|Unanswered (Unstarted _)) -> Error (Live.Before_effect "native workflow was refused before its producer ran")
     | Some _,Space_unopened detail -> Error (Live.Before_effect detail)
     | Some _,(Unreadable _|Failed _|Unanswered (Exited _|Signaled _|Timed_out|Output_exceeded|Unobserved _)) ->
       Error (Live.Outcome_unknown "native workflow result is unknown; read the same tab before another step; never replay the workflow")
     | None,_ -> Error (effect_failure ~unknown:"native workflow result is unknown; read the same tab before another step; never replay the workflow" error))
  | Ok value ->
    let unknown detail = Live.Outcome_unknown (detail ^ "; read the same tab and do not replay the workflow") in
    let* outcome=Browser_ego_workflow.decode ~windows request value |> Result.map_error unknown in
    let pages=match outcome with Browser_ego_workflow.Completed {pages;_}|Stopped {pages;_} -> pages in
    let* ()=match pages with
      | None -> Ok ()
      | Some pages when source=Some pages.source -> Ok ()
      | Some _ -> Error (unknown "workflow source Page disagrees with its full pre-effect native identity") in
    let tab_of_page (identity:Browser_ego_workflow.page_identity) = remember t (Managed identity.label) in
    let current_tab=match pages with None -> request.tab_id | Some pages -> tab_of_page pages.current in
    let* ()=if holds_input then (match outcome with
      | Browser_ego_workflow.Completed {input;_}|Stopped {input=Browser_ego_release.Settled input;_} -> settle_input t pending input |> Result.map_error unknown
      | Stopped {input=Browser_ego_release.Unconfirmed _;_} -> Ok ()) else Ok () in
    let receipt_of value=match value with
      | `Assoc fields ->
        let fields=match pages with
          | None -> fields
          | Some pages ->
            let page_json (identity:Browser_ego_workflow.page_identity) =
              let native=Browser_surface.ego_page_fields
                {label=Some identity.label;target_id=identity.target_id;opened_by=identity.opened_by} in
              obj (("spaceId",`Int identity.space_id)::("tabId",`Int (tab_of_page identity))::native) in
            let observed=obj ["source",page_json pages.source;"current",page_json pages.current;
              "transitions",`List (List.map (fun (transition:Browser_ego_workflow.transition) -> obj [
                "index",`Int transition.index;"source",page_json transition.source;
                "popup",page_json transition.popup;"selected",`Bool transition.selected]) pages.transitions)] in
            ("sourceTabId",`Int request.tab_id)::("pages",observed)::List.remove_assoc "pages" fields in
        Ok (obj (("tabId",`Int current_tab)::("action",str "workflow")::fields))
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error (unknown "workflow receipt is not an object") in
    match outcome with
    | Browser_ego_workflow.Completed {reply=value;input=_;pages=_} -> receipt_of value
    | Browser_ego_workflow.Stopped {receipt=value;message=detail;effect_started;completed_effect;input=_;native_error;pages=_;
        refused_before_press} ->
      let message=head detail ^ "; read the same tab before continuing; never replay the workflow" in
      if completed_effect then
        let* receipt=receipt_of value in Error (Live.Partial_failure {tab_id=current_tab;receipt;message})
      else match native_error with
        | Some _ ->
          let* receipt=receipt_of value in
          let disposition=if effect_started then Live.Uncertain else Live.Not_started in
          Error (Live.Observed_failure {disposition;message;receipt})
        | None -> if effect_started && (Option.is_some pages || Option.is_some refused_before_press) then
            (* A refused step's receipt carries the SDK kind the caller needs to pick a narrower target. *)
            let* receipt=receipt_of value in Error (Live.Observed_failure {disposition=Live.Uncertain;message;receipt})
          else if effect_started then Error (Live.Outcome_unknown message)
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
  | Page_context -> pre (dialog_read t args)
  | Page_snapshot -> pre (snapshot t args)
  | Page_downloads -> pre (downloads t args)
  | Page_cookies -> pre (storage_names t args)
  | Page_network -> pre (network_log t args)
  | Page_console -> console_read t args
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
        | Ok (Open_tab _|Control (Hand_off|Take_over|Wait_for_control _|Adopt_tab _|Release_tab _)|On_tab _)
        | Error _ -> Error (Live.Before_effect "Space completion is terminal or uncertain; former Page/control work is refused; use space_status to reconcile"))
    | Tabs_list|Page_read|Page_elements|Page_scene|Page_capture|Page_goto|Page_context|Page_snapshot
    | Page_downloads|Page_cookies|Page_network|Page_console|Page_interact|Page_native_workflow ->
      Error (Live.Before_effect "Space completion is terminal or uncertain; former Page work is refused; use space_status to reconcile")

let dispatch ?command_id ?actor t ~verb args =
  let command_id=match command_id with Some id -> id
    | None -> Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let annotate = function
    | `Assoc fields -> `Assoc (("inputReadiness",str (Input.readiness_wire t.input)) :: List.remove_assoc "inputReadiness" fields)
    | value -> value in
  match Input.within_command t.input ~command_id (fun () -> let* ()=admit_after_finish t ~verb args in dispatch_raw ?actor t ~verb args) with
  | Error detail -> Error (Live.Before_effect detail)
  | Ok (Ok value) -> Ok (annotate value)
  | Ok (Error (Live.Partial_failure partial)) -> Error (Live.Partial_failure {partial with receipt=annotate partial.receipt})
  | Ok (Error (Live.Observed_failure observed)) ->
    Error (Live.Observed_failure {observed with receipt=annotate observed.receipt})
  | Ok (Error (Live.Before_effect _|Outcome_unknown _) as failure) -> failure

(* What leaves the peer. A failure that is only a message becomes the observed
   failure with the same effect phase, so its receipt can say where input
   stands and which SDK process holds this connection's CDP settings. *)
let with_session_state t ~sdk_process_started_at result =
  let started = match sdk_process_started_at with Some at -> `Float at | None -> `Null in
  let stamp = function
    | `Assoc fields -> `Assoc (("inputReadiness",str (Input.readiness_wire t.input))
        :: ("sdkProcessStartedAt",started)
        :: List.remove_assoc "sdkProcessStartedAt" (List.remove_assoc "inputReadiness" fields))
    | value -> value in
  match result with
  | Ok value -> Ok (stamp value)
  | Error (Live.Before_effect message) ->
    Error (Live.Observed_failure {disposition=Live.Not_started;message;receipt=stamp (obj [])})
  | Error (Live.Outcome_unknown message) ->
    Error (Live.Observed_failure {disposition=Live.Uncertain;message;receipt=stamp (obj [])})
  | Error (Live.Partial_failure partial) -> Error (Live.Partial_failure {partial with receipt=stamp partial.receipt})
  | Error (Live.Observed_failure observed) -> Error (Live.Observed_failure {observed with receipt=stamp observed.receipt})
