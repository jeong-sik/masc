(** Generate the Board identity-field mirror from TOML declarations.

    The TOML files are the source of truth.  Dune passes the declared source
    files explicitly, so this action does not depend on a sandbox working
    directory.  A missing, extra, or malformed Board declaration is an error.
*)
let ( let* ) = Result.bind

let board_prefix = "masc_board_"
let toml_suffix = ".toml"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let length = in_channel_length ic in
      really_input_string ic length)
;;

let constructor_name = function
  | Tool_name.Board_name.Board_post -> "Board_post"
  | Tool_name.Board_name.Board_post_update -> "Board_post_update"
  | Tool_name.Board_name.Board_list -> "Board_list"
  | Tool_name.Board_name.Board_post_get -> "Board_post_get"
  | Tool_name.Board_name.Board_comment -> "Board_comment"
  | Tool_name.Board_name.Board_vote -> "Board_vote"
  | Tool_name.Board_name.Board_stats -> "Board_stats"
  | Tool_name.Board_name.Board_search -> "Board_search"
  | Tool_name.Board_name.Board_comment_vote -> "Board_comment_vote"
  | Tool_name.Board_name.Board_reaction -> "Board_reaction"
  | Tool_name.Board_name.Board_profile -> "Board_profile"
  | Tool_name.Board_name.Board_hearths -> "Board_hearths"
  | Tool_name.Board_name.Board_curation_read -> "Board_curation_read"
  | Tool_name.Board_name.Board_curation_submit -> "Board_curation_submit"
  | Tool_name.Board_name.Board_delete -> "Board_delete"
  | Tool_name.Board_name.Board_cleanup -> "Board_cleanup"
  | Tool_name.Board_name.Board_sub_board_create -> "Board_sub_board_create"
  | Tool_name.Board_name.Board_sub_board_list -> "Board_sub_board_list"
  | Tool_name.Board_name.Board_sub_board_get -> "Board_sub_board_get"
  | Tool_name.Board_name.Board_sub_board_update -> "Board_sub_board_update"
  | Tool_name.Board_name.Board_sub_board_delete -> "Board_sub_board_delete"
;;

let input_files () =
  let rec collect index acc =
    if index = Array.length Sys.argv
    then List.rev acc
    else collect (index + 1) (Sys.argv.(index) :: acc)
  in
  collect 1 []
;;

let board_name_of_file path =
  let file = Filename.basename path in
  if
    not
      (String.starts_with ~prefix:board_prefix file
       && String.ends_with ~suffix:toml_suffix file)
  then None
  else
    let name =
      String.sub file 0 (String.length file - String.length toml_suffix)
    in
    Tool_name.Board_name.of_string name
;;

let validate_file_set files =
  let unknown =
    List.filter_map
      (fun path ->
        match board_name_of_file path with
        | Some _ -> None
        | None -> Some (Filename.basename path))
      files
  in
  if unknown <> []
  then Error (Printf.sprintf "unknown Board TOML file(s): %s" (String.concat ", " unknown))
  else
    let expected =
      Tool_name.Board_name.all
      |> List.map Tool_name.Board_name.to_string
      |> List.sort String.compare
    in
    let actual =
      files
      |> List.map (fun path ->
        let file = Filename.basename path in
        String.sub file 0 (String.length file - String.length toml_suffix))
      |> List.sort String.compare
    in
    if expected <> actual
    then
      Error
        (Printf.sprintf
           "Board TOML set does not match Tool_name.Board_name.all (expected %d, found %d)"
           (List.length expected)
           (List.length actual))
    else Ok ()
;;

let load_declarations files =
  let* () =
    if files = []
    then Error "no Board TOML files were passed"
    else validate_file_set files
  in
  let path_for_board board =
    List.find_opt
      (fun path ->
        match board_name_of_file path with
        | Some candidate -> candidate = board
        | None -> false)
      files
  in
  let rec load acc = function
    | [] -> Ok (List.rev acc)
    | board :: rest ->
      let name = Tool_name.Board_name.to_string board in
      let* path =
        match path_for_board board with
        | Some path -> Ok path
        | None -> Error (Printf.sprintf "missing TOML for %s" name)
      in
      let* declaration =
        match Tool_definition_toml.load ~name ~contents:(read_file path) with
        | Ok loaded -> Ok loaded
        | Error message -> Error (Printf.sprintf "%s: %s" path message)
      in
      load ((board, declaration.Tool_definition_toml.identity_fields) :: acc) rest
  in
  load [] Tool_name.Board_name.all
;;

let render_fields fields =
  "[" ^ String.concat "; " (List.map (Printf.sprintf "%S") fields) ^ "]"
;;

let () =
  match load_declarations (input_files ()) with
  | Error message ->
    Printf.eprintf "gen_board_tool_registry: %s\n" message;
    exit 1
  | Ok declarations ->
    print_endline "(* Generated from config/tools/masc_board_*.toml. Do not edit. *)";
    print_endline "let identity_fields_for_board_name = function";
    List.iter
      (fun (board, fields) ->
        Printf.printf
          "  | Tool_name.Board_name.%s -> %s\n"
          (constructor_name board)
          (render_fields fields))
      declarations;
    print_endline ";;"
