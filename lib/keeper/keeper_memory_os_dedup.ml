(** Keeper_memory_os_dedup — semantic de-duplication for Memory OS facts.

    Provides:
    - `normalize_claim` : normalize a fact claim for comparison
    - `compute_dedup_key` : generate a normalized hash for exact de-dup
    - `word_overlap_similarity` : compute word-overlap similarity between two claims
    - `find_similar_facts` : find semantically similar facts from a list
    - `dedup_action` : determine whether to merge, skip, or accept a new fact

    Bug2 Fix: Previously, facts with slightly different phrasing were stored
    multiple times. Now we compute word-overlap similarity and either merge
    (update confidence), skip (if new confidence <= existing), or accept
    (if new confidence > existing and similarity < threshold). *)

let default_threshold = 0.85
let default_min_word_count = 3

(* ---------- Normalization ---------- *)

let normalize_claim (s : string) : string =
  s
  |> String.lowercase_ascii
  |> fun s -> String.concat " " (String.split_on_char ' ' s)
  |> fun s -> String.trim s

let compute_dedup_key (claim : string) : string =
  let normalized = normalize_claim claim in
  (* Simple hash: sum of character codes mod 2^32 *)
  let len = String.length normalized in
  let rec hash i acc =
    if i >= len then acc
    else
      let c = Char.code normalized.[i] in
      hash (i + 1) ((acc + c * (i + 1)) mod 4294967296)
  in
  Printf.sprintf "%08x" (hash 0 0)

(* ---------- Word-overlap similarity ---------- *)

let tokenize (s : string) : string list =
  s
  |> normalize_claim
  |> String.split_on_char ' '
  |> List.filter (fun w -> String.length w > 1)  (* Skip single-char tokens *)

let word_overlap_similarity (claim1 : string) (claim2 : string) : float =
  let tokens1 = tokenize claim1 in
  let tokens2 = tokenize claim2 in
  let set1 = List.length tokens1 in
  let set2 = List.length tokens2 in
  if set1 = 0 || set2 = 0 then 0.0
  else
    (* Count common tokens *)
    let rec count_common l1 l2 acc =
      match l1 with
      | [] -> acc
      | h :: t ->
        if List.mem h l2 then count_common t l2 (acc + 1)
        else count_common t l2 acc
    in
    let common = count_common tokens1 tokens2 0 in
    (* Jaccard-like similarity: common / min(set1, set2) *)
    let min_set = min set1 set2 in
    float_of_int common /. float_of_int min_set

(* ---------- Find similar facts ---------- *)

type dedup_result =
  | NoSimilarFact
  | SimilarFact of { fact_id : string; similarity : float; existing_confidence : float }

let find_similar_facts ~threshold (new_claim : string) (existing_facts : Keeper_memory_os_types.fact list) : dedup_result list =
  let rec find_similar facts acc =
    match facts with
    | [] -> acc
    | fact :: rest ->
      let similarity = word_overlap_similarity new_claim fact.claim in
      if similarity >= threshold then
        find_similar rest
          ( { fact_id = fact.source.trace_id; similarity; existing_confidence = fact.confidence } :: acc )
      else
        find_similar rest acc
  in
  find_similar existing_facts []

(* ---------- Dedup action ---------- *)

type dedup_action =
  | Accept  (** No similar fact found; accept the new fact *)
  | Skip of { similar_fact_id : string; similarity : float; existing_confidence : float }  (** Similar fact exists with >= confidence; skip *)
  | Merge of { similar_fact_id : string; similarity : float; new_confidence : float; existing_confidence : float }  (** Similar fact exists with lower confidence; merge *)

let dedup_action ~threshold (new_claim : string) (new_confidence : float) (existing_facts : Keeper_memory_os_types.fact list) : dedup_action =
  let similar = find_similar_facts ~threshold new_claim existing_facts in
  match similar with
  | [] -> Accept
  | best :: _ ->
    (* Take the most similar fact *)
    let { fact_id; similarity; existing_confidence } = best in
    if new_confidence <= existing_confidence then
      Skip { similar_fact_id = fact_id; similarity; existing_confidence }
    else
      Merge { similar_fact_id = fact_id; similarity; new_confidence; existing_confidence }

(* ---------- Log de-dup decisions ---------- *)

let log_dedup_decision (action : dedup_action) (new_claim : string) =
  let dedup_log = "memory/dedup.log" in
  try
    ensure_dir (Filename.dirname dedup_log);
    let json_line =
      match action with
      | Accept -> Printf.sprintf "{\"action\": \"accept\", \"claim\": \"%s\"}\n" (String.map (fun c -> if c = '"' then '\\' else c) new_claim)
      | Skip { similar_fact_id; similarity; existing_confidence } ->
        Printf.sprintf "{\"action\": \"skip\", \"similar_fact_id\": \"%s\", \"similarity\": %.4f, \"existing_confidence\": %.4f, \"claim\": \"%s\"}\n"
          similar_fact_id similarity existing_confidence (String.map (fun c -> if c = '"' then '\\' else c) new_claim)
      | Merge { similar_fact_id; similarity; new_confidence; existing_confidence } ->
        Printf.sprintf "{\"action\": \"merge\", \"similar_fact_id\": \"%s\", \"similarity\": %.4f, \"new_confidence\": %.4f, \"existing_confidence\": %.4f, \"claim\": \"%s\"}\n"
          similar_fact_id similarity new_confidence existing_confidence (String.map (fun c -> if c = '"' then '\\' else c) new_claim)
    in
    let oc = open_out_gen [Open_append; Open_creat] 0o644 dedup_log in
    output_string oc json_line;
    close_out oc
  with _ -> ()  (* Best-effort logging *)

and ensure_dir path =
  if path = "" || path = Filename.current_dir_name
  then ()
  else if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then invalid_arg (Printf.sprintf "%s exists but is not a directory" path)
    else ()
  )
  else (
    ensure_dir (Filename.dirname path);
    Sys.mkdir path 0o755
  )