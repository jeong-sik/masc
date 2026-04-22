(** Lightweight filesystem reader for [.masc/governance_v2/cases/].

    The governance case tracking UI was retired (dashboard hardcoded
    [("pending_ruling", Int 0)]), but stale case files remain on disk
    from before the retirement — and [Meta_cognition_snapshot] still
    consumes them.  This helper surfaces the raw counts so the
    dashboard can report the truth instead of a constant zero.

    See #7815. *)

type case = {
  id : string;
  title : string;
  status : string;
  risk_class : string;
  created_at : float;
}

let persistence_surface = "governance_cases_snapshot"

let observe_drop ~reason =
  Prometheus.inc_counter Prometheus.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)] ()

let report_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> observe_drop ~reason)
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let cases_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "governance_v2/cases"

let parse_case ~path (json : Yojson.Safe.t) : case option =
  let id = Safe_ops.json_string ~default:"" "id" json in
  if id = "" then (
    report_drop
      ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
      ~path
      ~detail:"missing required id";
    None
  )
  else
    let title = Safe_ops.json_string ~default:"" "title" json in
    let status = Safe_ops.json_string ~default:"" "status" json in
    let risk_class = Safe_ops.json_string ~default:"" "risk_class" json in
    let created_at =
      match json |> Yojson.Safe.Util.member "created_at" with
      | `Float f -> f
      | `Int i -> float_of_int i
      | _ -> 0.0
    in
    Some { id; title; status; risk_class; created_at }

let load_all ~base_path : case list =
  let dir = cases_dir ~base_path in
  if not (Sys.file_exists dir) then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
      report_drop ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error ~path:dir ~detail;
      []
    | Ok names ->
      names
      |> List.filter (fun name ->
        Filename.check_suffix name ".json"
        && not (String.starts_with ~prefix:"_" name))
      |> List.filter_map (fun name ->
        let path = Filename.concat dir name in
        match
          Safe_ops.result_to_option_logged
            ~on_drop:(fun () ->
              observe_drop ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error)
            ~surface:persistence_surface
            ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
            ~path
            (Safe_ops.read_json_file_safe path)
        with
        | None -> None
        | Some json -> parse_case ~path json)

let count_by_status ~base_path ~status =
  load_all ~base_path
  |> List.filter (fun c -> c.status = status)
  |> List.length

let pending_ruling_count ~base_path =
  count_by_status ~base_path ~status:"pending_ruling"

let oldest_pending_ruling_age_s ~base_path ~now_ts : float option =
  load_all ~base_path
  |> List.filter (fun c -> c.status = "pending_ruling")
  |> List.fold_left
    (fun acc c ->
      let age = now_ts -. c.created_at in
      if age < 0.0 then acc
      else
        match acc with
        | None -> Some age
        | Some current -> Some (Float.max current age))
    None
