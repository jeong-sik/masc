type probe =
  { file_bytes : string -> int option
  ; command_exit : string -> int option
  ; pr_merged : repo:string -> pr:int -> bool option
  ; ci_passed : repo:string -> pr:int -> bool option
  ; custom_check : id:string -> payload:Yojson.Safe.t -> bool option
  }

type outcome =
  | Satisfied
  | Unsatisfied of string
  | Indeterminate of string

let outcome_to_string = function
  | Satisfied -> "satisfied"
  | Unsatisfied reason -> Printf.sprintf "unsatisfied(%s)" reason
  | Indeterminate reason -> Printf.sprintf "indeterminate(%s)" reason

let size_ok ~min_bytes n =
  match min_bytes with None -> true | Some m -> n >= m

let min_bytes_str = function Some m -> string_of_int m | None -> "0"

let eval_file ~path ~min_bytes (probe : probe) =
  match probe.file_bytes path with
  | None -> Unsatisfied (Printf.sprintf "%s: absent" path)
  | Some n when size_ok ~min_bytes n -> Satisfied
  | Some n ->
    Unsatisfied (Printf.sprintf "%s: %dB < min %s" path n (min_bytes_str min_bytes))

let eval_claim (probe : probe) (claim : Evidence_claim.t) : outcome =
  let open Evidence_claim in
  match claim with
  | Artifact_exists { path; min_bytes } -> eval_file ~path ~min_bytes probe
  | File_changed { path; min_bytes } -> eval_file ~path ~min_bytes probe
  | Tests_pass { command; expected_exit } -> (
    match probe.command_exit command with
    | None -> Indeterminate (Printf.sprintf "could not run: %s" command)
    | Some code when code = expected_exit -> Satisfied
    | Some code ->
      Unsatisfied (Printf.sprintf "%s: exit %d <> %d" command code expected_exit))
  | PR_merged { repo; pr_number } -> (
    match probe.pr_merged ~repo ~pr:pr_number with
    | None -> Indeterminate (Printf.sprintf "pr %s#%d: unknown" repo pr_number)
    | Some true -> Satisfied
    | Some false -> Unsatisfied (Printf.sprintf "pr %s#%d not merged" repo pr_number))
  | CI_pass { repo; pr_number } -> (
    match probe.ci_passed ~repo ~pr:pr_number with
    | None -> Indeterminate (Printf.sprintf "ci %s#%d: unknown" repo pr_number)
    | Some true -> Satisfied
    | Some false -> Unsatisfied (Printf.sprintf "ci %s#%d not passing" repo pr_number))
  | Custom_check { id; payload } -> (
    match probe.custom_check ~id ~payload with
    | None -> Indeterminate (Printf.sprintf "custom %s: unknown id / uncheckable" id)
    | Some true -> Satisfied
    | Some false -> Unsatisfied (Printf.sprintf "custom %s failed" id))

let is_indeterminate = function
  | Indeterminate _ -> true
  | Satisfied | Unsatisfied _ -> false

let is_unsatisfied = function
  | Unsatisfied _ -> true
  | Satisfied | Indeterminate _ -> false

let eval_all (probe : probe) (claims : Evidence_claim.t list) : outcome =
  match claims with
  | [] -> Unsatisfied "no typed claims declared"
  | _ ->
    let outcomes = List.map (eval_claim probe) claims in
    (* Indeterminate dominates Unsatisfied: if any claim could not be
       evaluated, report indeterminate rather than a false definite "no".
       Satisfied requires every claim Satisfied over a non-empty list. *)
    (match List.find_opt is_indeterminate outcomes with
     | Some ind -> ind
     | None -> (
       match List.find_opt is_unsatisfied outcomes with
       | Some uns -> uns
       | None -> Satisfied))
