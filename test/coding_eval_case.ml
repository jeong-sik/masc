(** Coding-eval case declarations (RFC-0396 W1).

    One case is one directory under [benchmarks/coding/cases/<id>/] holding
    [case.json], a [workspace/] the verify script fails on, a [solution/]
    overlay that turns verify green, and the verify script itself. The only
    pass verdict is that script exiting 0 against a workspace copy
    (RFC-0396 D2); this module carries the declaration and never judges. *)

type level =
  | L1
  | L2
  | L3

let level_to_string = function
  | L1 -> "L1"
  | L2 -> "L2"
  | L3 -> "L3"
;;

let level_of_string_opt = function
  | "L1" -> Some L1
  | "L2" -> Some L2
  | "L3" -> Some L3
  | _ -> None
;;

type t = {
  id : string;
  level : level;
  lang : string;
  timeout_sec : int;
  verify : string;
  prompt : string;
  description : string;
  (* The protected test oracle: files the harness restores from the case's
     canonical [workspace/] before running verify, so a run is graded against
     the original test rather than whatever the agent left in its workspace
     (SWE-bench keeps test files fixed for the same reason). Defaults to
     ["check.sh"] when the key is absent, which is the corpus convention. *)
  test_files : string list;
  (* Optional PASS_TO_PASS guard: a case-relative script that must exit 0 both
     on the pristine workspace and after the candidate. It catches a run that
     makes verify green while breaking behaviour that already worked -- the
     regression axis SWE-bench measures with its PASS_TO_PASS test set. Absent
     means the case declares nothing to preserve. *)
  regression : string option;
  (* Optional build probe: a case-relative script that must exit 0 for the
     candidate's edit to count as "builds". A red build separates a
     non-compiling edit (Build_failed) from a compiling-but-wrong one
     (Wrong_solution) in the failure taxonomy. Absent means verify is the only
     oracle the case runs. *)
  build : string option;
}

let default_test_files = [ "check.sh" ]

let declared_keys =
  [ "id"
  ; "level"
  ; "lang"
  ; "timeout_sec"
  ; "verify"
  ; "prompt"
  ; "description"
  ; "test_files"
  ; "regression"
  ; "build"
  ]
;;

let of_json json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let unknown =
      fields
      |> List.filter (fun (key, _) -> not (List.mem key declared_keys))
      |> List.map fst
    in
    let* () =
      if unknown = []
      then Ok ()
      else
        Error
          (Printf.sprintf
             "case.json has undeclared key(s): %s. Valid: %s"
             (String.concat ", " unknown)
             (String.concat ", " declared_keys))
    in
    let str name =
      match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ -> Error (Printf.sprintf "%s must be a non-empty string" name)
      | None -> Error (Printf.sprintf "%s is missing" name)
    in
    let* id = str "id" in
    let* level_raw = str "level" in
    let* level =
      match level_of_string_opt level_raw with
      | Some level -> Ok level
      | None ->
        Error (Printf.sprintf "level must be one of [L1, L2, L3], got %S" level_raw)
    in
    let* lang = str "lang" in
    let* timeout_sec =
      match List.assoc_opt "timeout_sec" fields with
      | Some (`Int seconds) when seconds > 0 -> Ok seconds
      | Some _ -> Error "timeout_sec must be a positive integer"
      | None -> Error "timeout_sec is missing"
    in
    let* verify = str "verify" in
    let* () =
      if Filename.is_relative verify
         && not (List.mem ".." (String.split_on_char '/' verify))
      then Ok ()
      else Error "verify must be a case-relative path without .."
    in
    let* prompt = str "prompt" in
    let* description = str "description" in
    let* test_files =
      match List.assoc_opt "test_files" fields with
      | None -> Ok default_test_files
      | Some (`List items) ->
        let rec collect acc = function
          | [] -> Ok (List.rev acc)
          | `String value :: rest when String.trim value <> "" ->
            if Filename.is_relative value
               && not (List.mem ".." (String.split_on_char '/' value))
            then collect (value :: acc) rest
            else
              Error
                (Printf.sprintf
                   "test_files entry %S must be a workspace-relative path \
                    without .."
                   value)
          | _ -> Error "test_files entries must be non-empty strings"
        in
        (match collect [] items with
         | Ok [] ->
           Error
             "test_files must not be empty (omit the key for the default \
              [\"check.sh\"])"
         | other -> other)
      | Some _ -> Error "test_files must be an array of strings"
    in
    let* regression =
      match List.assoc_opt "regression" fields with
      | None | Some `Null -> Ok None
      | Some (`String value) when String.trim value <> "" ->
        if Filename.is_relative value
           && not (List.mem ".." (String.split_on_char '/' value))
        then Ok (Some value)
        else Error "regression must be a case-relative path without .."
      | Some _ -> Error "regression must be a non-empty string or null"
    in
    let* build =
      match List.assoc_opt "build" fields with
      | None | Some `Null -> Ok None
      | Some (`String value) when String.trim value <> "" ->
        if Filename.is_relative value
           && not (List.mem ".." (String.split_on_char '/' value))
        then Ok (Some value)
        else Error "build must be a case-relative path without .."
      | Some _ -> Error "build must be a non-empty string or null"
    in
    Ok
      { id
      ; level
      ; lang
      ; timeout_sec
      ; verify
      ; prompt
      ; description
      ; test_files
      ; regression
      ; build
      }
  | _ -> Error "case.json must be a JSON object"
;;

let load_case ~dir =
  let ( let* ) = Result.bind in
  let case_path = Filename.concat dir "case.json" in
  let* json =
    match Yojson.Safe.from_file case_path with
    | json -> Ok json
    | exception Sys_error message -> Error message
    | exception Yojson.Json_error message -> Error message
  in
  let* case = of_json json in
  let* () =
    if String.equal case.id (Filename.basename dir)
    then Ok ()
    else
      Error
        (Printf.sprintf
           "case id %S does not match its directory %S"
           case.id
           (Filename.basename dir))
  in
  let must_exist what path =
    if Sys.file_exists path
    then Ok ()
    else Error (Printf.sprintf "%s missing: %s" what path)
  in
  let workspace_dir = Filename.concat dir "workspace" in
  let solution_dir = Filename.concat dir "solution" in
  let* () = must_exist "workspace directory" workspace_dir in
  let* () = must_exist "solution overlay" solution_dir in
  let* () = must_exist "verify script" (Filename.concat dir case.verify) in
  let* () =
    match case.regression with
    | None -> Ok ()
    | Some regression ->
      must_exist "regression script" (Filename.concat dir regression)
  in
  let* () =
    match case.build with
    | None -> Ok ()
    | Some build -> must_exist "build script" (Filename.concat dir build)
  in
  (* Each protected test oracle must exist in the canonical workspace (so the
     harness has a pristine copy to restore), and the solution overlay must not
     contain it -- a solution that ships its own test file would let the graded
     oracle be the candidate's, not the case author's. *)
  let* () =
    List.fold_left
      (fun acc test_file ->
         let* () = acc in
         let* () =
           must_exist
             (Printf.sprintf "protected test oracle %s" test_file)
             (Filename.concat workspace_dir test_file)
         in
         if Sys.file_exists (Filename.concat solution_dir test_file)
         then
           Error
             (Printf.sprintf
                "solution overlay must not contain the protected test oracle \
                 %s (the graded test is the case's, not the candidate's)"
                test_file)
         else Ok ())
      (Ok ())
      case.test_files
  in
  Ok case
;;

let load_cases ~cases_dir =
  match Sys.readdir cases_dir with
  | entries ->
    let dirs =
      Array.to_list entries
      |> List.filter (fun entry -> Sys.is_directory (Filename.concat cases_dir entry))
      |> List.sort String.compare
    in
    let results =
      List.map
        (fun entry ->
           let dir = Filename.concat cases_dir entry in
           Result.map_error
             (fun message -> Printf.sprintf "%s: %s" entry message)
             (load_case ~dir))
        dirs
    in
    let errors =
      List.filter_map (function Error message -> Some message | Ok _ -> None) results
    in
    if errors <> []
    then Error (String.concat "; " errors)
    else Ok (List.filter_map Result.to_option results)
  | exception Sys_error message -> Error message
;;
