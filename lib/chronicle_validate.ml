(** Chronicle_validate — cross-validate chronicle epochs against git history.
    Pure OCaml, no LLM dependency.

    Checks:
    1. Referenced SHAs exist in git history
    2. Key files are covered by the commit range
    3. RFC files exist on disk
    4. Verification score computation

    @since Project Chronicle Phase 4 *)

(* --- Git capture hook for test isolation --- *)

type git_capture_hook =
  workdir:string -> string list -> (Unix.process_status * string) option

let git_capture_hook_for_tests : git_capture_hook option Atomic.t =
  Atomic.make None

let set_git_capture_hook_for_tests hook =
  Atomic.set git_capture_hook_for_tests (Some hook)

let clear_git_capture_hook_for_tests () =
  Atomic.set git_capture_hook_for_tests None

(* --- Execution helpers --- *)

let run_git ~timeout_sec ~workdir args =
  match Atomic.get git_capture_hook_for_tests with
  | Some hook -> hook ~workdir args
  | None ->
    let argv = [ "git"; "-C"; workdir; "--no-optional-locks" ] @ args in
    let raw_source = String.concat " " (List.map Filename.quote argv) in
    Some
      (Masc_exec.Exec_gate.run_argv_with_status
         ~actor:(Masc_exec.Agent_id.of_string "system/chronicle_validate")
         ~raw_source
         ~summary:"chronicle git validation"
         ~timeout_sec argv)

let run_git_output ~workdir args =
  match run_git ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ()) ~workdir args with
  | Some (Unix.WEXITED 0, output) -> Some output
  | _ -> None

(* --- Validation types --- *)

type validation_result =
  { epoch_id : string
  ; is_valid : bool
  ; sha_check : bool
  ; file_range_check : bool
  ; rfc_refs_valid : bool list
  ; verification_score : float  (* 0.0 ~ 1.0 *)
  ; warnings : string list
  }
[@@deriving show]

(* --- SHA validation --- *)

let sha_exists ~workdir sha =
  match run_git_output ~workdir [ "cat-file"; "-t"; sha ] with
  | Some output ->
    let t = String.trim output in
    t = "commit"
  | None -> false

(* --- File range validation --- *)

let files_in_range ~workdir start_commit end_commit =
  if String.equal start_commit end_commit then
    match
      run_git_output ~workdir
        [ "show"; "--name-only"; "--pretty=format:"; start_commit ]
    with
    | Some output ->
      String.split_on_char '\n' output
      |> List.filter (fun s -> s <> "")
    | None -> []
  else
    let range = Printf.sprintf "%s..%s" start_commit end_commit in
    match run_git_output ~workdir [ "diff"; "--name-only"; range ] with
    | Some output ->
      String.split_on_char '\n' output
      |> List.filter (fun s -> s <> "")
    | None -> []

(* --- RFC file validation --- *)

let rfc_file_exists ~workdir rfc_ref =
  let base =
    workdir |> Filename.concat "docs" |> Filename.concat "rfc"
  in
  let candidates =
    [ Printf.sprintf "%s/%s.md" base rfc_ref
    ; Printf.sprintf "%s/%s.org" base rfc_ref
    ]
  in
  List.exists Sys.file_exists candidates

(* --- Score computation --- *)

let compute_score ~sha_check ~file_range_check ~rfc_refs_valid =
  let base =
    (if sha_check then 0.3 else 0.0)
    +. (if file_range_check then 0.3 else 0.0)
  in
  let rfc =
    match rfc_refs_valid with
    | [] -> 0.4  (* No RFC refs — neutral *)
    | refs ->
      let valid = List.length (List.filter (fun x -> x) refs) in
      0.4 *. (float_of_int valid /. float_of_int (List.length refs))
  in
  min 1.0 (base +. rfc)

(* --- Public API --- *)

let validate_epoch ~workdir epoch =
  let start_ok =
    sha_exists ~workdir epoch.Chronicle_types.start_commit
  in
  let end_ok =
    sha_exists ~workdir epoch.Chronicle_types.end_commit
  in
  let sha_check = start_ok && end_ok in
  let range_files =
    files_in_range ~workdir
      epoch.Chronicle_types.start_commit
      epoch.Chronicle_types.end_commit
  in
  let key_paths =
    List.map (fun (kf : Chronicle_types.key_file_role) -> kf.path)
      epoch.Chronicle_types.key_files
  in
  let file_range_check =
    match key_paths with
    | [] -> true
    | _ -> List.for_all (fun p -> List.mem p range_files) key_paths
  in
  let rfc_refs_valid =
    List.map (rfc_file_exists ~workdir) epoch.Chronicle_types.rfc_refs
  in
  let warnings = ref [] in
  if not start_ok then
    warnings :=
      Printf.sprintf "start_commit %s not found"
        epoch.Chronicle_types.start_commit
      :: !warnings;
  if not end_ok then
    warnings :=
      Printf.sprintf "end_commit %s not found"
        epoch.Chronicle_types.end_commit
      :: !warnings;
  if not file_range_check && key_paths <> [] then
    warnings := "some key_files not in commit range" :: !warnings;
  let rfc_invalid =
    List.filter (fun (_, valid) -> not valid)
      (List.combine epoch.Chronicle_types.rfc_refs rfc_refs_valid)
    |> List.map (fun (r, _) -> r)
  in
  if rfc_invalid <> [] then
    warnings :=
      Printf.sprintf "missing RFC files: %s"
        (String.concat ", " rfc_invalid)
      :: !warnings;
  let verification_score =
    compute_score ~sha_check ~file_range_check ~rfc_refs_valid
  in
  let is_valid = sha_check && file_range_check in
  { epoch_id = epoch.Chronicle_types.id
  ; is_valid
  ; sha_check
  ; file_range_check
  ; rfc_refs_valid
  ; verification_score
  ; warnings = List.rev !warnings
  }
