(** Chronicle_ingest — git log → candidate epoch pipeline.
    Pure OCaml, no LLM dependency.

    Ingest reads git history, extracts commit metadata, groups commits
    into candidate epochs by an explicit time window, and produces
    {!candidate_epoch} values ready for the synthesize phase.

    @since Project Chronicle Phase 2 *)

(** Git capture hook for test isolation. *)
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
      (Fd_accountant.observe ~kind:Sandbox_exec (fun () ->
         Masc_exec.Exec_gate.run_argv_with_status
           ~actor:(Masc_exec.Agent_id.of_string "system/chronicle_ingest")
           ~raw_source
           ~summary:"chronicle git log ingestion"
           ~timeout_sec argv))

let run_git_output ~workdir args =
  match
    run_git
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
      ~workdir args
  with
  | Some (Unix.WEXITED 0, output) -> Some output
  | _ -> None

(* --- Parsing --- *)

(** A single commit parsed from git log output. *)
type commit_event =
  { sha : string
  ; parents : string list
  ; author_date : string
  ; subject : string
  ; files : string list
  }
[@@deriving show]

(** A candidate epoch produced by grouping commits.
    Ready for synthesize phase (LLM enrichment). *)
type candidate_epoch =
  { id : string
  ; label : string
  ; start_commit : string
  ; end_commit : string
  ; start_date : string
  ; end_date : string
  ; file_paths : string list
  ; commit_count : int
  }
[@@deriving show]

(* NUL-separated fields: sha\0parents\0date\0subject
   Followed by file names (one per line).
   Commits separated by blank line. *)
let field_sep = Char.chr 0

let parse_git_log raw =
  let commits = String.split_on_char '\n' raw in
  let rec loop commits acc cur_files cur_commit =
    match commits with
    | [] ->
      let ev = acc_commit cur_commit (List.rev cur_files) acc in
      List.rev ev
    | line :: rest ->
      if line = "" then
        let acc = acc_commit cur_commit (List.rev cur_files) acc in
        loop rest acc [] None
      else
        match cur_commit with
        | None ->
          let fields = String.split_on_char field_sep line in
          (match fields with
          | [ sha; parents_raw; date; subject ] ->
            let parents =
              String.split_on_char ' ' (String.trim parents_raw)
              |> List.filter (fun s -> s <> "")
            in
            let commit =
              { sha = String.trim sha
              ; parents
              ; author_date = String.trim date
              ; subject = String.trim subject
              ; files = []
              }
            in
            loop rest acc cur_files (Some commit)
          | _ ->
            (* Malformed header line — skip *)
            loop rest acc cur_files None)
        | Some commit ->
          (* This line is a file path *)
          loop rest acc (line :: cur_files) (Some commit)
  and acc_commit cur files acc =
    match cur with
    | None -> acc
    | Some c -> { c with files } :: acc
  in
  loop commits [] [] None

(* --- Epoch grouping --- *)

(* Group remaining commits by time window (days). *)
let rec group_by_time_window events ~days =
  let rec loop current_group current_date groups remaining =
    match remaining with
    | [] ->
      let groups =
        match current_group with
        | [] -> groups
        | _ -> List.rev current_group :: groups
      in
      List.rev groups
    | ev :: rest ->
      let date = String.sub ev.author_date 0 10 in
      match current_group with
      | [] -> loop [ ev ] date groups rest
      | first :: _ ->
        let first_date = String.sub first.author_date 0 10 in
        if date = first_date || within_days first_date date days then
          loop (ev :: current_group) current_date groups rest
        else
          let groups = List.rev current_group :: groups in
          loop [ ev ] date groups rest
  in
  loop [] "" [] events

and within_days d1 d2 days =
  let parse_date s =
    if String.length s < 10 then None
    else
      match
        ( int_of_string_opt (String.sub s 0 4)
        , int_of_string_opt (String.sub s 5 2)
        , int_of_string_opt (String.sub s 8 2) )
      with
      | Some y, Some m, Some d -> Some (y, m, d)
      | _ -> None
  in
  match (parse_date d1, parse_date d2) with
  | Some (y1, m1, day1), Some (y2, m2, day2) ->
    let to_days y m d = y * 366 + m * 31 + d in
    abs (to_days y1 m1 day1 - to_days y2 m2 day2) <= days
  | _ -> false

(* Build a candidate_epoch from a non-empty group of commits.

   The non-emptiness invariant is encoded in the signature ([first]
   plus a separately-passed [rest]) so callers must produce the head
   from a pattern match rather than rely on a runtime [assert false]
   below the call site. *)
let make_candidate first rest =
  let commits = first :: rest in
  let last = List.fold_left (fun _ ev -> ev) first rest in
  let all_files =
    commits
    |> List.map (fun ev -> ev.files)
    |> List.concat
    |> List.sort_uniq String.compare
  in
    let label =
      let subj = first.subject in
      if String.length subj > 60 then
        String.sub subj 0 57 ^ "..."
      else subj
    in
    let year = String.sub first.author_date 0 4 in
    let short = String.sub first.sha 0 (min 7 (String.length first.sha)) in
    let id = Printf.sprintf "%s-cluster-%s" year short in
    { id
    ; label
    ; start_commit = first.sha
    ; end_commit = last.sha
    ; start_date = String.sub first.author_date 0 10
    ; end_date = String.sub last.author_date 0 10
    ; file_paths = all_files
    ; commit_count = List.length commits
    }

(* --- Public API --- *)

let ingest_raw ~workdir ~from ~to_ =
  let range = Printf.sprintf "%s..%s" from to_ in
  let args =
    [ "log"
    ; "--format=%H%x00%P%x00%aI%x00%s"
    ; "--name-only"
    ; range
    ]
  in
  match run_git_output ~workdir args with
  | None -> []
  | Some raw -> parse_git_log raw

let ingest_since_last ~workdir ~last_commit =
  match run_git_output ~workdir [ "rev-parse"; "HEAD" ] with
  | None -> []
  | Some head ->
    let head = String.trim head in
    if String.equal head last_commit then []
    else ingest_raw ~workdir ~from:last_commit ~to_:head

let group_events ?(time_window_days = 7) events =
  group_by_time_window events ~days:time_window_days
  |> List.filter_map (fun g ->
    match g with
    | [] -> None
    | first :: rest -> Some (make_candidate first rest))
  |> List.sort (fun a b -> String.compare a.start_date b.start_date)

let ingest_range ?(time_window_days = 7) ~workdir ~from ~to_ () =
  let events = ingest_raw ~workdir ~from ~to_ in
  group_events ~time_window_days events

let ingest_since ?(time_window_days = 7) ~workdir ~last_commit () =
  let events = ingest_since_last ~workdir ~last_commit in
  group_events ~time_window_days events
