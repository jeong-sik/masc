(** Cdal_friction_projection -- Single-run friction projection from v1 evidence.

    @since CDAL Phase 1A *)

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type blocked_attempt_key = {
  tool_name : string;
  violation_kind : string;
  effective_mode : string;
}

type blocked_attempt_group = {
  key : blocked_attempt_key;
  count : int;
}

type evidence_gap_group = {
  artifact : string;
  reason : string;
  impact : string;
  count : int;
}

type friction_projection = {
  window : string;
  based_on_run_ids : string list;
  basis_hash : string;
  blocked_attempt_count : int;
  blocked_tool_counts : (string * int) list;
  blocked_attempt_groups : blocked_attempt_group list;
  evidence_gap_groups : evidence_gap_group list;
  review_tripwires : string list;
}

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let mode_violations_suffix = "evidence/mode_violations.json"

(** Find the first raw_evidence_ref that ends with mode_violations.json. *)
let find_violations_ref (proof : Agent_sdk.Cdal_proof.t) : string option =
  List.find_opt
    (fun ref_ -> String.ends_with ~suffix:mode_violations_suffix ref_)
    proof.raw_evidence_refs

(** Convert a Violation_record.t to its v1 grouping key. *)
let key_of_violation (v : Violation_record.t) : blocked_attempt_key =
  {
    tool_name = v.tool_name;
    violation_kind = Violation_record.violation_kind_to_string v.violation_kind;
    effective_mode = Agent_sdk.Execution_mode.to_string v.effective_mode;
  }

(** Compare two keys for stable sorting. *)
let compare_key (a : blocked_attempt_key) (b : blocked_attempt_key) : int =
  let c = String.compare a.tool_name b.tool_name in
  if c <> 0 then c
  else
    let c = String.compare a.violation_kind b.violation_kind in
    if c <> 0 then c
    else String.compare a.effective_mode b.effective_mode

(** Group violations by key using Hashtbl, returning sorted groups. *)
let group_violations (violations : Violation_record.t list)
    : blocked_attempt_group list =
  let module H = Hashtbl.Make(struct
    type t = blocked_attempt_key
    let equal a b = compare_key a b = 0
    let hash k =
      Hashtbl.hash (k.tool_name, k.violation_kind, k.effective_mode)
  end) in
  let tbl = H.create 16 in
  List.iter (fun v ->
    let k = key_of_violation v in
    let prev = try H.find tbl k with Not_found -> 0 in
    H.replace tbl k (prev + 1)
  ) violations;
  H.fold (fun key count acc -> { key; count } :: acc) tbl []
  |> List.sort (fun a b -> compare_key a.key b.key)

(** Compute MD5 basis_hash from run_id + "|friction_v1". *)
let compute_basis_hash (run_id : string) : string =
  let input = run_id ^ "|friction_v1" in
  "md5:" ^ (Digest.string input |> Digest.to_hex)

(** Derive blocked_tool_counts from attempt groups. *)
let compute_tool_counts (groups : blocked_attempt_group list)
    : (string * int) list =
  let tbl = Hashtbl.create 8 in
  List.iter (fun g ->
    let prev = try Hashtbl.find tbl g.key.tool_name with Not_found -> 0 in
    Hashtbl.replace tbl g.key.tool_name (prev + g.count)
  ) groups;
  Hashtbl.fold (fun name count acc -> (name, count) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(** Derive evidence_gap_groups from verdict completeness_gaps. *)
let compute_gap_groups (gaps : Cdal_types.completeness_gap list)
    : evidence_gap_group list =
  let impact_str = function
    | Cdal_types.Blocks_verdict -> "blocks_verdict"
    | Cdal_types.Annotation_only -> "annotation_only"
  in
  List.map (fun (g : Cdal_types.completeness_gap) ->
    { artifact = g.artifact;
      reason = g.reason;
      impact = impact_str g.impact;
      count = 1 }
  ) gaps

(** Compute review tripwires from attempt groups exceeding threshold. *)
let compute_tripwires ~threshold (groups : blocked_attempt_group list)
    : string list =
  List.filter_map (fun (g : blocked_attempt_group) ->
    if g.count >= threshold then
      Some (Printf.sprintf "blocked_attempts:%s:%d+"
              g.key.tool_name g.count)
    else None
  ) groups
  |> List.sort String.compare

(* ================================================================ *)
(* Public API                                                        *)
(* ================================================================ *)

let project_single_run
    ~(store : Agent_sdk.Proof_store.config)
    ?(completeness_gaps : Cdal_types.completeness_gap list = [])
    ?(tripwire_threshold = 3)
    (proof : Agent_sdk.Cdal_proof.t)
    : friction_projection option =
  let groups, blocked_attempt_count =
    match find_violations_ref proof with
    | None -> ([], 0)
    | Some ref_ ->
      match Proof_artifact_reader.read_json store ref_ with
      | Error _ -> ([], 0)
      | Ok json ->
        match Violation_record.of_json_list json with
        | Error _ | Ok [] -> ([], 0)
        | Ok violations ->
          let g = group_violations violations in
          let c = List.fold_left
            (fun acc (grp : blocked_attempt_group) -> acc + grp.count) 0 g in
          (g, c)
  in
  let gap_groups = compute_gap_groups completeness_gaps in
  if blocked_attempt_count = 0 && gap_groups = [] then None
  else
    Some {
      window = "single_run";
      based_on_run_ids = [proof.run_id];
      basis_hash = compute_basis_hash proof.run_id;
      blocked_attempt_count;
      blocked_tool_counts = compute_tool_counts groups;
      blocked_attempt_groups = groups;
      evidence_gap_groups = gap_groups;
      review_tripwires = compute_tripwires ~threshold:tripwire_threshold groups;
    }

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let blocked_attempt_key_to_json (k : blocked_attempt_key) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("effective_mode", `String k.effective_mode);
    ("tool_name", `String k.tool_name);
    ("violation_kind", `String k.violation_kind);
  ])

let blocked_attempt_group_to_json (g : blocked_attempt_group) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("count", `Int g.count);
    ("key", blocked_attempt_key_to_json g.key);
  ])

let evidence_gap_group_to_json (g : evidence_gap_group) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("artifact", `String g.artifact);
    ("count", `Int g.count);
    ("impact", `String g.impact);
    ("reason", `String g.reason);
  ])

let to_json (fp : friction_projection) : Yojson.Safe.t =
  Yojson.Safe.sort (`Assoc [
    ("based_on_run_ids", `List (List.map (fun s -> `String s) fp.based_on_run_ids));
    ("basis_hash", `String fp.basis_hash);
    ("blocked_attempt_count", `Int fp.blocked_attempt_count);
    ("blocked_attempt_groups",
     `List (List.map blocked_attempt_group_to_json fp.blocked_attempt_groups));
    ("blocked_tool_counts",
     `List (List.map (fun (name, count) ->
       Yojson.Safe.sort (`Assoc [("count", `Int count); ("tool_name", `String name)]))
       fp.blocked_tool_counts));
    ("evidence_gap_groups",
     `List (List.map evidence_gap_group_to_json fp.evidence_gap_groups));
    ("review_tripwires", `List (List.map (fun s -> `String s) fp.review_tripwires));
    ("window", `String fp.window);
  ])
