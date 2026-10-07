type kind = Claim | Conflict
type source = { id : string; kind : kind; text : string }
type summary = { source_ids : string list; text : string }
type publication = { keys : (string * string) list; text : string; contract : string }
type building =
  { target : (string * string) list
  ; remaining : source list
  ; text : string option
  ; contract : string
  }
type t = { published : publication option; building : building option }
type observation = Missing | Current of summary | Stale of summary
type batch =
  { state : t
  ; selected : source list
  ; remaining : source list
  ; input : Yojson.Safe.t
  ; rendered_prompt : string
  }
type preparation = Unchanged | Cleanup of t | Prepared of batch

let ( let* ) = Result.bind
let empty = { published = None; building = None }
let is_empty t = match t.published, t.building with
  | None, None -> true
  | Some _, _ | _, Some _ -> false
let nonblank value = String.trim value <> ""
let kind_name = function Claim -> "claim" | Conflict -> "conflict"
let source_json (source : source) = `Assoc
  ["id", `String source.id; "kind", `String (kind_name source.kind);
   "text", `String source.text]
let source_key source =
  source.id, Digestif.SHA256.(digest_string (Yojson.Safe.to_string (source_json source)) |> to_hex)
let source_keys sources = List.map source_key sources |> List.sort_uniq Stdlib.compare
module Keys = Set.Make (struct type t = string * string let compare = Stdlib.compare end)
let subset left right = Keys.subset (Keys.of_list left) (Keys.of_list right)
let summary (publication : publication) =
  { source_ids = List.map fst publication.keys; text = publication.text }

let observe ~sources ~contract t =
  match sources, t.published with
  | [], _ -> Current { source_ids = []; text = "" }
  | _ :: _, None -> Missing
  | _ :: _, Some published ->
    if String.equal published.contract contract && source_keys sources = published.keys
    then Current (summary published)
    else Stale (summary published)

let input batch = batch.input
let rendered_prompt batch = batch.rendered_prompt
let selected_count batch = List.length batch.selected
let remaining_count batch = List.length batch.remaining
let prepared_state batch = batch.state

let validate_sources sources =
  let rec check seen = function
    | [] -> Ok ()
    | (source : source) :: rest ->
      if not (nonblank source.id && nonblank source.text)
      then Error "briefing sources require nonblank ids and text"
      else if Set_util.StringSet.mem source.id seen
      then Error ("briefing repeats source id: " ^ source.id)
      else check (Set_util.StringSet.add source.id seen) rest in
  check Set_util.StringSet.empty sources

let needs_refresh ~sources ~contract t =
  match sources with
  | [] -> false
  | _ :: _ ->
    (match validate_sources sources, t.published with
     | Ok (), Some published ->
       not (String.equal published.contract contract && source_keys sources = published.keys)
     | Error _, _ | Ok (), None -> true)

let start_pass ~sources ~contract (published : publication option) =
  let target = source_keys sources in
  let previous = match published with
    | Some previous when String.equal previous.contract contract
                         && subset previous.keys target -> Some previous
    | Some _ | None -> None in
  let previous_keys = match previous with
    | None -> Keys.empty | Some previous -> Keys.of_list previous.keys in
  { target
  ; remaining = List.filter (fun source -> not (Keys.mem (source_key source) previous_keys)) sources
  ; text = Option.map (fun (previous : publication) -> previous.text) previous
  ; contract
  }

let model_input previous selected = `Assoc
  ["previous_summary", (match previous with None -> `Null | Some text -> `String text);
   "entries", `List (List.map source_json selected)]

let render_batch ~render ~state ~selected ~remaining =
  match state.building with
  | None -> Error "briefing batch has no active pass"
  | Some building ->
    let input = model_input building.text selected in
    let* rendered_prompt = render input in
    Ok { state; selected; remaining; input; rendered_prompt }

let prepare ~sources ~contract ~render t =
  let* () = validate_sources sources in
  if not (needs_refresh ~sources ~contract t) then
    match sources, t.building with
    | [], _ -> Ok (if is_empty t then Unchanged else Cleanup empty)
    | _ :: _, Some _ -> Ok (Cleanup { t with building = None })
    | _ :: _, None -> Ok Unchanged
  else if not (nonblank contract) then Error "briefing contract must be nonblank"
  else
    let sources = List.sort (fun (a : source) b -> String.compare a.id b.id) sources in
    let keys = source_keys sources in
    let building = match t.building with
      | Some building when String.equal building.contract contract && subset building.target keys -> building
      | Some _ -> start_pass ~sources ~contract None
      | None -> start_pass ~sources ~contract t.published in
    let state = { t with building = Some building } in
    let* batch = render_batch ~render ~state ~selected:building.remaining ~remaining:[] in
    Ok (Prepared batch)

let narrow ~render batch =
  match batch.selected with
  | [] | [_] -> Ok None
  | _ :: _ :: _ ->
    (* Bisection after an actual size refusal, not an estimated byte/token
       allowance. Both halves retain complete source entries. *)
    let prefix_length = List.length batch.selected / 2 in
    let selected = List.take prefix_length batch.selected in
    let remaining = List.drop prefix_length batch.selected @ batch.remaining in
    let* smaller = render_batch ~render ~state:batch.state ~selected ~remaining in
    Ok (Some smaller)

let output_schema = `Assoc
  ["type", `String "object";
   "properties", `Assoc ["briefing", `Assoc ["type", `String "string"; "minLength", `Int 1]];
   "required", `List [`String "briefing"]; "additionalProperties", `Bool false]

let contract ~template =
  Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (`List [`String template; output_schema])) |> to_hex)

let exact_fields what names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error (what ^ " has unknown, missing, or repeated fields")
let string = function `String text when nonblank text -> Ok text | _ -> Error "briefing expects nonblank text"
let decode_output json =
  let* fields = exact_fields "briefing output" ["briefing"] json in
  string (List.assoc "briefing" fields)

let accept batch ~text =
  if not (nonblank text) then Error "briefing output must be nonblank"
  else match batch.state.building with
  | None -> Error "briefing batch has no active pass"
  | Some building ->
    if batch.remaining = [] then
      Ok { published = Some { keys = building.target; text; contract = building.contract }; building = None }
    else Ok { batch.state with building = Some { building with remaining = batch.remaining; text = Some text } }

(* State encoding retains only source identities and not-yet-consumed entries.
   Completed raw prose is represented by the model's semantic summary. *)
let keys_json keys = `List (List.map (fun (id, digest) ->
  `Assoc ["id", `String id; "sha256", `String digest]) keys)
let option_json encode = function None -> `Null | Some value -> encode value
let publication_json (p : publication) = `Assoc
  ["sources", keys_json p.keys; "text", `String p.text; "contract", `String p.contract]
let building_json (b : building) = `Assoc
  ["target", keys_json b.target; "remaining", `List (List.map source_json b.remaining);
   "text", option_json (fun text -> `String text) b.text; "contract", `String b.contract]
let to_json t = `Assoc
  ["schema", `String "workspace.memory.briefing.v1";
   "published", option_json publication_json t.published;
   "building", option_json building_json t.building]

let traverse decode rows =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest -> let* value = decode row in loop (value :: acc) rest in
  loop [] rows
let array decode = function
  | `List values -> traverse decode values
  | _ -> Error "briefing state expects an array"
let option decode = function `Null -> Ok None | json -> Result.map Option.some (decode json)
let decode_source json =
  let* fields = exact_fields "briefing source" ["id"; "kind"; "text"] json in
  let* id = string (List.assoc "id" fields) in
  let* text = string (List.assoc "text" fields) in
  let* kind = match List.assoc "kind" fields with
    | `String "claim" -> Ok Claim | `String "conflict" -> Ok Conflict
    | _ -> Error "unknown briefing source kind" in
  Ok { id; kind; text }
let decode_keys json =
  let* keys = array (fun json ->
    let* fields = exact_fields "briefing source identity" ["id"; "sha256"] json in
    let* id = string (List.assoc "id" fields) in
    let* digest = string (List.assoc "sha256" fields) in
    if String.length digest <> 64 || not (String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) digest)
    then Error "briefing source identity is not a SHA256 digest"
    else Ok (id, digest)) json in
  let ids = List.map fst keys in
  if List.length ids <> List.length (List.sort_uniq String.compare ids)
  then Error "briefing state repeats a source id"
  else Ok (List.sort Stdlib.compare keys)
let decode_publication json =
  let* fields = exact_fields "briefing publication" ["sources"; "text"; "contract"] json in
  let* keys = decode_keys (List.assoc "sources" fields) in
  let* text = string (List.assoc "text" fields) in
  let* contract = string (List.assoc "contract" fields) in
  if keys = [] then Error "nonempty briefing publication has no sources"
  else Ok { keys; text; contract }
let decode_building json =
  let* fields = exact_fields "briefing pass" ["target"; "remaining"; "text"; "contract"] json in
  let* target = decode_keys (List.assoc "target" fields) in
  let* remaining = array decode_source (List.assoc "remaining" fields) in
  let* () = validate_sources remaining in
  let* text = option string (List.assoc "text" fields) in
  let* contract = string (List.assoc "contract" fields) in
  let remaining_keys = source_keys remaining in
  if remaining = [] || not (subset remaining_keys target)
  then Error "briefing pass must retain unconsumed entries from its target"
  else if (remaining_keys = target) <> Option.is_none text
  then Error "briefing pass summary does not match its consumed source boundary"
  else Ok { target; remaining; text; contract }
let of_json json =
  let* fields = exact_fields "briefing state" ["schema"; "published"; "building"] json in
  match List.assoc "schema" fields with
  | `String "workspace.memory.briefing.v1" ->
    let* published = option decode_publication (List.assoc "published" fields) in
    let* building = option decode_building (List.assoc "building" fields) in
    Ok { published; building }
  | _ -> Error "unknown workspace briefing schema"

let path ~directory = Filename.concat directory "briefing.json"
let io f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (error, fn, arg) -> Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))
  | Sys_error detail -> Error detail
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)
let load ~directory = io (fun () ->
  match Fs_compat.load_file_opt (path ~directory) with
  | None -> Ok empty
  | Some text ->
    let* json = try Ok (Yojson.Safe.from_string text) with
      | Yojson.Json_error detail -> Error detail in
    of_json json)
let save ~directory t = io (fun () ->
  Fs_compat.mkdir_p directory;
  match Fs_compat.save_file_atomic_strict_staged (path ~directory) (Yojson.Safe.to_string (to_json t)) with
  | Ok () -> Ok ()
  | Error failure ->
    match failure.exception_ with
    | Eio.Cancel.Cancelled _ as exn -> Printexc.raise_with_backtrace exn failure.backtrace
    | _ -> Error (Fs_compat.atomic_replace_failure_to_string failure))
