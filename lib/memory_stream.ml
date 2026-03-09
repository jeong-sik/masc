(** Memory Stream — Scored retrieval memory for Generative Agents.

    Stanford Generative Agents (Park et al. 2023) scoring formula:
    score = α·recency + β·importance + γ·relevance

    Phase 1: JSONL file persistence, keyword overlap for relevance.
    Phase 2+: external semantic store integration (pgvector-based).

    Storage: .masc/memory/{agent_name}/stream.jsonl
    Rotation: archive after 1000 entries.

    @since 4.0.0 *)

[@@@warning "-32"]

open Printf

(* ---------- Types ---------- *)

type memory_type =
  | Observation of string
  | Action of string
  | Reflection of string
  | Plan of string

type memory_entry = {
  id: string;
  agent_name: string;
  content: string;
  timestamp: float;
  importance: int;
  entry_type: memory_type;
}

type scoring_weights = {
  alpha: float;
  beta: float;
  gamma: float;
}

let default_weights = { alpha = 1.0; beta = 1.0; gamma = 1.0 }

let max_entries = 1000

(* ---------- Paths ---------- *)

let me_root () =
  Env_config.me_root ()

let memory_dir ~agent_name =
  sprintf "%s/.masc/memory/%s" (me_root ()) agent_name

let stream_path ~agent_name =
  sprintf "%s/stream.jsonl" (memory_dir ~agent_name)

let archive_path ~agent_name ~timestamp =
  sprintf "%s/archive_%d.jsonl" (memory_dir ~agent_name) (int_of_float timestamp)

(* ---------- Ensure directory ---------- *)

let ensure_dir path =
  let rec mkdir_p dir =
    if not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  mkdir_p path

(* ---------- JSON serialization ---------- *)

let memory_type_to_json = function
  | Observation s -> `Assoc [("type", `String "observation"); ("detail", `String s)]
  | Action s -> `Assoc [("type", `String "action"); ("detail", `String s)]
  | Reflection s -> `Assoc [("type", `String "reflection"); ("detail", `String s)]
  | Plan s -> `Assoc [("type", `String "plan"); ("detail", `String s)]

let memory_type_of_json json =
  let open Yojson.Safe.Util in
  let typ = json |> member "type" |> to_string in
  let detail = json |> member "detail" |> to_string in
  match typ with
  | "observation" -> Observation detail
  | "action" -> Action detail
  | "reflection" -> Reflection detail
  | "plan" -> Plan detail
  | _ -> Observation detail

let entry_to_json (e : memory_entry) : Yojson.Safe.t =
  `Assoc [
    ("id", `String e.id);
    ("agent_name", `String e.agent_name);
    ("content", `String e.content);
    ("timestamp", `Float e.timestamp);
    ("importance", `Int e.importance);
    ("entry_type", memory_type_to_json e.entry_type);
  ]

let entry_of_json (json : Yojson.Safe.t) : memory_entry option =
  try
    let open Yojson.Safe.Util in
    Some {
      id = json |> member "id" |> to_string;
      agent_name = json |> member "agent_name" |> to_string;
      content = json |> member "content" |> to_string;
      timestamp = json |> member "timestamp" |> to_float;
      importance = json |> member "importance" |> to_int;
      entry_type = json |> member "entry_type" |> memory_type_of_json;
    }
  with _ -> None

(* ---------- File I/O ---------- *)

let load_all_entries ~agent_name : memory_entry list =
  let path = stream_path ~agent_name in
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let entries = ref [] in
      (try
        while true do
          let line = input_line ic in
          if String.length line > 0 then
            match Yojson.Safe.from_string line |> entry_of_json with
            | Some e -> entries := e :: !entries
            | None -> ()
        done
      with End_of_file -> ());
      List.rev !entries)
  end

let append_entry ~agent_name (entry : memory_entry) =
  let dir = memory_dir ~agent_name in
  ensure_dir dir;
  let path = stream_path ~agent_name in
  let oc = open_out_gen [Open_creat; Open_append; Open_text] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    let json_str = Yojson.Safe.to_string (entry_to_json entry) in
    output_string oc json_str;
    output_char oc '\n')

let count_entries ~agent_name : int =
  let path = stream_path ~agent_name in
  if not (Sys.file_exists path) then 0
  else begin
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let n = ref 0 in
      (try while true do ignore (input_line ic); incr n done
       with End_of_file -> ());
      !n)
  end

(** Rewrite all entries atomically (used by Lodge_memory_gc). *)
let rewrite_entries ~agent_name (entries : memory_entry list) =
  let dir = memory_dir ~agent_name in
  ensure_dir dir;
  let path = stream_path ~agent_name in
  let tmp_path = path ^ ".tmp" in
  (* Write to temp file first, then atomic rename *)
  let oc = open_out tmp_path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    List.iter (fun entry ->
      let json_str = Yojson.Safe.to_string (entry_to_json entry) in
      output_string oc json_str;
      output_char oc '\n'
    ) entries);
  Sys.rename tmp_path path

(* ---------- Scoring ---------- *)

(** Recency: exponential decay.  0.995^hours_since *)
let recency_score ~now (entry : memory_entry) =
  let hours_since = (now -. entry.timestamp) /. 3600.0 in
  Float.pow 0.995 hours_since

(** Importance: normalized to 0.0-1.0 *)
let importance_score (entry : memory_entry) =
  Float.of_int entry.importance /. 10.0

(** Relevance: keyword overlap ratio (Phase 1 approximation).
    Splits both query and content into lowercase word sets,
    computes |intersection| / |query_words|. *)
let keyword_relevance ~query (entry : memory_entry) =
  let tokenize s =
    s
    |> String.lowercase_ascii
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w > 1)
    |> List.sort_uniq String.compare
  in
  let query_words = tokenize query in
  let content_words = tokenize entry.content in
  if List.length query_words = 0 then 0.5  (* neutral if no query *)
  else begin
    let matches = List.filter (fun qw ->
      List.exists (fun cw -> String.equal qw cw) content_words
    ) query_words in
    Float.of_int (List.length matches) /. Float.of_int (List.length query_words)
  end

let score_entry ?(weights = default_weights) ~now ~query (entry : memory_entry) =
  let r = recency_score ~now entry in
  let i = importance_score entry in
  let rel = keyword_relevance ~query entry in
  weights.alpha *. r +. weights.beta *. i +. weights.gamma *. rel

(* ---------- Public API ---------- *)

let add_memory ~agent_name ~content ~importance entry_type =
  let importance = max 1 (min 10 importance) in
  let id = sprintf "%s-%d-%06d"
    agent_name
    (int_of_float (Time_compat.now ()))
    (Random.int 999999)
  in
  let entry = {
    id;
    agent_name;
    content;
    timestamp = Time_compat.now ();
    importance;
    entry_type;
  } in
  append_entry ~agent_name entry

let retrieve ~agent_name ~query ~limit =
  let entries = load_all_entries ~agent_name in
  let now = Time_compat.now () in
  let scored = List.map (fun e ->
    (score_entry ~now ~query e, e)
  ) entries in
  let sorted = List.sort (fun (s1, _) (s2, _) -> Float.compare s2 s1) scored in
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | (_, e) :: rest -> take (n - 1) (e :: acc) rest
  in
  take limit [] sorted

let recent ~agent_name ~hours =
  let entries = load_all_entries ~agent_name in
  let cutoff = Time_compat.now () -. (hours *. 3600.0) in
  List.filter (fun e -> e.timestamp >= cutoff) entries

let importance_sum_since ~agent_name ~since =
  let entries = load_all_entries ~agent_name in
  List.fold_left (fun acc e ->
    if e.timestamp >= since then acc + e.importance
    else acc
  ) 0 entries

(* ---------- Formatting ---------- *)

let memory_type_label = function
  | Observation _ -> "관찰"
  | Action _ -> "행동"
  | Reflection _ -> "성찰"
  | Plan _ -> "계획"

let format_memories entries =
  if List.length entries = 0 then "(기억 없음)"
  else
    entries
    |> List.map (fun e ->
      let age_h = (Time_compat.now () -. e.timestamp) /. 3600.0 in
      let age_str =
        if age_h < 1.0 then sprintf "%.0f분 전" (age_h *. 60.0)
        else if age_h < 24.0 then sprintf "%.1f시간 전" age_h
        else sprintf "%.0f일 전" (age_h /. 24.0)
      in
      sprintf "• [%s/%d] %s (%s)"
        (memory_type_label e.entry_type)
        e.importance
        e.content
        age_str)
    |> String.concat "\n"

(* ---------- Maintenance ---------- *)

let rotate_if_needed ~agent_name =
  let n = count_entries ~agent_name in
  if n > max_entries then begin
    let entries = load_all_entries ~agent_name in
    (* Keep the most recent max_entries/2, archive the rest *)
    let keep = max_entries / 2 in
    let total = List.length entries in
    let to_archive = total - keep in
    let archived, kept =
      let rec split i acc = function
        | [] -> (List.rev acc, [])
        | rest when i >= to_archive -> (List.rev acc, rest)
        | x :: xs -> split (i + 1) (x :: acc) xs
      in
      split 0 [] entries
    in
    (* Write archive *)
    let arch_path = archive_path ~agent_name ~timestamp:(Time_compat.now ()) in
    let oc = open_out arch_path in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      List.iter (fun e ->
        output_string oc (Yojson.Safe.to_string (entry_to_json e));
        output_char oc '\n'
      ) archived);
    (* Rewrite stream with only kept entries *)
    let path = stream_path ~agent_name in
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      List.iter (fun e ->
        output_string oc (Yojson.Safe.to_string (entry_to_json e));
        output_char oc '\n'
      ) kept);
    eprintf "[memory_stream] Rotated %s: archived %d, kept %d\n%!"
      agent_name (List.length archived) (List.length kept)
  end
