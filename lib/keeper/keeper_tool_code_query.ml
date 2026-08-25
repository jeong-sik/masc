(** See [keeper_tool_code_query.mli]. *)

(* The name lives in config/tools/keeper_code_query.toml and reaches here
   through the schema, so the tool cannot answer to a name the definition does
   not declare. *)
let tool_name = (Tool_schemas_code_query.schema : Masc_domain.tool_schema).name

let ( let* ) = Result.bind
let ok ~start_time data = Tool_result.make_ok ~tool_name:tool_name ~start_time ~data ()

let refusal ~start_time message =
  Tool_result.make_err
    ~tool_name:tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let runtime_failure ~start_time message =
  Tool_result.make_err
    ~tool_name:tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let required_string args key =
  match Json_util.get_string args key with
  | Some value ->
    (match String_util.trim_nonempty value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s must not be blank" key))
  | None -> Error (Printf.sprintf "%s is required" key)
;;

(* [Grep] and [Read] number lines from 1 and so does this tool; LSP numbers
   from 0. The conversion is here so the Keeper never has to hold both. *)
let required_one_based args key =
  match Json_util.get_int args key with
  | Some value when value >= 1 -> Ok (value - 1)
  | Some value -> Error (Printf.sprintf "%s is counted from 1, got %d" key value)
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let optional_occurrence args =
  match Json_util.get_int args "occurrence" with
  | None -> Ok 1
  | Some value when value >= 1 -> Ok value
  | Some value -> Error (Printf.sprintf "occurrence is counted from 1, got %d" value)
;;

let question_of args =
  let* raw = required_string args "question" in
  match Lsp_questions.question_of_string raw with
  | Some (Lsp_questions.Definition as question) | Some (Lsp_questions.Hover as question) ->
    Ok question
  | Some Lsp_questions.References ->
    (* Measured on this tree as answering only the opened file's occurrences,
       so it is refused by name rather than answered short (#30504). *)
    Error
      "references is not answered here: measured on this repository it returns only the \
       occurrences in the file it was given. Use Grep for where a name is used."
  | None -> Error (Printf.sprintf "question must be definition or hover, got %S" raw)
;;

(* The line as the file holds it, so the column search below is over the same
   bytes the language server will be given. *)
let line_of_file ~path ~line_index =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error reason -> Error (Printf.sprintf "cannot read %s: %s" path reason)
  | contents ->
    let lines = String.split_on_char '\n' contents in
    (match List.nth_opt lines line_index with
     | Some line -> Ok line
     | None ->
       Error
         (Printf.sprintf
            "%s has %d lines, so line %d is past its end"
            path
            (List.length lines)
            (line_index + 1)))
;;

(* Finding which column a name sits in is not parsing — the language server
   still decides what the name means. RFC §3.4 rejects deriving the position
   from a pattern; this derives it from the literal name the caller named. *)
let columns_of ~line ~symbol =
  let needle = String.length symbol in
  let rec scan from acc =
    if from + needle > String.length line
    then List.rev acc
    else if String.equal (String.sub line from needle) symbol
    then scan (from + 1) (from :: acc)
    else scan (from + 1) acc
  in
  if needle = 0 then [] else scan 0 []
;;

let column_of ~line ~symbol ~occurrence ~line_number =
  match columns_of ~line ~symbol with
  | [] ->
    Error
      (Printf.sprintf
         "%S is not on line %d, which reads: %s"
         symbol
         line_number
         (String.trim line))
  | columns ->
    (match List.nth_opt columns (occurrence - 1) with
     | Some column -> Ok column
     | None ->
       Error
         (Printf.sprintf
            "%S occurs %d time(s) on line %d, so there is no occurrence %d"
            symbol
            (List.length columns)
            line_number
            occurrence))
;;

let language_of ~path =
  match Lsp_process_manager.language_of_path path with
  | Some language -> Ok language
  | None ->
    Error
      (Printf.sprintf
         "no language server covers %s; %s"
         (Filename.extension path)
         "this answers about .ml, .mli, .ts, .tsx, .js, .jsx, .py, .rs and .go")
;;

let project_root_of ~language ~path ~boundary =
  match Lsp_project_root.resolve ~language ~file:path ~boundary with
  | Lsp_project_root.Project_root root -> Ok root
  | Lsp_project_root.No_project_root { markers; _ } ->
    Error
      (Printf.sprintf
         "%s is in the workspace but not inside a project: no %s above it. A language \
          server rooted at the workspace would answer about unrelated trees."
         path
         (String.concat " or " markers))
  | Lsp_project_root.Outside_boundary { boundary; _ } ->
    Error (Printf.sprintf "%s resolved outside the workspace root %s" path boundary)
;;

(* A definition often lands outside the Keeper's workspace — the standard
   library, an opam package. Saying which side it fell on beats a path the
   Keeper cannot open and is not told why. *)
let location_json ~boundary (location : Lsp_questions.location) =
  (* Both sides are canonicalized before they are compared, the way
     [Lsp_project_root] does it: the boundary comes from the keeper's meta and
     the answer comes back from the language server, and [/var] and
     [/private/var] are one directory that these two spell differently. Without
     this a file plainly inside the workspace is reported as outside it. *)
  let boundary = Fs_compat.realpath_lenient boundary in
  let answered = Fs_compat.realpath_lenient location.Lsp_questions.path in
  let prefix = boundary ^ Filename.dir_sep in
  let inside = String.starts_with ~prefix answered in
  let shown =
    if inside
    then String.sub answered (String.length prefix) (String.length answered - String.length prefix)
    else answered
  in
  `Assoc
    [ "path", `String shown
    ; "in_workspace", `Bool inside
    ; "line", `Int (location.Lsp_questions.line + 1)
    ; "character", `Int (location.Lsp_questions.character + 1)
    ]
;;

let answer_json ~boundary ~question = function
  | Lsp_questions.Locations locations ->
    `Assoc
      [ "question", `String (Lsp_questions.string_of_question question)
      ; "locations", `List (List.map (location_json ~boundary) locations)
      ]
  | Lsp_questions.Hover_text text ->
    `Assoc
      [ "question", `String (Lsp_questions.string_of_question question)
      ; ( "text"
        , match text with
          | Some text -> `String text
          | None -> `Null )
    ]
;;

let handle ~config ~meta ~start_time ~args =
  let boundary = Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta in
  let requested =
    let* question = question_of args in
    let* raw_path = required_string args "path" in
    let* line_index = required_one_based args "line" in
    let* symbol = required_string args "symbol" in
    let* occurrence = optional_occurrence args in
    Ok (question, raw_path, line_index, symbol, occurrence)
  in
  match requested with
  | Error message -> refusal ~start_time message
  | Ok (question, raw_path, line_index, symbol, occurrence) ->
    (* The sandbox bounds the question before a language server sees the path,
       and the refusal names the path the Keeper gave (RFC §2). *)
    let resolved =
      Keeper_alerting_path.resolve_keeper_read_path
        ~config
        ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
        ~raw_path
    in
    (match resolved with
     | Error rejection ->
       refusal
         ~start_time
         (Printf.sprintf
            "%s: %s"
            raw_path
            (Keeper_alerting_path.rejection_to_user_message rejection))
     | Ok path ->
       let prepared =
         let* language = language_of ~path in
         let* line = line_of_file ~path ~line_index in
         let* character =
           column_of ~line ~symbol ~occurrence ~line_number:(line_index + 1)
         in
         let* workspace_root = project_root_of ~language ~path ~boundary in
         Ok (language, workspace_root, character)
       in
       (match prepared with
        | Error message -> refusal ~start_time message
        | Ok (language, workspace_root, character) ->
          (match Lsp_turn_pool.get_opt () with
           | None ->
             refusal
               ~start_time
               "a language server is only available inside a keeper turn"
           | Some pool ->
             (match
                Lsp_questions.ask
                  pool
                  ~language
                  ~workspace_root
                  ~path
                  ~line:line_index
                  ~character
                  ~question
              with
              | Ok answer -> ok ~start_time (answer_json ~boundary ~question answer)
              | Error error ->
                refusal ~start_time (Format.asprintf "%a" Lsp_questions.pp_error error)))))
;;

let dispatch ~config ~meta ~name ~args : Tool_result.result option =
  if not (String.equal name tool_name)
  then None
  else (
    let start_time = Time_compat.now () in
    try Some (handle ~config ~meta ~start_time ~args) with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
      Some
        (runtime_failure
           ~start_time
           (Printf.sprintf "code query failed: %s" (Printexc.to_string exn))))
;;
