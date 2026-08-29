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
}

let declared_keys =
  [ "id"; "level"; "lang"; "timeout_sec"; "verify"; "prompt"; "description" ]
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
    Ok { id; level; lang; timeout_sec; verify; prompt; description }
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
  let* () = must_exist "workspace directory" (Filename.concat dir "workspace") in
  let* () = must_exist "solution overlay" (Filename.concat dir "solution") in
  let* () = must_exist "verify script" (Filename.concat dir case.verify) in
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
