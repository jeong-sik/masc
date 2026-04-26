(** Cdal_friction_projection -- Single-run friction projection from v1 evidence.

    @since CDAL Phase 1A *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type blocked_attempt_key =
  { tool_name : string
  ; violation_kind : string
  ; effective_mode : string
  }

type blocked_attempt_group =
  { key : blocked_attempt_key
  ; count : int
  }

type evidence_gap_group =
  { artifact : string
  ; reason : string
  ; impact : string
  ; count : int
  }

type friction_projection =
  { window : string
  ; based_on_run_ids : string list
  ; basis_hash : string
  ; blocked_attempt_count : int
  ; blocked_tool_counts : (string * int) list
  ; blocked_attempt_groups : blocked_attempt_group list
  ; evidence_gap_groups : evidence_gap_group list
  ; review_tripwires : string list
  }

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let mode_violations_suffix = "evidence/mode_violations.json"
let review_warning_suffix = "evidence/review_warning.json"

(** Find the first raw_evidence_ref that ends with mode_violations.json. *)
let find_violations_ref (proof : Oas.Cdal_proof.t) : string option =
  List.find_opt
    (fun ref_ -> String.ends_with ~suffix:mode_violations_suffix ref_)
    proof.raw_evidence_refs
;;

(** Convert a Violation_record.t to its v1 grouping key. *)
let key_of_violation (v : Violation_record.t) : blocked_attempt_key =
  { tool_name = v.tool_name
  ; violation_kind = Violation_record.violation_kind_to_string v.violation_kind
  ; effective_mode = Oas.Execution_mode.to_string v.effective_mode
  }
;;

(** Compare two keys for stable sorting. *)
let compare_key (a : blocked_attempt_key) (b : blocked_attempt_key) : int =
  let c = String.compare a.tool_name b.tool_name in
  if c <> 0
  then c
  else (
    let c = String.compare a.violation_kind b.violation_kind in
    if c <> 0 then c else String.compare a.effective_mode b.effective_mode)
;;

(** Group violations by key using Hashtbl, returning sorted groups. *)
let group_violations (violations : Violation_record.t list) : blocked_attempt_group list =
  let module H = Hashtbl.Make (struct
      type t = blocked_attempt_key

      let equal a b = compare_key a b = 0
      let hash k = Hashtbl.hash (k.tool_name, k.violation_kind, k.effective_mode)
    end)
  in
  let tbl = H.create 16 in
  List.iter
    (fun v ->
       let k = key_of_violation v in
       let prev = Option.value ~default:0 (H.find_opt tbl k) in
       H.replace tbl k (prev + 1))
    violations;
  H.fold (fun key count acc -> { key; count } :: acc) tbl []
  |> List.sort (fun a b -> compare_key a.key b.key)
;;

(** Compute MD5 basis_hash from run_id + "|friction_v1". *)
let compute_basis_hash (run_id : string) : string =
  let input = run_id ^ "|friction_v1" in
  "md5:" ^ (Digest.string input |> Digest.to_hex)
;;

(** Derive blocked_tool_counts from attempt groups. *)
let compute_tool_counts (groups : blocked_attempt_group list) : (string * int) list =
  let tbl = Hashtbl.create 8 in
  List.iter
    (fun g ->
       let prev = Option.value ~default:0 (Hashtbl.find_opt tbl g.key.tool_name) in
       Hashtbl.replace tbl g.key.tool_name (prev + g.count))
    groups;
  Hashtbl.fold (fun name count acc -> (name, count) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
;;

(** Derive evidence_gap_groups from verdict completeness_gaps. *)
let compute_gap_groups (gaps : Cdal_types.completeness_gap list) : evidence_gap_group list
  =
  let impact_str = function
    | Cdal_types.Blocks_verdict -> "blocks_verdict"
    | Cdal_types.Annotation_only -> "annotation_only"
  in
  List.map
    (fun (g : Cdal_types.completeness_gap) ->
       { artifact = g.artifact
       ; reason = g.reason
       ; impact = impact_str g.impact
       ; count = 1
       })
    gaps
;;

(** Compute review tripwires from attempt groups exceeding threshold. *)
let compute_tripwires ~threshold (groups : blocked_attempt_group list) : string list =
  List.filter_map
    (fun (g : blocked_attempt_group) ->
       if g.count >= threshold
       then Some (Printf.sprintf "blocked_attempts:%s:%d+" g.key.tool_name g.count)
       else None)
    groups
  |> List.sort String.compare
;;

let review_tripwires_of_gaps (gaps : Cdal_types.completeness_gap list) : string list =
  let has_review_gap =
    List.exists
      (fun (g : Cdal_types.completeness_gap) ->
         g.impact = Cdal_types.Blocks_verdict
         && String.equal g.artifact review_warning_suffix)
      gaps
  in
  if has_review_gap then [ "review_requirement:submit_for_verification" ] else []
;;

(* ================================================================ *)
(* Public API                                                        *)
(* ================================================================ *)

let project_single_run
      ~(store : Oas.Proof_store.config)
      ?(completeness_gaps : Cdal_types.completeness_gap list = [])
      ?(tripwire_threshold = 3)
      (proof : Oas.Cdal_proof.t)
  : friction_projection option
  =
  let groups, blocked_attempt_count =
    match find_violations_ref proof with
    | None -> [], 0
    | Some ref_ ->
      (match Proof_artifact_reader.read_json store ref_ with
       | Error _ -> [], 0
       | Ok json ->
         (match Violation_record.of_json_list json with
          | Error _ | Ok [] -> [], 0
          | Ok violations ->
            let g = group_violations violations in
            let c =
              List.fold_left
                (fun acc (grp : blocked_attempt_group) -> acc + grp.count)
                0
                g
            in
            g, c))
  in
  let gap_groups = compute_gap_groups completeness_gaps in
  let review_tripwires =
    List.sort_uniq
      String.compare
      (compute_tripwires ~threshold:tripwire_threshold groups
       @ review_tripwires_of_gaps completeness_gaps)
  in
  if blocked_attempt_count = 0 && gap_groups = []
  then None
  else
    Some
      { window = "single_run"
      ; based_on_run_ids = [ proof.run_id ]
      ; basis_hash = compute_basis_hash proof.run_id
      ; blocked_attempt_count
      ; blocked_tool_counts = compute_tool_counts groups
      ; blocked_attempt_groups = groups
      ; evidence_gap_groups = gap_groups
      ; review_tripwires
      }
;;

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let blocked_attempt_key_to_json (k : blocked_attempt_key) : Yojson.Safe.t =
  Yojson.Safe.sort
    (`Assoc
        [ "effective_mode", `String k.effective_mode
        ; "tool_name", `String k.tool_name
        ; "violation_kind", `String k.violation_kind
        ])
;;

let blocked_attempt_group_to_json (g : blocked_attempt_group) : Yojson.Safe.t =
  Yojson.Safe.sort
    (`Assoc [ "count", `Int g.count; "key", blocked_attempt_key_to_json g.key ])
;;

let evidence_gap_group_to_json (g : evidence_gap_group) : Yojson.Safe.t =
  Yojson.Safe.sort
    (`Assoc
        [ "artifact", `String g.artifact
        ; "count", `Int g.count
        ; "impact", `String g.impact
        ; "reason", `String g.reason
        ])
;;

(* ================================================================ *)
(* Cross-run window support                                          *)
(* ================================================================ *)

type run_window =
  | Single_run
  | Last_n_runs of int
  | Session of string
  | Rolling_seconds of float

let window_to_string = function
  | Single_run -> "single_run"
  | Last_n_runs n -> Printf.sprintf "last_%d_runs" n
  | Session s -> Printf.sprintf "session:%s" s
  | Rolling_seconds s -> Printf.sprintf "rolling_%.0fs" s
;;

let compute_window_basis_hash ~window ~run_ids =
  let sorted_ids = List.sort String.compare run_ids in
  let input =
    window_to_string window ^ "|" ^ String.concat "," sorted_ids ^ "|friction_v1"
  in
  "md5:" ^ (Digest.string input |> Digest.to_hex)
;;

let merge_groups (all_groups : blocked_attempt_group list list)
  : blocked_attempt_group list
  =
  let module H = Hashtbl.Make (struct
      type t = blocked_attempt_key

      let equal a b = compare_key a b = 0
      let hash k = Hashtbl.hash (k.tool_name, k.violation_kind, k.effective_mode)
    end)
  in
  let tbl = H.create 32 in
  List.iter
    (fun groups ->
       List.iter
         (fun (g : blocked_attempt_group) ->
            let prev = Option.value ~default:0 (H.find_opt tbl g.key) in
            H.replace tbl g.key (prev + g.count))
         groups)
    all_groups;
  H.fold (fun key count acc -> { key; count } :: acc) tbl []
  |> List.sort (fun a b -> compare_key a.key b.key)
;;

let project_single_run_groups ~(store : Oas.Proof_store.config) (proof : Oas.Cdal_proof.t)
  : blocked_attempt_group list * int
  =
  match find_violations_ref proof with
  | None -> [], 0
  | Some ref_ ->
    (match Proof_artifact_reader.read_json store ref_ with
     | Error _ -> [], 0
     | Ok json ->
       (match Violation_record.of_json_list json with
        | Error _ | Ok [] -> [], 0
        | Ok violations ->
          let g = group_violations violations in
          let c =
            List.fold_left (fun acc (grp : blocked_attempt_group) -> acc + grp.count) 0 g
          in
          g, c))
;;

let project_window
      ~(store : Oas.Proof_store.config)
      ~(window : run_window)
      ?(completeness_gaps : Cdal_types.completeness_gap list = [])
      ?(tripwire_threshold = 3)
      (proofs : Oas.Cdal_proof.t list)
  : friction_projection option
  =
  match window, proofs with
  | Single_run, [ proof ] ->
    project_single_run ~store ~completeness_gaps ~tripwire_threshold proof
  | Single_run, _ -> None (* Single_run requires exactly one proof *)
  | _, [] -> None
  | _, _ ->
    let all_groups =
      List.map
        (fun proof ->
           let groups, _ = project_single_run_groups ~store proof in
           groups)
        proofs
    in
    let merged = merge_groups all_groups in
    let blocked_attempt_count =
      List.fold_left (fun acc (g : blocked_attempt_group) -> acc + g.count) 0 merged
    in
    let gap_groups = compute_gap_groups completeness_gaps in
    let review_tripwires =
      List.sort_uniq
        String.compare
        (compute_tripwires ~threshold:tripwire_threshold merged
         @ review_tripwires_of_gaps completeness_gaps)
    in
    if blocked_attempt_count = 0 && gap_groups = []
    then None
    else (
      let run_ids = List.map (fun (p : Oas.Cdal_proof.t) -> p.run_id) proofs in
      Some
        { window = window_to_string window
        ; based_on_run_ids = run_ids
        ; basis_hash = compute_window_basis_hash ~window ~run_ids
        ; blocked_attempt_count
        ; blocked_tool_counts = compute_tool_counts merged
        ; blocked_attempt_groups = merged
        ; evidence_gap_groups = gap_groups
        ; review_tripwires
        })
;;

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let to_json (fp : friction_projection) : Yojson.Safe.t =
  Yojson.Safe.sort
    (`Assoc
        [ "based_on_run_ids", `List (List.map (fun s -> `String s) fp.based_on_run_ids)
        ; "basis_hash", `String fp.basis_hash
        ; "blocked_attempt_count", `Int fp.blocked_attempt_count
        ; ( "blocked_attempt_groups"
          , `List (List.map blocked_attempt_group_to_json fp.blocked_attempt_groups) )
        ; ( "blocked_tool_counts"
          , `List
              (List.map
                 (fun (name, count) ->
                    Yojson.Safe.sort
                      (`Assoc [ "count", `Int count; "tool_name", `String name ]))
                 fp.blocked_tool_counts) )
        ; ( "evidence_gap_groups"
          , `List (List.map evidence_gap_group_to_json fp.evidence_gap_groups) )
        ; "review_tripwires", `List (List.map (fun s -> `String s) fp.review_tripwires)
        ; "window", `String fp.window
        ])
;;
