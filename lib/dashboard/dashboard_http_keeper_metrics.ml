(** Dashboard_http_keeper_metrics — keeper metrics window counters,
    history summary, and helper utilities.

    {b Note for code auditors}: this module does {b not} access a SQL
    database — the helpers here are pure parsers / aggregators over
    JSONL lines.  The actual feed lives in [Dashboard_http_keeper]:
    [Dated_jsonl.read_recent_lines] (current-day metrics window) with
    [Dashboard_http_helpers.keeper_tail_lines_or_empty] as an explicit tail degradation path when the
    dated store is empty (see [dashboard_http_keeper.ml], e.g.
    around lines 591 / 1717 / 1839 / 1952 / 2054).  No relational
    store sits on this path, so proposals to "use a single SQL batch
    query" against keeper metrics are a stack mismatch.  Per-keeper
    sub-op fan-out (the N+1 shape on [snapshot_json]) is real and
    {b not yet fixed}; the proposed remediation is fiber-batched
    aggregation over those same JSONL reads rather than SQL —
    RFC-0029 candidate, tracked in #10710.  *)


let count_table_incr (tbl : (string, int) Hashtbl.t) (key : string) : unit =
  let key = String.trim key in
  if key <> "" then
    let cur = Option.value ~default:0 (Hashtbl.find_opt tbl key) in
    Hashtbl.replace tbl key (cur + 1)

let truncate_text ~(max_len : int) (s : string) : string =
  let s = String.trim s in
  match String_util.utf8_safe ~max_bytes:max_len ~suffix:"..." s with
  | String_util.Untouched _ -> s
  | String_util.Truncated { prefix; suffix; _ } -> prefix ^ suffix

let contains_ci = String_util.contains_substring_ci

let keeper_history_summary_json
    ~(all_keeper_names : string list)
    ~(keeper_name : string)
    ~(history_path : string)
    ~(filter_fragments : bool)
  : Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int =
  let history_lines =
    Dashboard_http_helpers.keeper_tail_lines_or_empty ~site:"dashboard_keeper_history_summary"
      history_path ~max_bytes:120000 ~max_lines:80
  in
  let mention_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let (conversation_rev, k2k_rev, raw_count, fragment_count, filtered_count) =
    List.fold_left (fun (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count) line ->
      try
        let j = Yojson.Safe.from_string line in
        let role = Safe_ops.json_string ~default:"" "role" j |> String.trim in
        let role_lc = String.lowercase_ascii role in
        (* Message text lives in typed [content_blocks], not a flat [content]
           string. Reading flat [content] decoded "" for every row, so the
           keeper conversation / k2k summary was empty. Same SSOT extractor as
           the trace view. *)
        let content =
          Keeper_context_core.text_of_history_jsonl_json j |> String.trim
        in
        let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        if role = "" || content = ""
           || Keeper_types_support.is_internal_history_source source
        then
          (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
        else
          let is_fragment =
            role_lc = "assistant"
            && Keeper_execution.looks_fragmentary_history_text content
          in
          let should_filter = filter_fragments && is_fragment in
          let mentions =
            all_keeper_names
            |> List.filter (fun candidate ->
                 candidate <> keeper_name && contains_ci content candidate)
          in
          let (conv_acc, k2k_acc) =
            if should_filter then
              (conv_acc, k2k_acc)
            else
              let () = List.iter (count_table_incr mention_counts) mentions in
              let preview = truncate_text ~max_len:280 content in
              let is_k2k = role_lc = "user" && mentions <> [] in
              let conversation_item =
                `Assoc [
                  ("role", `String role);
                  ("ts_unix", `Float ts_unix);
                  ("content", `String content);
                  ("preview", `String preview);
                  ("mentions", `List (List.map (fun s -> `String s) mentions));
                  ("k2k", `Bool is_k2k);
                  ("is_fragment", `Bool is_fragment);
                ]
              in
              let k2k_acc =
                match mentions with
                | mentioned_keeper :: _ when is_k2k ->
                    (`Assoc [
                       ("keeper", `String keeper_name);
                       ("mentioned", `String mentioned_keeper);
                       ("role", `String role);
                       ("ts_unix", `Float ts_unix);
                       ("preview", `String preview);
                     ]) :: k2k_acc
                | _ -> k2k_acc
              in
              (conversation_item :: conv_acc, k2k_acc)
          in
          ( conv_acc,
            k2k_acc,
            raw_count + 1,
            fragment_count + (if is_fragment then 1 else 0),
            filtered_count + (if should_filter then 1 else 0) )
      with
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Not_found ->
        (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
    ) ([], [], 0, 0, 0) history_lines
  in
  let conversation = `List (List.rev conversation_rev) in
  let k2k_recent = `List (List.rev k2k_rev) in
  let k2k_mentions =
    mention_counts
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c else String.compare ka kb)
    |> Keeper_types_profile.take 5
    |> List.map (fun (k, v) ->
         `Assoc [("keeper", `String k); ("count", `Int v)])
    |> fun xs -> `List xs
  in
  (conversation, k2k_recent, k2k_mentions, raw_count, fragment_count, filtered_count)

let top_counts_json
    ?(limit = 5)
    ~(name_key : string)
    (tbl : (string, int) Hashtbl.t) : Yojson.Safe.t list =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> Keeper_types_profile.take limit
  |> List.map (fun (k, v) ->
       `Assoc [ (name_key, `String k); ("count", `Int v) ])

