module Layout = Dated_jsonl.Layout

type source = Activity | Audit
type availability = Observed | Not_created
let sources = [Activity; Audit]
let store = function Activity -> Dated_jsonl.Store.Root.Activity_events | Audit -> Events
let source_name source = Dated_jsonl.Store.Root.relative_path (store source)
let source_of_name = function "activity-events" -> Some Activity | "events" -> Some Audit | _ -> None
type position = { file : string; device : int; inode : int; before : int; anchor : string }
type ceiling = { file : string; size : int }
type cursor = { task : string; workspace : string; ceilings : ceiling list; inventory : string; position : position }
type error = Invalid_request | Invalid_cursor | Source_changed
  | Invalid_event of { file : string; offset : int }
  | Invalid_layout of { entry : string } | Source_unavailable
type page = { task_id : string; cursor : cursor option; sources : (source * availability) list;
  events : Yojson.Safe.t list; next_cursor : cursor option }
let hash text = Agent_core_sha256.(digest_string text |> to_hex)

let dated_parts relative = match String.split_on_char '/' relative with
  | [source;month;file] -> (match source_of_name source,Layout.year_and_month_of_directory_name month with
    | Some source,Some (year,month_number) when Layout.day_file_name_is_valid ~year ~month:month_number file -> Some (source,month,file)
    | _ -> None)
  | _ -> None
let compare_relative left right = match dated_parts left,dated_parts right with
  | Some (ls,lm,lf),Some (rs,rm,rf) ->
    let order=String.compare lm rm in
    if order<>0 then order else let order=Layout.compare_day_files lf rf in
    if order<>0 then order else String.compare (source_name rs) (source_name ls)
  | _ -> String.compare left right
