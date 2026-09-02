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
  | Some question -> Ok question
  | None ->
    Error (Printf.sprintf "question must be definition, hover or references, got %S" raw)
;;

(* The guard lives with the question type, so the REST route cannot answer a
   references question this tool would refuse. *)
let reference_index_ready = Lsp_questions.reference_index_ready

(* The position arithmetic lives in [Lsp_position] — one owner for this
   tool and the REST question route, so the two surfaces cannot disagree
   about where a name sits. *)
let line_of_file = Lsp_position.line_of_file
let column_of = Lsp_position.column_of
let language_of = Lsp_position.language_of
let project_root_of = Lsp_position.project_root_of

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
        ~sandbox_roots:(Keeper_alerting_path.sandbox_roots ~meta)
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
         let* () = reference_index_ready ~question ~language ~project_root:workspace_root in
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
