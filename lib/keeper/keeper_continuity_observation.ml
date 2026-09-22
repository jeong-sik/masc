type frontier = { trace_id : string; end_atom : int; boundary_line : int }
type input = Summarized of frontier | Uncompressed | Not_applied
type t =
  { prepared_at : float
  ; runtime_id : string
  ; input : input
  ; request_bytes : int
  }

type synthesis_state =
  | Checking | Running | Committed | No_source
  | Disabled | Source_unavailable | Input_unavailable | Not_committed
  | Capacity_refused | Cancelled

type atom_range = { start_atom : int; end_atom : int; completed_end_atom : int }
type synthesis =
  { observed_at : float
  ; trace_id : string option
  ; state : synthesis_state
  ; range : atom_range option
  }

let syntheses : ((string * string), synthesis) Hashtbl.t = Hashtbl.create 16
let observations : ((string * string), t) Hashtbl.t = Hashtbl.create 16
let mutex = Stdlib.Mutex.create ()
let key ~config ~keeper_name = Workspace.keepers_runtime_dir config, keeper_name
let record ~config ~keeper_name observation =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.replace observations (key ~config ~keeper_name) observation)
let latest ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.find_opt observations (key ~config ~keeper_name))
let forget ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.remove observations (key ~config ~keeper_name);
    Hashtbl.remove syntheses (key ~config ~keeper_name))

let record_synthesis ~config ~keeper_name observation =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.replace syntheses (key ~config ~keeper_name) observation)
let latest_synthesis ~config ~keeper_name =
  Stdlib.Mutex.protect mutex (fun () ->
    Hashtbl.find_opt syntheses (key ~config ~keeper_name))
let synthesis_state_to_string = function
  | Checking -> "checking" | Running -> "running" | Committed -> "committed"
  | No_source -> "no_source" | Disabled -> "disabled"
  | Source_unavailable -> "source_unavailable" | Input_unavailable -> "input_unavailable"
  | Not_committed -> "not_committed" | Capacity_refused -> "capacity_refused"
  | Cancelled -> "cancelled"
let synthesis_to_json (value : synthesis) =
  `Assoc ["observed_at", `Float value.observed_at;
    "trace_id", (match value.trace_id with None -> `Null | Some trace -> `String trace);
    "state", `String (synthesis_state_to_string value.state);
    "range", (match value.range with None -> `Null | Some range ->
      `Assoc ["start_atom", `Int range.start_atom; "end_atom", `Int range.end_atom;
        "completed_end_atom", `Int range.completed_end_atom])]
let synthesis_of_json json =
  let ( let* ) = Result.bind in
  let object_fields keys = function
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare keys -> Ok fields
    | _ -> Error "invalid synthesis observation fields" in
  let* fields = object_fields ["observed_at"; "trace_id"; "state"; "range"] json in
  let* observed_at = match List.assoc "observed_at" fields with
    | `Float time when Float.is_finite time && time >= 0. -> Ok time
    | `Int time when time >= 0 -> Ok (float_of_int time)
    | _ -> Error "invalid synthesis observation time" in
  let* trace_id = match List.assoc "trace_id" fields with
    | `Null -> Ok None
    | `String trace when String.trim trace <> "" -> Ok (Some trace)
    | _ -> Error "invalid synthesis trace" in
  let* state = match List.assoc "state" fields with
    | `String "checking" -> Ok Checking | `String "running" -> Ok Running
    | `String "committed" -> Ok Committed | `String "no_source" -> Ok No_source
    | `String "disabled" -> Ok Disabled | `String "source_unavailable" -> Ok Source_unavailable
    | `String "input_unavailable" -> Ok Input_unavailable | `String "not_committed" -> Ok Not_committed
    | `String "capacity_refused" -> Ok Capacity_refused | `String "cancelled" -> Ok Cancelled
    | _ -> Error "invalid synthesis state" in
  let* range = match List.assoc "range" fields with
    | `Null -> Ok None
    | json ->
      let* fields = object_fields ["start_atom"; "end_atom"; "completed_end_atom"] json in
      match List.assoc "start_atom" fields, List.assoc "end_atom" fields, List.assoc "completed_end_atom" fields with
      | `Int start_atom, `Int end_atom, `Int completed_end_atom
        when start_atom >= 0 && end_atom > start_atom && completed_end_atom >= end_atom ->
        Ok (Some {start_atom; end_atom; completed_end_atom})
      | _ -> Error "invalid synthesis atom range" in
  if (Option.is_some range && Option.is_none trace_id)
     || (match state, range with (Running | Committed), None -> true | _ -> false)
  then Error "synthesis state lacks source evidence"
  else Ok {observed_at; trace_id; state; range}
