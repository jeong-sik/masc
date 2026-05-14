(** Source-level guard for provider runtime-prefix ownership.

    OAS runtime bindings own provider ids and provider:model label
    construction. MASC code should not rebuild labels by reaching into legacy
    adapter-like records. *)

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0
  then true
  else if needle_len > haystack_len
  then false
  else (
    let rec loop idx =
      if idx + needle_len > haystack_len
      then false
      else if String.equal (String.sub haystack idx needle_len) needle
      then true
      else loop (idx + 1)
    in
    loop 0)
;;

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let repo_root () =
  let marker path = Filename.concat path "dune-project" in
  let has_marker path = Sys.file_exists (marker path) in
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_marker root -> root
  | _ ->
    let rec ascend path =
      if has_marker path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then path else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let is_directory path =
  try Sys.is_directory path with
  | Sys_error _ -> false
;;

let is_ocaml_source path =
  Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli"
;;

let rec ocaml_sources_under dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if is_directory path
    then ocaml_sources_under path
    else if is_ocaml_source path
    then [ path ]
    else [])
;;

let source_path root relative = Filename.concat root relative

let relative_path ~root path =
  let root_prefix = root ^ Filename.dir_sep in
  let root_len = String.length root_prefix in
  if String.length path >= root_len
     && String.equal (String.sub path 0 root_len) root_prefix
  then String.sub path root_len (String.length path - root_len)
  else path
;;

let line_violation line =
  if contains ~needle:".cascade_prefix ^" line
  then Some "manual cascade_prefix label concatenation"
  else None
;;

let provider_prefix_boundary_has_no_external_leaks () =
  let root = repo_root () in
  let lib_dir = source_path root "lib" in
  let violations =
    ocaml_sources_under lib_dir
    |> List.filter_map (fun path ->
      let rel = relative_path ~root path in
      read_file path
      |> String.split_on_char '\n'
      |> List.mapi (fun idx line ->
        match line_violation line with
        | Some reason -> Some (Printf.sprintf "%s:%d %s" rel (idx + 1) reason)
        | None -> None)
      |> List.filter_map Fun.id
      |> function
      | [] -> None
      | xs -> Some xs)
    |> List.concat
  in
  match violations with
  | [] -> ()
  | xs ->
    Alcotest.failf
      "provider prefix boundary leaks:\n%s"
      (String.concat "\n" xs)
;;

let () =
  Alcotest.run
    "provider_prefix_boundary"
    [
      ( "source"
      , [
          Alcotest.test_case
            "external modules use Provider_adapter prefix helpers"
            `Quick
            provider_prefix_boundary_has_no_external_leaks;
        ] );
    ]
;;
