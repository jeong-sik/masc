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

let base_path_or_default = function
  | Some base_path -> base_path
  | None -> Env_config.base_path ()
;;

let procedures_dir ?base_path ~agent_name () =
  let base_path = base_path_or_default base_path in
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "procedures")
    agent_name

let procedures_path ?base_path ~agent_name () =
  sprintf "%s/procedures.jsonl" (procedures_dir ?base_path ~agent_name ())

let with_procedures_lock ?base_path ~agent_name f =
  let dir = procedures_dir ?base_path ~agent_name () in
  Fs_compat.mkdir_p dir;
  File_lock_eio.with_lock (procedures_path ?base_path ~agent_name ()) f

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

type load_error =
  { path : string
  ; line_number : int
  ; message : string
  }

type load_result = (procedure list, load_error list) result

let load_procedures ?base_path ~agent_name () : procedure list =
  with_procedures_lock ?base_path ~agent_name (fun () ->
    let path = procedures_path ?base_path ~agent_name () in
    Fs_compat.load_jsonl path
    |> List.filter_map of_json)

let load_procedures_strict ?base_path ~agent_name () : load_result =
  with_procedures_lock ?base_path ~agent_name (fun () ->
    let path = procedures_path ?base_path ~agent_name () in
    if not (Fs_compat.file_exists path)
    then Ok []
    else (
      let content = Fs_compat.load_file path in
      let lines = String.split_on_char '\n' content in
      let line_no = ref 0 in
      let errors = ref [] in
      let procedures = ref [] in
      List.iter
        (fun raw ->
           let line = String.trim raw in
           if String.equal line ""
           then ()
           else (
             incr line_no;
             match Yojson.Safe.from_string line with
             | exception Yojson.Json_error msg ->
               errors := { path; line_number = !line_no; message = msg } :: !errors
             | json ->
               (match of_json json with
                | None ->
                  errors :=
                    { path
                    ; line_number = !line_no
                    ; message = "procedure schema mismatch"
                    }
                    :: !errors
                | Some p -> procedures := p :: !procedures)))
        lines;
      match List.rev !errors with
      | [] -> Ok (List.rev !procedures)
      | errs -> Error errs))

let save_procedure ?base_path ~agent_name (p : procedure) =
  with_procedures_lock ?base_path ~agent_name (fun () ->
    let path = procedures_path ?base_path ~agent_name () in
    Fs_compat.append_jsonl path (to_json p))

let rewrite_procedures ?base_path ~agent_name (procs : procedure list) =
  try
    with_procedures_lock ?base_path ~agent_name (fun () ->
      let path = procedures_path ?base_path ~agent_name () in
      let content =
        procs
        |> List.map (fun p -> Yojson.Safe.to_string (to_json p))
        |> String.concat "\n"
        |> fun s -> if s = "" then "" else s ^ "\n"
      in
      let report = Fs_compat.save_file_atomic_eio path content in
      Fs_compat.Durable_mutation.fold_report report
        ~not_committed:(fun report ->
          Error (Fs_compat.Durable_mutation.report_to_string report))
        ~committed_not_durable:(fun report ->
          Log.Misc.warn
            "procedural memory rewrite committed with sync debt path=%s detail=%s"
            path
            (Fs_compat.Durable_mutation.report_to_string report);
          Ok ())
        ~durable:(fun report ->
          (match report.diagnostics with
           | [] -> ()
           | _ ->
             Log.Misc.warn
               "procedural memory rewrite durable with cleanup diagnostics path=%s detail=%s"
               path
               (Fs_compat.Durable_mutation.report_to_string report));
          Ok ()))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

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
let top_procedures ?base_path ~agent_name ~limit () : procedure list =
  let procs = load_procedures ?base_path ~agent_name () in
  procs
  |> List.filter is_crystallized
  |> List.sort (fun a b -> Float.compare b.confidence a.confidence)
  |> List.filteri (fun i _ -> i < limit)
