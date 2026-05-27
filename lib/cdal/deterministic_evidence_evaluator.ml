type evaluation_result =
  | All_satisfied
  | Partial of
      { satisfied : Evidence_claim.t list
      ; missing : Evidence_claim.t list
      }
  | Inconclusive of
      { reason : string
      ; transient : bool
      }

type pr_check_result =
  [ `Merged of string
  | `Open
  | `Closed_unmerged
  | `Not_found
  ]

type ci_check_result =
  [ `All_pass
  | `Any_fail of string list
  | `In_progress
  | `Not_found
  ]

type exec_result =
  [ `Exit of int
  | `Timeout
  | `Spawn_error of string
  ]

type file_stat_result =
  [ `Exists of int
  | `Missing
  ]

type custom_check_result =
  [ `Satisfied
  | `Unsatisfied of string
  | `Unknown_id
  ]

type evaluator_deps =
  { gh_pr_check : repo:string -> pr_number:int -> pr_check_result
  ; gh_ci_check : repo:string -> pr_number:int -> ci_check_result
  ; exec_command : command:string -> timeout_sec:int -> exec_result
  ; file_stat : path:string -> file_stat_result
  ; custom_check :
      id:string -> payload:Yojson.Safe.t -> custom_check_result
  }

(** Per-claim verdict used internally before aggregation. *)
type claim_verdict =
  | Satisfied
  | Unsatisfied of string  (** human-readable reason kept for [Partial.missing] formatting *)
  | Transient_inconclusive of string
  | Hard_inconclusive of string

let check_pr_merged (deps : evaluator_deps) ~repo ~pr_number =
  match deps.gh_pr_check ~repo ~pr_number with
  | `Merged _ -> Satisfied
  | `Open ->
    Transient_inconclusive
      (Printf.sprintf "%s#%d is open, not yet merged" repo pr_number)
  | `Closed_unmerged ->
    Unsatisfied (Printf.sprintf "%s#%d is closed without merge" repo pr_number)
  | `Not_found ->
    Hard_inconclusive
      (Printf.sprintf "%s#%d not found via gh_pr_check" repo pr_number)

let check_ci_pass (deps : evaluator_deps) ~repo ~pr_number =
  match deps.gh_ci_check ~repo ~pr_number with
  | `All_pass -> Satisfied
  | `In_progress ->
    Transient_inconclusive
      (Printf.sprintf "%s#%d CI checks still in progress" repo pr_number)
  | `Any_fail failing ->
    Unsatisfied
      (Printf.sprintf
         "%s#%d CI fails: %s"
         repo
         pr_number
         (String.concat ", " failing))
  | `Not_found ->
    Hard_inconclusive
      (Printf.sprintf "%s#%d not found via gh_ci_check" repo pr_number)

let check_tests_pass (deps : evaluator_deps) ~command ~expected_exit =
  match deps.exec_command ~command ~timeout_sec:300 with
  | `Exit code when code = expected_exit -> Satisfied
  | `Exit code ->
    Unsatisfied
      (Printf.sprintf
         "command %S exited %d (expected %d)"
         command
         code
         expected_exit)
  | `Timeout ->
    Transient_inconclusive
      (Printf.sprintf "command %S timed out" command)
  | `Spawn_error msg ->
    Hard_inconclusive
      (Printf.sprintf "command %S spawn failed: %s" command msg)

let check_size_constraint ~path ~min_bytes ~observed =
  match min_bytes with
  | None -> Satisfied
  | Some n when observed >= n -> Satisfied
  | Some n ->
    Unsatisfied
      (Printf.sprintf
         "%s is %d bytes (< required %d)"
         path
         observed
         n)

let check_artifact_exists (deps : evaluator_deps) ~path ~min_bytes =
  match deps.file_stat ~path with
  | `Exists size -> check_size_constraint ~path ~min_bytes ~observed:size
  | `Missing -> Unsatisfied (Printf.sprintf "%s does not exist" path)

let check_file_changed (deps : evaluator_deps) ~path ~min_bytes =
  (* Phase B: same shape as Artifact_exists; semantic distinction
     (changed vs. exists) is enforced at task-creation time, not by
     re-reading git history during evaluation. Phase C may add a
     [git_diff] dep for stricter "changed" detection. *)
  check_artifact_exists deps ~path ~min_bytes

let check_custom (deps : evaluator_deps) ~id ~payload =
  match deps.custom_check ~id ~payload with
  | `Satisfied -> Satisfied
  | `Unsatisfied reason ->
    Unsatisfied (Printf.sprintf "custom_check(%s): %s" id reason)
  | `Unknown_id ->
    Hard_inconclusive
      (Printf.sprintf "custom_check id %S not in evaluator allowlist" id)

let verdict_of_claim (deps : evaluator_deps) (claim : Evidence_claim.t) =
  match claim with
  | PR_merged { repo; pr_number } -> check_pr_merged deps ~repo ~pr_number
  | CI_pass { repo; pr_number } -> check_ci_pass deps ~repo ~pr_number
  | Tests_pass { command; expected_exit } ->
    check_tests_pass deps ~command ~expected_exit
  | Artifact_exists { path; min_bytes } ->
    check_artifact_exists deps ~path ~min_bytes
  | File_changed { path; min_bytes } ->
    check_file_changed deps ~path ~min_bytes
  | Custom_check { id; payload } -> check_custom deps ~id ~payload

(** Aggregate per-claim verdicts. Transient inconclusive wins over
    everything (callers retry before treating as failure). Hard
    inconclusive wins over Partial (gate blocks on protocol error).
    Otherwise Satisfied-only → All_satisfied; mixed → Partial. *)
let aggregate (claims : Evidence_claim.t list) (verdicts : claim_verdict list) =
  let paired = List.combine claims verdicts in
  let transient =
    List.find_map
      (fun (_, v) ->
        match v with
        | Transient_inconclusive r -> Some r
        | Satisfied | Unsatisfied _ | Hard_inconclusive _ -> None)
      paired
  in
  match transient with
  | Some reason -> Inconclusive { reason; transient = true }
  | None ->
    let hard =
      List.find_map
        (fun (_, v) ->
          match v with
          | Hard_inconclusive r -> Some r
          | Satisfied | Unsatisfied _ | Transient_inconclusive _ -> None)
        paired
    in
    (match hard with
     | Some reason -> Inconclusive { reason; transient = false }
     | None ->
       let satisfied, missing =
         List.partition_map
           (fun (claim, v) ->
             match v with
             | Satisfied -> Left claim
             | Unsatisfied _ -> Right claim
             | Transient_inconclusive _ | Hard_inconclusive _ ->
               (* unreachable: filtered above *)
               Right claim)
           paired
       in
       (match missing with
        | [] -> All_satisfied
        | _ :: _ -> Partial { satisfied; missing }))

let evaluate ~deps ~claims =
  match claims with
  | [] -> All_satisfied
  | _ :: _ ->
    let verdicts = List.map (verdict_of_claim deps) claims in
    aggregate claims verdicts
