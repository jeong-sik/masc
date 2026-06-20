(** Memory subsystem dashboard HTTP JSON helpers. *)

open Server_utils

let memory_subsystems_entry_cache_ttl_sec = 30.0

(* RFC-0149 §3.1: cache holds typed errors alongside successful rows so the
   dashboard JSON can surface per-keeper Read failure class instead of silently
   swallowing them. *)
let memory_subsystems_entry_cache
  : (string
     * float
     * (string * Keeper_memory_policy.keeper_memory_line) list
     * (string * string) list)
      option
      Atomic.t
  =
  Atomic.make None
;;

(** Single-flight mutex for refreshing the memory-subsystems cache. The cache
    itself is an [Atomic.t] so readers can check the TTL without contending for
    the lock; only a miss contends and one fiber performs the expensive IO. *)
let memory_subsystems_entry_cache_mu = Eio.Mutex.create ()
;;

let dashboard_memory_subsystems_include_entries request =
  bool_query_param request "include_memory_entries" ~default:false
  ||
  match query_param request "focus" |> Option.map String.trim with
  | Some "entries" -> true
  | _ -> false
;;

let load_memory_subsystems_entries ~(config : Workspace_utils.config) =
  (* NDT-OK: wall-clock read only gates a dashboard cache TTL. *)
  let now = Unix.gettimeofday () in
  let is_fresh = function
    | Some (base_path, cached_at, _rows, _errors) ->
      String.equal base_path config.base_path
      && now -. cached_at < memory_subsystems_entry_cache_ttl_sec
    | None -> false
  in
  match Atomic.get memory_subsystems_entry_cache with
  | Some (base_path, cached_at, rows, errors) as cached when is_fresh cached ->
    (rows, errors)
  | _ ->
    Eio.Mutex.use_rw ~protect:true memory_subsystems_entry_cache_mu
    @@ fun () ->
    (match Atomic.get memory_subsystems_entry_cache with
     | Some (base_path, cached_at, rows, errors) as cached when is_fresh cached ->
       (rows, errors)
     | _ ->
       let rows, errors =
         try
           Keeper_meta_store.keeper_names config
           |> List.fold_left
                (fun (rows_acc, errs_acc) keeper ->
                  match
                    Keeper_memory_recall.read_keeper_memory_summary_result
                      config
                      ~name:keeper
                      ~max_bytes:120000
                      ~max_lines:180
                      ~recent_limit:30
                  with
                  | Ok summary ->
                    let rows =
                      List.map
                        (fun (row : Keeper_memory_policy.keeper_memory_line) ->
                          keeper, row)
                        summary.recent_notes
                    in
                    List.rev_append rows rows_acc, errs_acc
                  | Error exn_class ->
                    let label =
                      Keeper_memory_recall_exn_class.to_label exn_class
                    in
                    rows_acc, (keeper, label) :: errs_acc)
                ([], [])
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _ -> [], []
       in
       let rows = List.rev rows in
       let errors = List.rev errors in
       Atomic.set memory_subsystems_entry_cache
         (Some (config.base_path, now, rows, errors));
       rows, errors)
;;

let load_user_model_facts ~(config : Workspace_utils.config) =
  let now = Time_compat.now () in
  let base_path = config.base_path in
  Keeper_memory_os_io.list_fact_store_keeper_ids_for_base_path ~base_path
  |> List.fold_left
       (fun (items_acc, errors_acc) keeper ->
         try
           let items =
             Keeper_memory_os_io.read_facts_tail_for_base_path
               ~base_path
               ~keeper_id:keeper
               ~n:Keeper_memory_os_io.fact_store_max
             |> List.filter Keeper_memory_os_types.fact_is_user_model
             |> List.filter (Keeper_memory_os_types.fact_is_current ~now)
             |> List.map (fun fact -> keeper, fact)
           in
           List.rev_append items items_acc, errors_acc
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> items_acc, (keeper, Printexc.to_string exn) :: errors_acc)
       ([], [])
  |> fun (items, errors) -> List.rev items, List.rev errors
;;

let dashboard_memory_subsystems_http_json
      ~(config : Workspace_utils.config)
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
  let user_model_item_to_json
        (keeper : string)
        (fact : Keeper_memory_os_types.fact)
    : Yojson.Safe.t
    =
    `Assoc
      [ "keeper", `String keeper
      ; "kind", `String (Keeper_memory_os_types.category_to_string fact.category)
      ; "claim", `String fact.claim
      ; ( "source_ref"
        , `String
            (Skill_candidate_projection.source_memory_fact_ref ~agent_name:keeper fact)
        )
      ; "source_trace_id", `String fact.source.trace_id
      ; "source_turn", `Int fact.source.turn
      ; "first_seen", `Float fact.first_seen
      ; ( "last_verified_at"
        , match fact.last_verified_at with
          | Some ts -> `Float ts
          | None -> `Null )
      ; ( "observed_by"
        , `List (List.map (fun keeper -> `String keeper) fact.observed_by) )
      ]
  in
  let all_memory_entries, memory_entry_errors =
    if include_memory_entries
    then load_memory_subsystems_entries ~config
    else [], []
  in
  let all_user_model_items, user_model_errors = load_user_model_facts ~config in
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
  let user_model_filtered =
    all_user_model_items
    |> List.filter (fun (keeper, (fact : Keeper_memory_os_types.fact)) ->
      let keeper_ok =
        match keeper_filter with
        | None -> true
        | Some k -> String.equal keeper k
      in
      let search_ok =
        match search with
        | None -> true
        | Some q ->
          contains_ci keeper q
          || contains_ci (Keeper_memory_os_types.category_to_string fact.category) q
          || contains_ci fact.claim q
      in
      keeper_ok && search_ok)
  in
  let user_model_items =
    user_model_filtered
    |> List.sort
         (fun
             (_, (a : Keeper_memory_os_types.fact))
            (_, (b : Keeper_memory_os_types.fact))
            ->
            Float.compare
              (Keeper_memory_os_types.reference_time b)
              (Keeper_memory_os_types.reference_time a))
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
    let user_model_keepers = List.map fst all_user_model_items in
    episode_keepers @ memory_keepers @ user_model_keepers
    |> List.sort_uniq String.compare
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
          ; ( "errors"
            , `List
                (List.map
                   (fun (keeper, error_class) ->
                     `Assoc
                       [ "keeper", `String keeper
                       ; "error_class", `String error_class
                       ])
                   memory_entry_errors) )
          ] )
    ; ( "user_model"
      , `Assoc
          [ "schema", `String "masc.user_model.memory_projection.v1"
          ; "source", `String "memory_os_facts"
          ; "total", `Int (List.length all_user_model_items)
          ; "filtered", `Int (List.length user_model_filtered)
          ; "shown", `Int (List.length user_model_items)
          ; "limit", `Int limit
          ; ( "items"
            , `List
                (List.map
                   (fun (keeper, fact) -> user_model_item_to_json keeper fact)
                   user_model_items) )
          ; ( "errors"
            , `List
                (List.map
                   (fun (keeper, error) ->
                     `Assoc [ "keeper", `String keeper; "error", `String error ])
                   user_model_errors) )
          ] )
    ; ( "filters"
      , `Assoc
          [ "keepers", `List (List.map (fun k -> `String k) known_keepers)
          ; "outcomes", `List [ `String "success"; `String "partial"; `String "failure" ]
          ; "memory_kinds", `List (List.map (fun k -> `String k) known_memory_kinds)
          ] )
    ]
;;
