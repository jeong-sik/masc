(** Memory subsystem dashboard HTTP JSON helpers. *)

open Server_utils

let memory_subsystems_entry_cache_ttl_sec = 30.0

let memory_subsystems_entry_cache
  : (string * float * (string * Keeper_memory_policy.keeper_memory_line) list) option ref
  =
  ref None
;;

let dashboard_memory_subsystems_include_entries request =
  bool_query_param request "include_memory_entries" ~default:false
  ||
  match query_param request "focus" |> Option.map String.trim with
  | Some "entries" -> true
  | _ -> false
;;

let load_memory_subsystems_entries ~(config : Coord_utils.config) =
  (* NDT-OK: wall-clock read only gates a dashboard cache TTL. *)
  let now = Unix.gettimeofday () in
  match !memory_subsystems_entry_cache with
  | Some (base_path, cached_at, rows)
    when String.equal base_path config.base_path
         && now -. cached_at < memory_subsystems_entry_cache_ttl_sec -> rows
  | _ ->
    let rows =
      try
        Keeper_types.keeper_names config
        |> List.concat_map (fun keeper ->
          try
            let summary =
              Keeper_memory_recall.read_keeper_memory_summary
                config
                ~name:keeper
                ~max_bytes:120000
                ~max_lines:180
                ~recent_limit:30
            in
            List.map
              (fun (row : Keeper_memory_policy.keeper_memory_line) -> keeper, row)
              summary.recent_notes
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> [])
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> []
    in
    memory_subsystems_entry_cache := Some (config.base_path, now, rows);
    rows
;;

let dashboard_memory_subsystems_http_json
      ~(config : Coord_utils.config)
      ?include_memory_entries
      request
  : Yojson.Safe.t
  =
  let include_memory_entries =
    Option.value
      include_memory_entries
      ~default:(dashboard_memory_subsystems_include_entries request)
  in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:500 in
  let keeper_filter =
    query_param request "keeper"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let outcome_filter =
    query_param request "outcome"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let search =
    query_param request "q"
    |> Option.map (fun s -> String.trim s |> String.lowercase_ascii)
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let hebbian =
    try `Null with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> `Assoc [ "synapses", `List []; "last_consolidation", `Float 0.0 ]
  in
  let all_episodes =
    try Institution_eio.load_recent_episodes_jsonl ~limit:max_int with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []
  in
  let total = List.length all_episodes in
  (* Empty filter [q] used to match all episodes; preserve that and
     delegate non-empty matching to the SSOT helper, which scans byte by
     byte without lowercasing the haystack or allocating per position. *)
  let contains_ci haystack needle =
    String.length needle = 0 || String_util.contains_substring_ci haystack needle
  in
  let memory_entry_to_json
        (keeper : string)
        (row : Keeper_memory_policy.keeper_memory_line)
    : Yojson.Safe.t
    =
    `Assoc
      [ "keeper", `String keeper
      ; "kind", `String row.kind
      ; "text", `String row.text
      ; "priority", `Int row.priority
      ; "ts_unix", `Float row.ts_unix
      ]
  in
  let all_memory_entries =
    if include_memory_entries then load_memory_subsystems_entries ~config else []
  in
  let memory_total = List.length all_memory_entries in
  let memory_filtered =
    all_memory_entries
    |> List.filter (fun (keeper, (row : Keeper_memory_policy.keeper_memory_line)) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> String.equal keeper k
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci keeper q || contains_ci row.kind q || contains_ci row.text q
      in
      keeper_ok && search_ok)
  in
  let memory_filtered_total = List.length memory_filtered in
  let memory_entries =
    memory_filtered
    |> List.sort
         (fun
             (_, (a : Keeper_memory_policy.keeper_memory_line))
              (_, (b : Keeper_memory_policy.keeper_memory_line))
            -> compare b.ts_unix a.ts_unix)
    |> take limit
  in
  let filtered =
    all_episodes
    |> List.filter (fun (e : Institution_eio.episode) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> List.mem k e.participants
      in
      let outcome_ok =
        match outcome_filter with
        | None -> true
        | Some "success" -> e.outcome = `Success
        | Some "failure" -> e.outcome = `Failure
        | Some "partial" -> e.outcome = `Partial
        | Some _ -> true
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci e.summary q
          || contains_ci e.event_type q
          || List.exists (fun l -> contains_ci l q) e.learnings
          || List.exists (fun p -> contains_ci p q) e.participants
      in
      keeper_ok && outcome_ok && search_ok)
  in
  let filtered_total = List.length filtered in
  let episodes =
    let rec drop n = function
      | [] -> []
      | rest when n <= 0 -> rest
      | _ :: rest -> drop (n - 1) rest
    in
    if filtered_total <= limit then filtered else drop (filtered_total - limit) filtered
  in
  let known_keepers =
    let episode_keepers =
      all_episodes
      |> List.concat_map (fun (e : Institution_eio.episode) -> e.participants)
    in
    let memory_keepers = List.map fst all_memory_entries in
    episode_keepers @ memory_keepers |> List.sort_uniq String.compare
  in
  let known_memory_kinds =
    all_memory_entries
    |> List.map (fun (_, (row : Keeper_memory_policy.keeper_memory_line)) -> row.kind)
    |> List.sort_uniq String.compare
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "hebbian", hebbian
    ; ( "episodes"
      , `Assoc
          [ "total", `Int total
          ; "filtered", `Int filtered_total
          ; "shown", `Int (List.length episodes)
          ; "limit", `Int limit
          ; "items", `List (List.map Institution_eio.episode_to_json episodes)
          ] )
    ; ( "memory_entries"
      , `Assoc
          [ "total", `Int memory_total
          ; "filtered", `Int memory_filtered_total
          ; "shown", `Int (List.length memory_entries)
          ; "limit", `Int limit
          ; ( "items"
            , `List
                (List.map
                   (fun (keeper, row) -> memory_entry_to_json keeper row)
                   memory_entries) )
          ] )
    ; ( "filters"
      , `Assoc
          [ "keepers", `List (List.map (fun k -> `String k) known_keepers)
          ; "outcomes", `List [ `String "success"; `String "partial"; `String "failure" ]
          ; "memory_kinds", `List (List.map (fun k -> `String k) known_memory_kinds)
          ] )
    ]
;;
