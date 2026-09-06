(** See [lsp_project_root.mli]. *)

type resolution =
  | Project_root of string
  | No_project_root of
      { file : string
      ; markers : string list
      }
  | Outside_boundary of
      { file : string
      ; boundary : string
      }

let strip_trailing_sep path =
  let sep = Filename.dir_sep in
  let rec strip p =
    if String.length p > String.length sep && Filename.check_suffix p sep
    then strip (Filename.chop_suffix p sep)
    else p
  in
  strip path
;;

let within ~boundary dir =
  String.equal dir boundary
  || String.starts_with ~prefix:(boundary ^ Filename.dir_sep) dir
;;

let resolve ~language ~file ~boundary =
  let canonical_file = Fs_compat.realpath_lenient file in
  let boundary = strip_trailing_sep (Fs_compat.realpath_lenient boundary) in
  let start = Filename.dirname canonical_file in
  if not (within ~boundary start)
  then Outside_boundary { file = canonical_file; boundary }
  else (
    match Lsp_process_manager.root_rule_of_language language with
    | Lsp_process_manager.Boundary_root -> Project_root boundary
    | Lsp_process_manager.Marker_files markers ->
    (* Any marker makes the directory a root, so the nearest directory wins and
       the order within [markers] does not decide anything. *)
    let holds_marker dir =
      List.exists (fun marker -> Sys.file_exists (Filename.concat dir marker)) markers
    in
    let rec walk dir =
      if holds_marker dir
      then Some dir
      else if String.equal dir boundary
      then None
      else (
        let parent = Filename.dirname dir in
        (* [Filename.dirname "/"] is ["/"]. Stopping on the fixed point keeps
           this total even if [within] and the walk ever disagreed. *)
        if String.equal parent dir then None else walk parent)
    in
    (match walk start with
     | Some root -> Project_root root
     | None -> No_project_root { file = canonical_file; markers }))
;;
