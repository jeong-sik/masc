(** Dashboard_http_keeper_metrics — keeper metrics types, 24h bucket stats,
    gen window stats, history summary, and helper utilities.

    {b Note for code auditors}: this module does {b not} access a SQL
    database — the helpers here are pure parsers / aggregators over
    JSONL lines.  The actual feed lives in [Dashboard_http_keeper]:
    [Dated_jsonl.read_recent_lines] (current-day metrics window) with
    [Keeper_memory.read_file_tail_lines] as a tail fallback when the
    dated store is empty (see [dashboard_http_keeper.ml], e.g.
    around lines 591 / 1717 / 1839 / 1952 / 2054).  No relational
    store sits on this path, so proposals to "use a single SQL batch
    query" against keeper metrics are a stack mismatch.  Per-keeper
    sub-op fan-out (the N+1 shape on [snapshot_json]) is real and
    {b not yet fixed}; the proposed remediation is fiber-batched
    aggregation over those same JSONL reads rather than SQL —
    RFC-0029 candidate, tracked in #10710.  *)


let normalize_model_name s =
  let s = String.trim s in
  let s =
    match String.index_opt s ':' with
    | None -> s
    | Some i ->
        let prefix = String.sub s 0 i |> String.lowercase_ascii in
        if Provider_adapter.resolve_direct_canonical_name prefix <> None then
          String.sub s (i + 1) (String.length s - i - 1)
        else
          s
  in
  if String.ends_with ~suffix:":latest" s then
    String.sub s 0 (String.length s - String.length ":latest")
  else
    s

type keeper_gen_window_stats = {
  mutable turns: int;
  mutable input_tokens: int;
  mutable output_tokens: int;
  mutable total_tokens: int;
  mutable handoffs: int;
  mutable compactions: int;
  mutable memory_compactions: int;
  mutable memory_trimmed: int;
  mutable memory_checks: int;
  mutable memory_passed: int;
  mutable memory_notes: int;
  mutable first_ts: float;
  mutable last_ts: float;
  models: (string, int) Hashtbl.t;
  tools: (string, int) Hashtbl.t;
}

let create_keeper_gen_window_stats () : keeper_gen_window_stats =
  {
    turns = 0;
    input_tokens = 0;
    output_tokens = 0;
    total_tokens = 0;
    handoffs = 0;
    compactions = 0;
    memory_compactions = 0;
    memory_trimmed = 0;
    memory_checks = 0;
    memory_passed = 0;
    memory_notes = 0;
    first_ts = 0.0;
    last_ts = 0.0;
    models = Hashtbl.create 8;
    tools = Hashtbl.create 8;
  }

let count_table_incr (tbl : (string, int) Hashtbl.t) (key : string) : unit =
  let key = String.trim key in
  if key <> "" then
    let cur = Option.value ~default:0 (Hashtbl.find_opt tbl key) in
    Hashtbl.replace tbl key (cur + 1)

let utf8_safe_prefix_bytes (s : string) ~(max_bytes : int) : string =
  if max_bytes <= 0 then ""
  else
    let len = String.length s in
    if len <= max_bytes then s
    else
      let rec loop i last_good =
        if i >= len || i >= max_bytes then last_good
        else
          let dec = String.get_utf_8_uchar s i in
          let dlen = Uchar.utf_decode_length dec in
          if dlen <= 0 then last_good
          else
            let next = i + dlen in
            if next > max_bytes then last_good
            else loop next next
      in
      let cut = loop 0 0 in
      if cut <= 0 then ""
      else String.sub s 0 cut

let truncate_text ~(max_len : int) (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

(* ASCII case-insensitive substring containment, byte-wise.

   Empty needle returns [false] here (differs from the
   [contains_casefold] convention elsewhere — preserved). *)
let contains_ci (haystack : string) (needle : string) : bool =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then false
  else if nlen > hlen then false
  else
    let rec match_at i j =
      if j = nlen then true
      else if Char.lowercase_ascii (String.unsafe_get haystack (i + j))
            <> Char.lowercase_ascii (String.unsafe_get needle j)
      then false
      else match_at i (j + 1)
    in
    let last = hlen - nlen in
    let rec loop i =
      if i > last then false
      else if match_at i 0 then true
      else loop (i + 1)
    in
    loop 0

(* Static replacement patterns hoisted to module load.
   [proactive_preview_similarity_stats] funnels into
   [token_set_of_text] → [normalize_similarity_text], paying
   2 [Re.compile] per text × 2 texts per pair × ~7 pairs per window =
   ~28 DFA builds per similarity-stats call before this hoist. *)
let normalize_non_word_re =
  Re.Pcre.re {|[^0-9a-z가-힣]+|} |> Re.compile

let normalize_collapse_spaces_re =
  Re.Pcre.re {| +|} |> Re.compile

let normalize_similarity_text (s : string) : string =
  s
  |> String.lowercase_ascii
  |> Re.replace_string normalize_non_word_re ~by:" "
  |> Re.replace_string normalize_collapse_spaces_re ~by:" "
  |> String.trim

let token_set_of_text (s : string) : (string, unit) Hashtbl.t =
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let norm = normalize_similarity_text s in
  if norm <> "" then
    norm
    |> String.split_on_char ' '
    |> List.iter (fun tok ->
         let tok = String.trim tok in
         if tok <> "" then Hashtbl.replace tbl tok ());
  tbl

let jaccard_similarity_text (a : string) (b : string) : float =
  let sa = token_set_of_text a in
  let sb = token_set_of_text b in
  let na = Hashtbl.length sa in
  let nb = Hashtbl.length sb in
  if na = 0 || nb = 0 then 0.0
  else
    let inter =
      Hashtbl.fold
        (fun tok () acc -> if Hashtbl.mem sb tok then acc + 1 else acc)
        sa 0
    in
    let union = na + nb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let take_last (n : int) (xs : 'a list) : 'a list =
  let n = max 0 n in
  let len = List.length xs in
  let drop = max 0 (len - n) in
  let rec drop_n k ys =
    if k <= 0 then ys
    else
      match ys with
      | [] -> []
      | _ :: tl -> drop_n (k - 1) tl
  in
  drop_n drop xs

let proactive_preview_similarity_stats
    ?(window = 8)
    ?(warn_threshold = 0.90)
    (previews : string list) : int * int * float * float * bool =
  let previews =
    previews
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> take_last window
  in
  let sample_count = List.length previews in
  let rec pairwise acc = function
    | a :: (b :: _ as tl) ->
        let sim = jaccard_similarity_text a b in
        pairwise (sim :: acc) tl
    | _ -> List.rev acc
  in
  let sims = pairwise [] previews in
  let pair_count = List.length sims in
  let avg =
    if pair_count = 0 then 0.0
    else List.fold_left ( +. ) 0.0 sims /. float_of_int pair_count
  in
  let max_sim =
    if pair_count = 0 then 0.0
    else List.fold_left max 0.0 sims
  in
  let warn = pair_count >= 2 && max_sim >= warn_threshold in
  (sample_count, pair_count, avg, max_sim, warn)

type keeper_24h_bucket_stats = {
  mutable sample_points: int;
  mutable context_ratio_sum: float;
  mutable proactive_points: int;
  mutable proactive_fallback_count: int;
}

let create_keeper_24h_bucket_stats () : keeper_24h_bucket_stats =
  {
    sample_points = 0;
    context_ratio_sum = 0.0;
    proactive_points = 0;
    proactive_fallback_count = 0;
  }

let keeper_metrics_24h_json
    ~(metrics_lines : string list)
    ~(now_ts : float) : Yojson.Safe.t * Yojson.Safe.t =
  let window_sec = 24.0 *. 3600.0 in
  let start_ts = now_ts -. window_sec in
  let lines = metrics_lines in
  let buckets : (int, keeper_24h_bucket_stats) Hashtbl.t = Hashtbl.create 64 in
  let sample_points = ref 0 in
  let proactive_points = ref 0 in
  let proactive_fallback_count = ref 0 in
  List.iter
    (fun line ->
      try
        let j = Yojson.Safe.from_string line in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        if ts_unix >= start_ts && ts_unix <= (now_ts +. 60.0) then begin
          incr sample_points;
          let bucket_ts =
            int_of_float (floor (ts_unix /. 3600.0) *. 3600.0)
          in
          let b =
            match Hashtbl.find_opt buckets bucket_ts with
            | Some row -> row
            | None ->
                let row = create_keeper_24h_bucket_stats () in
                Hashtbl.replace buckets bucket_ts row;
                row
          in
          let context_ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
          b.sample_points <- b.sample_points + 1;
          b.context_ratio_sum <- b.context_ratio_sum +. context_ratio;
          let channel = Safe_ops.json_string ~default:"turn" "channel" j in
          if channel = "scheduled_autonomous" || channel = "proactive" then begin
            incr proactive_points;
            b.proactive_points <- b.proactive_points + 1;
            let proactive_obj = Yojson.Safe.Util.member "proactive" j in
            let fallback_applied =
              Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
            in
            if fallback_applied then begin
              incr proactive_fallback_count;
              b.proactive_fallback_count <- b.proactive_fallback_count + 1;
            end
          end
        end
      with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Server.info "keeper log parse: %s" (Printexc.to_string exn))
    lines;
  let rows =
    buckets
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ta, _) (tb, _) -> compare ta tb)
    |> List.map (fun (bucket_ts, b) ->
         let context_ratio_avg =
           if b.sample_points = 0 then 0.0
           else b.context_ratio_sum /. float_of_int b.sample_points
         in
         let proactive_fallback_rate =
           if b.proactive_points = 0 then 0.0
           else
             float_of_int b.proactive_fallback_count
             /. float_of_int b.proactive_points
         in
         `Assoc [
           ("bucket_ts_unix", `Int bucket_ts);
           ("sample_points", `Int b.sample_points);
           ("context_ratio_avg", `Float context_ratio_avg);
           ("proactive_points", `Int b.proactive_points);
           ("proactive_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_numerator", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_denominator", `Int b.proactive_points);
         ])
  in
  let bucket_count = List.length rows in
  let proactive_fallback_rate =
    if !proactive_points = 0 then 0.0
    else
      float_of_int !proactive_fallback_count
      /. float_of_int !proactive_points
  in
  let summary =
    `Assoc [
      ("window_hours", `Float 24.0);
      ("source_lines", `Int (List.length metrics_lines));
      ("sample_points", `Int !sample_points);
      ("bucket_count", `Int bucket_count);
      ("from_ts_unix", `Float start_ts);
      ("to_ts_unix", `Float now_ts);
      ("coverage_hours", `Float (float_of_int bucket_count));
      ("proactive_points", `Int !proactive_points);
      ("proactive_fallback_count", `Int !proactive_fallback_count);
      ("proactive_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_count", `Int !proactive_fallback_count);
      ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_numerator", `Int !proactive_fallback_count);
      ("proactive_template_fallback_denominator", `Int !proactive_points);
    ]
  in
  (`List rows, summary)

let keeper_history_summary_json
    ~(all_keeper_names : string list)
    ~(keeper_name : string)
    ~(history_path : string)
    ~(filter_fragments : bool)
  : Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int =
  let history_lines =
    Keeper_memory.read_file_tail_lines
      history_path
      ~max_bytes:120000
      ~max_lines:80
  in
  let mention_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let (conversation_rev, k2k_rev, raw_count, fragment_count, filtered_count) =
    List.fold_left (fun (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count) line ->
      try
        let j = Yojson.Safe.from_string line in
        let role = Safe_ops.json_string ~default:"" "role" j |> String.trim in
        let role_lc = String.lowercase_ascii role in
        let content = Safe_ops.json_string ~default:"" "content" j |> String.trim in
        let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
        let ts_unix =
          let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
          if ts0 > 0.0 then ts0 else Safe_ops.json_float ~default:0.0 "timestamp" j
        in
        if role = "" || content = ""
           || Keeper_types.is_internal_history_source source
           || Keeper_context_core.has_world_state_signature content
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
    |> Keeper_types.take 5
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
  |> Keeper_types.take limit
  |> List.map (fun (k, v) ->
       `Assoc [ (name_key, `String k); ("count", `Int v) ])

let top_count_name_and_count
    (tbl : (string, int) Hashtbl.t) : (string * int) option =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> function
  | (k, v) :: _ -> Some (k, v)
  | [] -> None

let get_agent_identity (name : string) =
  Dashboard_execution_helpers.get_agent_identity name
