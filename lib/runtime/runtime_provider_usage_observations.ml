open Runtime_provider_usage_types

let kind_rank = function
  | Five_hour -> 0
  | Seven_day -> 1
  | Duration_minutes _ -> 2
  | Provider_label _ -> 3
;;

let compare_kind left right =
  match left, right with
  | Duration_minutes a, Duration_minutes b -> Positive_minutes.compare a b
  | Provider_label a, Provider_label b -> String.compare a b
  | (Five_hour | Seven_day | Duration_minutes _ | Provider_label _), _ ->
    Int.compare (kind_rank left) (kind_rank right)
;;

module Window_key = struct
  type t = string option * window_kind

  let compare (left_id, left_kind) (right_id, right_kind) =
    match Option.compare String.compare left_id right_id with
    | 0 -> compare_kind left_kind right_kind
    | order -> order
  ;;
end

module Window_map = Map.Make (Window_key)
module Source_map = Map.Make (struct
    type t = source
    let source_rank = function
      | Claude_code_rate_limit_event -> 0
      | Codex_account_rate_limits_updated -> 1
      | Codex_account_rate_limits_read -> 2
      | Openrouter_key_read -> 3
      | Openrouter_credits_read -> 4
      | Zai_quota_limit_read -> 5
      | Kimi_coding_usages_read -> 6
      | Ollama_balance_read -> 7
      | Antigravity_usage_read -> 8
      | Muse_subscription_usage -> 9
    let compare a b = Int.compare (source_rank a) (source_rank b)
  end)

type t =
  { windows : recorded Window_map.t
  ; snapshots : float Source_map.t
  }

let empty = { windows = Window_map.empty; snapshots = Source_map.empty }

let report_shape = function
  | Openrouter_key_read | Openrouter_credits_read | Zai_quota_limit_read | Kimi_coding_usages_read
  | Ollama_balance_read | Antigravity_usage_read
  | Muse_subscription_usage -> Complete_snapshot
  | Claude_code_rate_limit_event | Codex_account_rate_limits_updated
  | Codex_account_rate_limits_read -> Sparse_update
;;

let key (window : window) = window.limit_id, window.kind

let is_retraction (window : window) =
  match window.utilization with
  | Credit_retracted -> true
  | Fraction _ | Percent _ | Usd _ | Credit_balance _ | Credit_unlimited -> false
;;

let is_codex_source = function
  | Codex_account_rate_limits_updated | Codex_account_rate_limits_read -> true
  | Claude_code_rate_limit_event | Openrouter_key_read | Openrouter_credits_read
  | Zai_quota_limit_read | Kimi_coding_usages_read | Ollama_balance_read
  | Antigravity_usage_read | Muse_subscription_usage -> false
;;

let same_retraction_scope source held_source =
  source = held_source || (is_codex_source source && is_codex_source held_source)
;;

let apply_report ~observed_at (report : report) observations =
  let shape = report_shape report.source in
  match shape, report.windows with
  | Sparse_update, [] -> observations, None
  | (Complete_snapshot | Sparse_update), reported_windows ->
    (match Source_map.find_opt report.source observations.snapshots with
     | Some at when at >= observed_at -> observations, None
     | Some _ | None ->
       let observations =
         match shape with
         | Sparse_update ->
           let retractions = List.filter is_retraction reported_windows in
           let windows =
             Window_map.filter
               (fun held_key (held : recorded) ->
                 not
                   (same_retraction_scope report.source held.source
                    && held.observed_at < observed_at
                    && List.exists
                         (fun window -> Window_key.compare held_key (key window) = 0)
                         retractions))
               observations.windows
           in
           let snapshots =
             if retractions = []
             then observations.snapshots
             else Source_map.add report.source observed_at observations.snapshots
           in
           { windows; snapshots }
         | Complete_snapshot ->
           let windows =
             Window_map.filter
               (fun held_key (held : recorded) ->
                 not
                   (held.source = report.source
                    && held.observed_at < observed_at
                    && not
                         (List.exists
                            (fun window -> Window_key.compare held_key (key window) = 0)
                            reported_windows)))
               observations.windows
           in
           { windows
           ; snapshots = Source_map.add report.source observed_at observations.snapshots
           }
       in
       (* Fold in wire order so a duplicate observes the first occurrence's
          timestamp and is refused like any other equal-time update. *)
       let windows, accepted_rev =
         List.fold_left
           (fun (windows, accepted) window ->
             let key = key window in
             match Window_map.find_opt key windows with
             | Some held when Float.compare held.observed_at observed_at >= 0 ->
               windows, accepted
             | Some _ | None ->
               ( Window_map.add key { window; source = report.source; observed_at } windows
               , window :: accepted ))
           (observations.windows, [])
           reported_windows
       in
       let accepted =
         match shape, List.rev accepted_rev with
         | Sparse_update, [] -> None
         | (Complete_snapshot | Sparse_update), windows -> Some { report with windows }
       in
       { observations with windows }, accepted)
;;

let recorded_windows observations =
  Window_map.bindings observations.windows
  |> List.filter_map (fun (_, (held : recorded)) ->
       if is_retraction held.window then None else Some held)
;;
let state observations =
  match recorded_windows observations with
  | first :: rest -> Reported (first, rest)
  | [] ->
    let latest =
      Source_map.fold
        (fun source observed_at latest ->
          match latest with
          | Some (_, at) when at >= observed_at -> latest
          | Some _ | None -> Some (source, observed_at))
        observations.snapshots
        None
    in
    (match latest with
     | None -> Not_reported_since_start
     | Some (source, observed_at) -> Reported_no_windows { source; observed_at })
;;
