type activity = Starting | Running | Stopping | Stopped | Worker_failed of string
type worker = { instance_id : string; matches_desired : bool; activity : activity }
type t = Starting_worker | Cleaning_workers | Applied of string | Inactive
  | Failed of string list | Unknown of string list

let observe ~enabled ~complete ~issues ~workers =
  if not complete then Unknown ("Declaration or worker inventory is incomplete" :: issues)
  else
    let failures = List.filter_map (fun worker -> match worker.activity with
      | Worker_failed detail -> Some (worker.instance_id ^ ": " ^ detail)
      | Starting | Running | Stopping | Stopped -> None) workers in
    match issues @ failures with
    | _ :: _ as errors -> Failed errors
    | [] ->
        let active = List.filter (fun worker -> match worker.activity with
          | Stopped -> false | Starting | Running | Stopping | Worker_failed _ -> true) workers in
        if not enabled then (match active with [] -> Inactive | _ :: _ -> Cleaning_workers)
        else if List.exists (fun worker -> not worker.matches_desired) active then Cleaning_workers
        else match active with
          | [] -> Starting_worker
          | [worker] -> (match worker.activity with
              | Running -> Applied worker.instance_id
              | Starting -> Starting_worker
              | Stopping -> Cleaning_workers
              | Stopped -> Starting_worker
              | Worker_failed detail -> Failed [detail])
          | _ :: _ -> Unknown ["Multiple workers claim the desired declaration"]

let to_json state =
  let fields = match state with
    | Starting_worker -> ["kind", `String "starting"]
    | Cleaning_workers -> ["kind", `String "cleaning"]
    | Applied instance_id -> ["kind", `String "applied"; "instance_id", `String instance_id]
    | Inactive -> ["kind", `String "inactive"]
    | Failed messages -> ["kind", `String "failed"; "messages", `List (List.map (fun text -> `String text) messages)]
    | Unknown messages -> ["kind", `String "unknown"; "messages", `List (List.map (fun text -> `String text) messages)] in
  `Assoc fields
