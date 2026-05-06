type stage_spec =
  { id : string
  ; label : string
  }

type stage_acc =
  { spec : stage_spec
  ; successes : int ref
  ; failures : int ref
  ; keepers : (string, unit) Hashtbl.t
  ; successful_keepers : (string, unit) Hashtbl.t
  ; failed_keepers : (string, unit) Hashtbl.t
  ; latest_ts : float option ref
  }

let stage_specs =
  [ { id = "docker_clone"; label = "Docker git clone with keeper credentials" }
  ; { id = "branch_create"; label = "Feature branch creation" }
  ; { id = "commit"; label = "Git commit" }
  ; { id = "push"; label = "Git push" }
  ; { id = "pr_create"; label = "Draft PR creation" }
  ]
;;

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else if needle_len > text_len
  then false
  else (
    let rec matches_at i j =
      j = needle_len
      || (String.get text (i + j) = String.get needle j
          && matches_at i (j + 1))
    in
    let rec loop i =
      if i + needle_len > text_len
      then false
      else if matches_at i 0 then true
      else loop (i + 1)
    in
    loop 0)
;;

let lower text = String.lowercase_ascii text

let string_field_opt record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let float_field_opt record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`Float value) -> Some value
     | Some (`Int value) -> Some (Float.of_int value)
     | _ -> None)
  | _ -> None
;;

let input_text record =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "input" fields with
     | Some json -> Yojson.Safe.to_string json
     | None -> "")
  | _ -> ""
;;

let record_success = Dashboard_keeper_tool_failure_proof.tool_success_of_record
let output_text = Dashboard_keeper_tool_failure_proof.output_text
let read_records = Dashboard_keeper_tool_failure_proof.read_records
let string_list_json values = `List (List.map (fun value -> `String value) values)

let known_keeper_table keeper_names =
  let table = Hashtbl.create (List.length keeper_names) in
  List.iter
    (fun keeper_name ->
       let keeper_name = String.trim keeper_name in
       if keeper_name <> "" then Hashtbl.replace table keeper_name ())
    keeper_names;
  table
;;

let add_set table value =
  let value = String.trim value in
  if value <> "" then Hashtbl.replace table value ()
;;

let sorted_set table =
  Hashtbl.fold (fun value () acc -> value :: acc) table []
  |> List.sort_uniq String.compare
;;

let update_latest latest ts =
  match !latest with
  | Some previous when previous >= ts -> ()
  | _ -> latest := Some ts
;;

let new_stage spec =
  { spec
  ; successes = ref 0
  ; failures = ref 0
  ; keepers = Hashtbl.create 8
  ; successful_keepers = Hashtbl.create 8
  ; failed_keepers = Hashtbl.create 8
  ; latest_ts = ref None
  }
;;

let init_stages () =
  let table = Hashtbl.create (List.length stage_specs) in
  List.iter (fun spec -> Hashtbl.replace table spec.id (new_stage spec)) stage_specs;
  table
;;

let has_docker_evidence record text =
  string_field_opt record "sandbox_profile" = Some "docker"
  || contains_substring text "\"sandbox_profile\":\"docker\""
  || contains_substring text "\"via\":\"docker\""
;;

let has_git_credentials text = contains_substring text "\"git_creds_enabled\":true"

let stage_ids_for_record record =
  let tool = string_field_opt record "tool" |> Option.value ~default:"" in
  let input = lower (input_text record) in
  let output = lower (output_text record) in
  let text = input ^ "\n" ^ output in
  let docker = has_docker_evidence record text in
  let git_creds = has_git_credentials text in
  let stages = ref [] in
  if docker && git_creds && contains_substring input "git clone"
  then stages := "docker_clone" :: !stages;
  if docker && contains_substring input "git checkout -b"
  then stages := "branch_create" :: !stages;
  if docker && contains_substring input "git commit" then stages := "commit" :: !stages;
  if docker && git_creds && contains_substring input "git push"
  then stages := "push" :: !stages;
  if
    docker
    && git_creds
    && String.equal tool "keeper_pr_create"
  then stages := "pr_create" :: !stages;
  List.rev !stages
;;

let add_record stages record stage_id =
  match Hashtbl.find_opt stages stage_id, string_field_opt record "keeper" with
  | Some stage, Some keeper ->
    let ok = record_success record in
    add_set stage.keepers keeper;
    if ok
    then (
      incr stage.successes;
      add_set stage.successful_keepers keeper)
    else (
      incr stage.failures;
      add_set stage.failed_keepers keeper);
    Option.iter (update_latest stage.latest_ts) (float_field_opt record "ts")
  | _ -> ()
;;

let stage_json stage =
  let latest_fields =
    match !(stage.latest_ts) with
    | None -> [ "latest_ts", `Null; "latest_at", `Null ]
    | Some ts ->
      [ "latest_ts", `Float ts
      ; "latest_at", `String (Masc_domain.iso8601_of_unix_seconds ts)
      ]
  in
  `Assoc
    ([ "id", `String stage.spec.id
     ; "label", `String stage.spec.label
     ; "passed", `Bool (!(stage.successes) > 0)
     ; "successes", `Int !(stage.successes)
     ; "failures", `Int !(stage.failures)
     ; "keepers", string_list_json (sorted_set stage.keepers)
     ; "successful_keepers", string_list_json (sorted_set stage.successful_keepers)
     ; "failed_keepers", string_list_json (sorted_set stage.failed_keepers)
     ]
     @ latest_fields)
;;

let json ?window_hours ~n ~keeper_names () =
  let known_keepers = known_keeper_table keeper_names in
  let stages = init_stages () in
  read_records ?window_hours ~n ()
  |> List.iter (fun record ->
    match string_field_opt record "keeper" with
    | Some keeper when Hashtbl.mem known_keepers keeper ->
      stage_ids_for_record record |> List.iter (add_record stages record)
    | _ -> ());
  let stage_rows =
    stage_specs
    |> List.map (fun spec ->
      Hashtbl.find_opt stages spec.id |> Option.value ~default:(new_stage spec))
  in
  let passed =
    stage_rows |> List.filter (fun stage -> !(stage.successes) > 0) |> List.length
  in
  let failed_observed =
    stage_rows |> List.filter (fun stage -> !(stage.failures) > 0) |> List.length
  in
  let missing = List.length stage_rows - passed in
  let status =
    if missing = 0
    then "pass"
    else if passed > 0 || failed_observed > 0
    then "warn"
    else "fail"
  in
  let observed_keepers =
    stage_rows
    |> List.concat_map (fun stage -> sorted_set stage.successful_keepers)
    |> List.sort_uniq String.compare
  in
  let missing_keepers =
    keeper_names
    |> List.filter (fun keeper_name ->
      not (List.exists (String.equal keeper_name) observed_keepers))
    |> List.sort_uniq String.compare
  in
  `Assoc
    [ "id", `String "docker_git_pr_workflow"
    ; "label", `String "Docker credential git-to-PR workflow"
    ; "status", `String status
    ; ( "summary"
      , `String
          (Printf.sprintf
             "%d/%d Docker credential git-to-PR stages have keeper-originated success \
              evidence; %d stages have failure evidence"
             passed
             (List.length stage_rows)
             failed_observed) )
    ; ( "required_tools"
      , string_list_json [ "keeper_bash"; "keeper_shell"; "keeper_pr_create" ] )
    ; "passing_tools", `List []
    ; "weak_tools", `List []
    ; "missing_tools", `List []
    ; ( "keeper_evidence"
      , `Assoc
          [ "provenance_scope", `String "known_keeper_tool_call_log"
          ; "keeper_count", `Int (List.length keeper_names)
          ; "observed_keepers", string_list_json observed_keepers
          ; "missing_keepers", string_list_json missing_keepers
          ; "stages", `List (List.map stage_json stage_rows)
          ] )
    ; ( "evidence_refs"
      , `List
          [ `Assoc
              [ "kind", `String "store"
              ; "id", `String "keeper_tool_call_log"
              ; "value", `String "Keeper_tool_call_log.read_recent/read_window"
              ]
          ] )
    ; ( "next_action"
      , `String
          "Repair keeper GitHub credential push/PR creation, then rerun a Docker clone \
           -> branch -> commit -> push -> draft PR workflow until every stage has \
           keeper-originated success evidence." )
    ]
;;
