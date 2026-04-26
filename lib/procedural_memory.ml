(** Procedural Memory — Patterns extracted from repeated agent behavior.

    Crystallization uses adaptive thresholding:
    - Standard: 3+ occurrences with 70%+ positive outcomes
    - Rare-but-perfect: 2+ occurrences with 100% success rate
    Thresholds are configurable via MASC_PROC_MIN_EVIDENCE and
    MASC_PROC_MIN_CONFIDENCE environment variables.

    Crystallized procedures are injected into successor agents via capsule hydration.

    Storage: .masc/procedures/{agent}/procedures.jsonl

    @since 2.90.0 *)

open Printf

(** A learned procedure — "When X, do Y". *)
type procedure = {
  id : string;
  agent_name : string;
  pattern : string;           (** "When X, do Y" description *)
  evidence : string list;     (** Decision IDs that support this pattern *)
  success_count : int;
  failure_count : int;
  confidence : float;         (** success / (success + failure) *)
  created_at : float;
  last_applied : float;
}

(* ================================================================ *)
(* Paths                                                            *)
(* ================================================================ *)

let procedures_dir ~agent_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:(Env_config.base_path ()))
       "procedures")
    agent_name

let procedures_path ~agent_name =
  sprintf "%s/procedures.jsonl" (procedures_dir ~agent_name)

let ensure_dir path =
  Fs_compat.mkdir_p path

(* ================================================================ *)
(* JSON Serialization                                               *)
(* ================================================================ *)

let to_json (p : procedure) : Yojson.Safe.t =
  `Assoc [
    ("id", `String p.id);
    ("agent_name", `String p.agent_name);
    ("pattern", `String p.pattern);
    ("evidence", `List (List.map (fun e -> `String e) p.evidence));
    ("success_count", `Int p.success_count);
    ("failure_count", `Int p.failure_count);
    ("confidence", `Float p.confidence);
    ("created_at", `Float p.created_at);
    ("last_applied", `Float p.last_applied);
  ]

let of_json (json : Yojson.Safe.t) : procedure option =
  match Safe_ops.json_string_opt "id" json,
        Safe_ops.json_string_opt "agent_name" json,
        Safe_ops.json_string_opt "pattern" json with
  | Some id, Some agent_name, Some pattern ->
    (match Safe_ops.json_int_opt "success_count" json,
           Safe_ops.json_int_opt "failure_count" json,
           Safe_ops.json_float_opt "confidence" json,
           Safe_ops.json_float_opt "created_at" json with
     | Some success_count, Some failure_count, Some confidence, Some created_at ->
       Some {
         id;
         agent_name;
         pattern;
         evidence = Safe_ops.json_string_list "evidence" json;
         success_count;
         failure_count;
         confidence;
         created_at;
         last_applied = Safe_ops.json_float ~default:0.0 "last_applied" json;
       }
     | _ -> None)
  | _ -> None

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let load_procedures ~agent_name : procedure list =
  let path = procedures_path ~agent_name in
  Fs_compat.load_jsonl path
  |> List.filter_map of_json

let save_procedure ~agent_name (p : procedure) =
  let dir = procedures_dir ~agent_name in
  ensure_dir dir;
  let path = procedures_path ~agent_name in
  Fs_compat.append_jsonl path (to_json p)

let rewrite_procedures ~agent_name (procs : procedure list) =
  let dir = procedures_dir ~agent_name in
  ensure_dir dir;
  let path = procedures_path ~agent_name in
  let content =
    procs
    |> List.map (fun p -> Yojson.Safe.to_string (to_json p))
    |> String.concat "\n"
    |> fun s -> if s = "" then "" else s ^ "\n"
  in
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> Log.Config.warn "procedural_memory save: %s" msg

(* ================================================================ *)
(* Procedure Operations                                             *)
(* ================================================================ *)

(** Record a positive or negative outcome for a pattern.
    If the pattern already exists, update counts. Otherwise create new. *)
let record_outcome ~agent_name ~pattern ~evidence_id ~success =
  let procs = load_procedures ~agent_name in
  let existing = List.find_opt (fun p -> p.pattern = pattern) procs in
  match existing with
  | Some p ->
    let updated = {
      p with
      success_count = p.success_count + (if success then 1 else 0);
      failure_count = p.failure_count + (if success then 0 else 1);
      evidence = evidence_id :: p.evidence;
      last_applied = Time_compat.now ();
      confidence =
        let s = Float.of_int (p.success_count + (if success then 1 else 0)) in
        let f = Float.of_int (p.failure_count + (if success then 0 else 1)) in
        s /. (s +. f);
    } in
    let patched = List.map (fun q ->
      if q.id = p.id then updated else q
    ) procs in
    rewrite_procedures ~agent_name patched;
    updated
  | None ->
    let now = Time_compat.now () in
    let id = sprintf "proc-%s-%d-%06x"
      agent_name (int_of_float now) (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF) in
    let p = {
      id;
      agent_name;
      pattern;
      evidence = [evidence_id];
      success_count = (if success then 1 else 0);
      failure_count = (if success then 0 else 1);
      confidence = if success then 1.0 else 0.0;
      created_at = now;
      last_applied = now;
    } in
    save_procedure ~agent_name p;
    p

(** Minimum evidence count required for crystallization.
    Configurable via MASC_PROC_MIN_EVIDENCE (default: 3).
    High-confidence patterns (100%) with fewer evidence may still qualify
    when adaptive thresholding is enabled. *)
let min_evidence () =
  Env_config.ProcMemory.min_evidence

(** Minimum confidence required for crystallization.
    Configurable via MASC_PROC_MIN_CONFIDENCE (default: 0.7). *)
let min_confidence () =
  Env_config.ProcMemory.min_confidence

(** Adaptive crystallization check.
    Standard: evidence >= min_evidence AND confidence >= min_confidence.
    Relaxed:  confidence = 1.0 AND evidence >= 2 (perfect success, rare pattern).
    This prevents critical-but-rare patterns from being lost forever. *)
let is_crystallized (p : procedure) : bool =
  let min_ev = min_evidence () in
  let min_conf = min_confidence () in
  let evidence_count = List.length p.evidence in
  let standard = evidence_count >= min_ev && p.confidence >= min_conf in
  let rare_but_perfect = p.confidence >= 1.0 && evidence_count >= 2 in
  standard || rare_but_perfect

(** Get top-N crystallized procedures by confidence.
    Uses adaptive thresholding: standard (3+ evidence, 70% confidence)
    plus rare-but-perfect (2+ evidence, 100% confidence). *)
let top_procedures ~agent_name ~limit : procedure list =
  let procs = load_procedures ~agent_name in
  procs
  |> List.filter is_crystallized
  |> List.sort (fun a b -> Float.compare b.confidence a.confidence)
  |> List.filteri (fun i _ -> i < limit)

(** Format procedures for capsule injection. *)
let format_for_dna ~agent_name ~limit : string =
  let procs = top_procedures ~agent_name ~limit in
  if procs = [] then ""
  else
    let lines = List.map (fun p ->
      sprintf "- %s (confidence: %.0f%%, evidence: %d)"
        p.pattern (p.confidence *. 100.0) (List.length p.evidence)
    ) procs in
    "[PROCEDURES]\n" ^ String.concat "\n" lines ^ "\n[/PROCEDURES]"
