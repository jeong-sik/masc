
type deps = {
  query_param : Httpun.Request.t -> string -> string option;
  int_query_param : Httpun.Request.t -> string -> default:int -> int;
}

let split_csv raw =
  raw
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")

let kind_filters deps request =
  let from_kinds =
    match deps.query_param request "kinds" with
    | Some raw -> split_csv raw
    | None -> []
  in
  let from_kind =
    match deps.query_param request "kind" with
    | Some raw -> split_csv raw
    | None -> []
  in
  from_kinds @ from_kind |> List.sort_uniq String.compare


(* RFC-0201 Step 1.  Default-shaped queries (kinds=[], after_seq=0)
   read from [Dashboard_snapshot.current ()].activity_events_default —
   the snapshot is refreshed every interval_sec by the background
   refresh fiber, so the HTTP path is a wait-free atomic read plus a
   list slice down to the request's [limit].  Non-default queries
   (cursor, kinds filter) fall through to the cache+offload path
   from PR #19150. *)
let slice_default_events_to_limit json ~limit =
  match json with
  | `Assoc fields ->
    let events_list =
      match List.assoc_opt "events" fields with
      | Some (`List xs) -> xs
      | _ -> []
    in
    let len = List.length events_list in
    let sliced =
      if len <= limit then events_list
      else
        (* Drop the oldest entries; snapshot is sorted seq-ascending so
           the most recent [limit] events live at the tail.  Matches
           [Activity_graph.json_response]'s own tail-slice semantics for
           [after_seq=0]. *)
        let drop_count = len - limit in
        List.filteri (fun i _ -> i >= drop_count) events_list
    in
    let next_after_seq =
      match List.rev sliced with
      | (`Assoc last_fields) :: _ ->
        (match List.assoc_opt "seq" last_fields with
         | Some (`Int n) -> `Int n
         | _ -> List.assoc_opt "next_after_seq" fields |> Option.value ~default:(`Int 0))
      | _ ->
        List.assoc_opt "after_seq" fields |> Option.value ~default:(`Int 0)
    in
    let replaced =
      List.map (fun (k, v) ->
        match k with
        | "events" -> (k, `List sliced)
        | "count" -> (k, `Int (List.length sliced))
        | "limit" -> (k, `Int limit)
        | "next_after_seq" -> (k, next_after_seq)
        | _ -> (k, v)) fields
    in
    `Assoc replaced
  | other -> other

let events_http_json ~deps ~state request =

  let kinds = kind_filters deps request in
  let after_seq =
    deps.int_query_param request "after_seq" ~default:0 |> max 0
  in
  let limit =
    deps.int_query_param request "limit" ~default:200
    |> Server_utils.clamp ~min_v:1 ~max_v:1000
  in
  let is_default_query = kinds = [] && after_seq = 0 in
  let snapshot_hit =
    if is_default_query then
      match Dashboard_snapshot.current () with
      | Some snap when snap.activity_events_default <> `Null ->
        Some (slice_default_events_to_limit snap.activity_events_default ~limit)
      | _ -> None
    else None
  in
  match snapshot_hit with
  | Some json -> json
  | None ->
    (* RFC-0201 Step 5.  Cache wrap retired — non-default queries
       (cursor / kinds filter) are operator-driven and rare, so a
       per-key Dashboard_cache entry has marginal hit-rate value.
       Offload via Domain_pool_ref still protects the HTTP main
       domain from JSONL-scan stall. *)
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Activity_graph.json_response (Mcp_server.workspace_config state) ~kinds
        ~after_seq ~limit ())
