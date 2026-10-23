(** Keeper metrics counters and history summaries.

    [keeper_history_summary_json] reads a bounded JSONL tail; the other helpers
    aggregate caller-provided counters. Conversation visibility follows recorded
    source provenance. *)

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

module Mention_counts = Map.Make (String)

let keeper_history_summary_json
    ~(all_keeper_names : string list)
    ~(keeper_name : string)
    ~(history_path : string)
  : Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int =
  let history_lines =
    Dashboard_http_helpers.keeper_tail_lines_or_empty ~site:"dashboard_keeper_history_summary"
      history_path ~max_bytes:120000 ~max_lines:80
  in
  let keeper_targets =
    all_keeper_names
    |> List.filter (fun name -> name <> keeper_name)
    |> List.filter_map (fun name ->
         Keeper_identity.Keeper_id.of_string name
         |> Option.map (fun id -> name, id))
  in
  let (conversation_rev, addressed_rev, mention_counts, raw_count) =
    List.fold_left (fun (conv_acc, addressed_acc, mention_counts, raw_count) line ->
      try
        let j = Yojson.Safe.from_string line in
        let role = Safe_ops.json_string ~default:"" "role" j |> String.trim in
        let role_lc = String.lowercase_ascii role in
        (* Message text lives in typed [content_blocks], not a flat [content]
           string. Reading flat [content] decoded "" for every row, so the
           keeper conversation / mention summary was empty. Same SSOT extractor as
           the trace view. *)
        let content =
          Keeper_context_core.text_of_history_jsonl_json j |> String.trim
        in
        let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        if role = "" || content = ""
           || Keeper_types_support.is_internal_history_source source
        then
          (conv_acc, addressed_acc, mention_counts, raw_count)
        else
          let mentioned_ids = Keeper_lane_mentions.mention_ids_of_content content in
          let mentions =
            keeper_targets
            |> List.filter_map (fun (name, id) ->
                 if List.exists (Keeper_identity.Keeper_id.equal id) mentioned_ids
                 then Some name else None)
          in
          let mention_counts =
            List.fold_left (fun counts name ->
              Mention_counts.update name
                (fun previous -> Some (1 + Option.value ~default:0 previous)) counts)
              mention_counts mentions
          in
          let (conv_acc, addressed_acc) =
            let preview = truncate_text ~max_len:280 content in
            let addressed_user_message = role_lc = "user" && mentions <> [] in
            let conversation_item =
              `Assoc [
                ("role", `String role);
                ("ts_unix", `Float ts_unix);
                ("content", `String content);
                ("preview", `String preview);
                ("mentions", `List (List.map (fun s -> `String s) mentions));
                ("addressed_user_message", `Bool addressed_user_message);
              ]
            in
            let addressed_acc =
              match mentions with
              | mentioned_keeper :: _ when addressed_user_message ->
                  (`Assoc [
                     ("keeper", `String keeper_name);
                     ("mentioned", `String mentioned_keeper);
                     ("role", `String role);
                     ("ts_unix", `Float ts_unix);
                     ("preview", `String preview);
                   ]) :: addressed_acc
              | _ -> addressed_acc
            in
            (conversation_item :: conv_acc, addressed_acc)
          in
          (conv_acc, addressed_acc, mention_counts, raw_count + 1)
      with
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Not_found ->
        (conv_acc, addressed_acc, mention_counts, raw_count)
    ) ([], [], Mention_counts.empty, 0) history_lines
  in
  let conversation = `List (List.rev conversation_rev) in
  let recent_addressed_messages = `List (List.rev addressed_rev) in
  let keeper_mention_counts =
    mention_counts
    |> Mention_counts.bindings
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c else String.compare ka kb)
    |> Keeper_types_profile.take 5
    |> List.map (fun (k, v) ->
         `Assoc [("keeper", `String k); ("count", `Int v)])
    |> fun xs -> `List xs
  in
  (conversation, recent_addressed_messages, keeper_mention_counts, raw_count)

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

