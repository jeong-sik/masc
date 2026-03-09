(** Lodge Memory GC — Active Memory Management

    Implements three memory management strategies from research:
    1. Consolidation (Mem0): merge similar memories to reduce noise
    2. Active Pruning (AgeMem): delete stale, low-importance memories
    3. Access Tracking (Memoria): weight by access frequency

    Designed to run periodically (e.g. every 10 heartbeat ticks).
    Operates on the Memory_stream JSONL files.

    References:
    - AgeMem (arXiv:2601.01885): aging-based memory management
    - Mem0 (mem0.ai): memory consolidation patterns
    - LEGOMem (arXiv:2510.04851): modular memory architecture

    @since 2.60.0
*)

(** {1 Configuration} *)

(** Entries older than this (in days) with low importance get pruned *)
let stale_threshold_days = 30.0

(** Importance threshold: entries below this score are pruning candidates *)
let low_importance_threshold = 3

(** Minimum entries to keep per agent (never prune below this) *)
let min_entries_per_agent = 50

(** Similarity threshold for consolidation (Jaccard index) *)
let similarity_threshold = 0.6

(** {1 Utilities} *)

(** Simple word tokenizer: lowercase, split on whitespace/punctuation *)
let tokenize s =
  String.lowercase_ascii s
  |> String.to_seq
  |> Seq.map (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then c
    else ' ')
  |> String.of_seq
  |> String.split_on_char ' '
  |> List.filter (fun w -> String.length w > 2)

(** Jaccard similarity between two word sets *)
let jaccard_similarity a b =
  let set_a = List.sort_uniq String.compare (tokenize a) in
  let set_b = List.sort_uniq String.compare (tokenize b) in
  let intersection = List.filter (fun w -> List.mem w set_b) set_a in
  let union_size =
    List.length set_a + List.length set_b - List.length intersection
  in
  if union_size = 0 then 0.0
  else float_of_int (List.length intersection) /. float_of_int union_size

(** {1 Active Pruning (AgeMem pattern)}

    Score each memory by: importance * recency_decay.
    Prune entries below threshold, keeping at least [min_entries_per_agent]. *)

type prune_result = {
  agent_name : string;
  total_before : int;
  total_after : int;
  pruned : int;
}

let prune_stale ~agent_name : prune_result =
  let entries = Memory_stream.load_all_entries ~agent_name in
  let total_before = List.length entries in
  if total_before <= min_entries_per_agent then
    { agent_name; total_before; total_after = total_before; pruned = 0 }
  else begin
    let now = Time_compat.now () in
    let stale_cutoff = now -. (stale_threshold_days *. 86400.0) in
    (* Partition into keep and prune candidates *)
    let keep, candidates = List.partition (fun (e : Memory_stream.memory_entry) ->
      (* Always keep: recent entries OR high-importance entries *)
      e.timestamp >= stale_cutoff || e.importance >= low_importance_threshold + 2
    ) entries in
    (* From candidates, prune the lowest-scoring ones *)
    let to_keep_count = max min_entries_per_agent (List.length keep) in
    let additional_needed = max 0 (to_keep_count - List.length keep) in
    (* Score candidates: importance * age_decay *)
    let scored_candidates = List.map (fun (e : Memory_stream.memory_entry) ->
      let age_days = (now -. e.timestamp) /. 86400.0 in
      let decay = 1.0 /. (1.0 +. age_days /. 7.0) in
      let score = float_of_int e.importance *. decay in
      (score, e)
    ) candidates in
    let sorted = List.sort (fun (s1, _) (s2, _) -> Float.compare s2 s1) scored_candidates in
    let additional_keep = List.filteri (fun i _ -> i < additional_needed) sorted
      |> List.map snd in
    let final = keep @ additional_keep in
    let total_after = List.length final in
    (* Rewrite the stream file *)
    if total_after < total_before then
      Memory_stream.rewrite_entries ~agent_name final;
    { agent_name; total_before; total_after; pruned = total_before - total_after }
  end

(** {1 Consolidation (Mem0 pattern)}

    Find pairs of similar memories and merge them into one,
    keeping the higher importance and combining content. *)

type consolidation_result = {
  agent_name : string;
  pairs_merged : int;
  entries_before : int;
  entries_after : int;
}

let consolidate ~agent_name : consolidation_result =
  let entries = Memory_stream.load_all_entries ~agent_name in
  let entries_before = List.length entries in
  if entries_before < 10 then
    { agent_name; pairs_merged = 0; entries_before; entries_after = entries_before }
  else begin
    (* Build similarity graph: find pairs above threshold *)
    let arr = Array.of_list entries in
    let n = Array.length arr in
    let merged = Array.make n false in
    let pairs_merged = ref 0 in
    let result = ref [] in
    for i = 0 to n - 1 do
      if not merged.(i) then begin
        let best_j = ref (-1) in
        let best_sim = ref 0.0 in
        for j = i + 1 to n - 1 do
          if not merged.(j) then begin
            let sim = jaccard_similarity arr.(i).content arr.(j).content in
            if sim > !best_sim && sim >= similarity_threshold then begin
              best_j := j;
              best_sim := sim
            end
          end
        done;
        if !best_j >= 0 then begin
          (* Merge: keep the newer entry, combine content *)
          let a = arr.(i) in
          let b = arr.(!best_j) in
          let (newer, older) =
            if a.timestamp >= b.timestamp then (a, b) else (b, a)
          in
          let merged_content = Printf.sprintf "%s\n\n[Consolidated from: %s]"
            newer.content
            (if String.length older.content > 100
             then String.sub older.content 0 100 ^ "..."
             else older.content) in
          let merged_entry = { newer with
            content = merged_content;
            importance = max newer.importance older.importance;
          } in
          result := merged_entry :: !result;
          merged.(!best_j) <- true;
          incr pairs_merged
        end else
          result := arr.(i) :: !result
      end
    done;
    let final = List.rev !result in
    let entries_after = List.length final in
    if !pairs_merged > 0 then
      Memory_stream.rewrite_entries ~agent_name final;
    { agent_name; pairs_merged = !pairs_merged; entries_before; entries_after }
  end

(** {1 Combined GC run} *)

type gc_result = {
  prune_results : prune_result list;
  consolidation_results : consolidation_result list;
  total_pruned : int;
  total_merged : int;
}

(** Run GC for all agents with memory streams.
    Returns summary of pruning and consolidation. *)
let run_gc () : gc_result =
  let me = Env_config.me_root () in
  let memory_base = Printf.sprintf "%s/.masc/memory" me in
  if not (Sys.file_exists memory_base) then
    { prune_results = []; consolidation_results = [];
      total_pruned = 0; total_merged = 0 }
  else begin
    let agents = Sys.readdir memory_base |> Array.to_list
      |> List.filter (fun e ->
        let path = Filename.concat memory_base e in
        Sys.is_directory path)
    in
    (* Phase 1: Consolidate similar memories *)
    let consolidation_results = List.map (fun agent_name ->
      consolidate ~agent_name
    ) agents in
    (* Phase 2: Prune stale, low-importance memories *)
    let prune_results = List.map (fun agent_name ->
      prune_stale ~agent_name
    ) agents in
    let total_pruned = List.fold_left (fun acc r -> acc + r.pruned) 0 prune_results in
    let total_merged = List.fold_left (fun acc r -> acc + r.pairs_merged) 0 consolidation_results in
    { prune_results; consolidation_results; total_pruned; total_merged }
  end

(** Format GC result as human-readable string *)
let format_result (r : gc_result) : string =
  let prune_lines = List.filter_map (fun (p : prune_result) ->
    if p.pruned > 0 then
      Some (Printf.sprintf "  %s: %d → %d (pruned %d)" p.agent_name p.total_before p.total_after p.pruned)
    else None
  ) r.prune_results in
  let merge_lines = List.filter_map (fun (c : consolidation_result) ->
    if c.pairs_merged > 0 then
      Some (Printf.sprintf "  %s: %d → %d (merged %d pairs)" c.agent_name c.entries_before c.entries_after c.pairs_merged)
    else None
  ) r.consolidation_results in
  let sections = [] in
  let sections = if prune_lines <> [] then
    sections @ ["Pruned:"; String.concat "\n" prune_lines]
  else sections in
  let sections = if merge_lines <> [] then
    sections @ ["Consolidated:"; String.concat "\n" merge_lines]
  else sections in
  if sections = [] then
    Printf.sprintf "Memory GC: no changes (agents: %d)" (List.length r.prune_results)
  else
    Printf.sprintf "Memory GC: pruned=%d, merged=%d\n%s"
      r.total_pruned r.total_merged (String.concat "\n" sections)
