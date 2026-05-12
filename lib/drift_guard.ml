module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(** Drift Guard - truthful handoff integrity verification.

    Public tool surfaces should use this module directly so the product exposes
    a single contract for handoff verification.
*)

type weights = {
  jaccard : float;
  cosine : float;
}

type drift_type =
  | Semantic
  | Factual
  | Structural
  | None

type verification_summary = {
  similarity : float;
  jaccard : float;
  cosine : float;
  threshold : float;
}

type drift_details = {
  similarity : float;
  jaccard : float;
  cosine : float;
  threshold : float;
  drift_type : drift_type;
}

type verification_result =
  | Verified of verification_summary
  | Drift_detected of drift_details

let drift_type_to_string = function
  | Semantic -> "semantic"
  | Factual -> "factual"
  | Structural -> "structural"
  | None -> "none"

let drift_type_of_string = function
  | "semantic" -> Semantic
  | "factual" -> Factual
  | "structural" -> Structural
  | _ -> None

let weights () =
  let configured = Level2_config.Drift_guard.weights () in
  { jaccard = configured.jaccard; cosine = configured.cosine }

let default_threshold () = Level2_config.Drift_guard.default_threshold ()

(** {1 Drift Classification Thresholds}

    Heuristic thresholds for determining drift type in handoff verification.
    - Factual drift: low token coverage or large size difference indicates
      content was replaced rather than edited.
    - Structural drift: cosine-jaccard divergence indicates word order/phrasing
      changed while vocabulary stayed similar.
    - Semantic drift: default when neither structural nor factual patterns match.

    These values are initial estimates and still await empirical
    calibration against a labelled drift corpus, but are now
    governable via Runtime_params so operators can tune without a
    rebuild. *)
let factual_coverage_floor () =
  Runtime_params.get Governance_registry.drift_factual_coverage_floor
let factual_size_ratio_floor () =
  Runtime_params.get Governance_registry.drift_factual_size_ratio_floor
let structural_divergence_threshold () =
  Runtime_params.get Governance_registry.drift_structural_divergence_threshold

(* Whitespace splitter for [tokenize] — pattern is a static character
   class, hoist out of the per-call hot path. *)
let whitespace_split_re = Re.Pcre.re "[ \t\r\n]+" |> Re.compile

let tokenize (s : string) : string list =
  let trimmed = String.trim s in
  if trimmed = "" then []
  else
    let tokens = Re.split whitespace_split_re trimmed in
    let trim_punct token =
      let is_punct = function
        | '.'
        | ','
        | ';'
        | ':'
        | '!'
        | '?'
        | '('
        | ')'
        | '['
        | ']'
        | '{'
        | '}'
        | '"'
        | '\''
        | '`'
        | '-'
        | '_'
        | '/'
        | '\\' -> true
        | _ -> false
      in
      let len = String.length token in
      if len = 0 then token
      else
        let rec left i =
          if i >= len then len
          else if is_punct token.[i] then left (i + 1)
          else i
        in
        let rec right i =
          if i < 0 then -1
          else if is_punct token.[i] then right (i - 1)
          else i
        in
        let l = left 0 in
        let r = right (len - 1) in
        if r < l then "" else String.sub token l (r - l + 1)
    in
    tokens
    |> List.map String.lowercase_ascii
    |> List.map trim_punct
    |> List.filter (fun token -> token <> "")

let jaccard_similarity a b =
  let set_a = List.fold_left (fun m t -> StringSet.add t m) StringSet.empty a in
  let set_b = List.fold_left (fun m t -> StringSet.add t m) StringSet.empty b in
  let intersection =
    StringSet.fold
      (fun token acc -> if StringSet.mem token set_b then acc + 1 else acc)
      set_a 0
  in
  let union = StringSet.cardinal set_a + StringSet.cardinal set_b - intersection in
  if union = 0 then 1.0
  else float_of_int intersection /. float_of_int union

let cosine_similarity a b =
  let freq_add m token =
    let prev = match StringMap.find_opt token m with Some n -> n | None -> 0 in
    StringMap.add token (prev + 1) m
  in
  let fa = List.fold_left freq_add StringMap.empty a in
  let fb = List.fold_left freq_add StringMap.empty b in
  let dot =
    StringMap.fold
      (fun token count acc ->
        match StringMap.find_opt token fb with
        | Some rhs -> acc +. float_of_int (count * rhs)
        | None -> acc)
      fa 0.0
  in
  let norm m =
    StringMap.fold
      (fun _token count acc -> acc +. float_of_int (count * count))
      m 0.0
    |> sqrt
  in
  let na = norm fa in
  let nb = norm fb in
  if na = 0.0 || nb = 0.0 then 0.0 else dot /. (na *. nb)

let intersection_size a b =
  let set_a = List.fold_left (fun m t -> StringSet.add t m) StringSet.empty a in
  let set_b = List.fold_left (fun m t -> StringSet.add t m) StringSet.empty b in
  StringSet.fold
    (fun token acc -> if StringSet.mem token set_b then acc + 1 else acc)
    set_a 0

let classify_drift ~tokens_a ~tokens_b ~jacc ~cos =
  let len_a = List.length tokens_a in
  let len_b = List.length tokens_b in
  let intersection = intersection_size tokens_a tokens_b in
  let coverage =
    if len_a = 0 then 1.0 else float_of_int intersection /. float_of_int len_a
  in
  let size_ratio =
    match max len_a len_b with
    | 0 -> 1.0
    | max_len -> float_of_int (min len_a len_b) /. float_of_int max_len
  in
  if coverage < factual_coverage_floor () || size_ratio < factual_size_ratio_floor () then Factual
  else if cos -. jacc > structural_divergence_threshold () then Structural
  else Semantic

let summarize ~original ~received ~threshold =
  let tokens_a = tokenize original in
  let tokens_b = tokenize received in
  let jacc = jaccard_similarity tokens_a tokens_b in
  let cos = cosine_similarity tokens_a tokens_b in
  let configured = weights () in
  let similarity = (configured.jaccard *. jacc) +. (configured.cosine *. cos) in
  let summary = { similarity; jaccard = jacc; cosine = cos; threshold } in
  (summary, tokens_a, tokens_b)

let text_similarity original received =
  let summary, _, _ =
    summarize ~original ~received ~threshold:(default_threshold ())
  in
  summary.similarity

let verify_handoff ~original ~received ?threshold () =
  let threshold = Option.value threshold ~default:(default_threshold ()) in
  let summary, tokens_a, tokens_b = summarize ~original ~received ~threshold in
  if summary.similarity >= threshold then Verified summary
  else
    let drift_type =
      classify_drift ~tokens_a ~tokens_b ~jacc:summary.jaccard
        ~cos:summary.cosine
    in
    Drift_detected
      {
        similarity = summary.similarity;
        jaccard = summary.jaccard;
        cosine = summary.cosine;
        threshold = summary.threshold;
        drift_type;
      }

let result_to_json = function
  | Verified summary ->
      `Assoc
        [
          ("similarity", `Float summary.similarity);
          ("jaccard", `Float summary.jaccard);
          ("cosine", `Float summary.cosine);
          ("threshold", `Float summary.threshold);
          ("passed", `Bool true);
          ("verdict", `String "verified");
          ("drift_type", `String "none");
        ]
  | Drift_detected details ->
      `Assoc
        [
          ("similarity", `Float details.similarity);
          ("jaccard", `Float details.jaccard);
          ("cosine", `Float details.cosine);
          ("threshold", `Float details.threshold);
          ("passed", `Bool false);
          ("verdict", `String "drift_detected");
          ("drift_type", `String (drift_type_to_string details.drift_type));
        ]

let drift_log_file (config : Coord.config) =
  Filename.concat (Coord.masc_dir config) "drift_guard.jsonl"

let ensure_dir path =
  Fs_compat.mkdir_p path

let append_json_line path json =
  Fs_compat.append_jsonl path json

let verify_and_log config ~from_agent ~to_agent ~task_id ~original ~received
    ?threshold () =
  let result = verify_handoff ~original ~received ?threshold () in
  let log_path = drift_log_file config in
  ensure_dir (Coord.masc_dir config);
  let entry =
    `Assoc
      [
        ("timestamp", `Float (Time_compat.now ()));
        ("from_agent", `String from_agent);
        ("to_agent", `String to_agent);
        ("task_id", `String task_id);
        ("result", result_to_json result);
      ]
  in
  append_json_line log_path entry;
  result

let get_drift_stats config ~days =
  let path = drift_log_file config in
  if not (Sys.file_exists path) then (0, 0, 0.0)
  else
    let cutoff =
      Time_compat.now () -. (float_of_int (max 0 days) *. 24.0 *. 3600.0)
    in
    (* Streaming aggregation — total / drift_count / similarity_sum
       fold over the JSONL without materialising the row list. The
       cutoff predicate also rejects most pre-window rows on long
       histories. *)
    let total = ref 0 in
    let drift_count = ref 0 in
    let similarity_sum = ref 0.0 in
    Fs_compat.fold_jsonl_lines
      ~init:()
      ~f:(fun () ~line_no:_ row ->
        match row with
        | `Assoc fields -> (
            let timestamp =
              match List.assoc_opt "timestamp" fields with
              | Some (`Float value) -> value
              | Some (`Int value) -> float_of_int value
              | _ -> 0.0
            in
            if timestamp >= cutoff then (
              match List.assoc_opt "result" fields with
              | Some (`Assoc result_fields) ->
                  let similarity =
                    match List.assoc_opt "similarity" result_fields with
                    | Some (`Float value) -> value
                    | Some (`Int value) -> float_of_int value
                    | _ -> 0.0
                  in
                  incr total;
                  similarity_sum := !similarity_sum +. similarity;
                  (match List.assoc_opt "passed" result_fields with
                  | Some (`Bool false) -> incr drift_count
                  | Some (`Bool true) | Some _ | None -> ())
              | None | Some _ -> ()))
        | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> ())
      path;
    let avg_similarity =
      if !total = 0 then 0.0 else !similarity_sum /. float_of_int !total
    in
    (!total, !drift_count, avg_similarity)
