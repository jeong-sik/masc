(** Source-level guard for provider cascade-prefix ownership.

    [Provider_adapter] is the boundary that owns provider prefix fields and
    provider:model label construction. Other library modules should call its
    helpers instead of reaching into the adapter record or rebuilding labels. *)

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

let is_identifier_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
  | _ -> false
;;

let contains_source_token ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0
  then true
  else if needle_len > haystack_len
  then false
  else (
    let boundary_before idx = idx = 0 || not (is_identifier_char haystack.[idx - 1]) in
    let boundary_after idx =
      idx >= haystack_len || not (is_identifier_char haystack.[idx])
    in
    let rec loop idx =
      if idx + needle_len > haystack_len
      then false
      else if String.equal (String.sub haystack idx needle_len) needle
              && boundary_before idx
              && boundary_after (idx + needle_len)
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
  let marker path = Filename.concat path "lib/provider_adapter.ml" in
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

let is_provider_adapter_source = function
  | "lib/provider_adapter.ml" | "lib/provider_adapter.mli" -> true
  | _ -> false
;;

let owns_non_llm_adapter_record = function
  | "lib/voice/voice_runtime_overlay.ml" -> true
  | _ -> false
;;

let adapter_record_fields =
  [ "canonical_name"
  ; "runtime_kind"
  ; "auth_mode"
  ; "aliases"
  ; "spawn_key"
  ; "cascade_prefix"
  ; "default_voice"
  ; "endpoint_url"
  ; "default_model_id"
  ; "model_policy"
  ; "tool_policy"
  ; "telemetry_policy"
  ]
;;

let adapter_record_field_violation line =
  adapter_record_fields
  |> List.find_map (fun field ->
    let via_local = "adapter." ^ field in
    let via_module = ".Provider_adapter." ^ field in
    if contains_source_token ~needle:via_local line
       || contains_source_token ~needle:via_module line
    then Some field
    else None)
;;

let manual_provider_model_label_violation line =
  List.find_opt
    (fun needle -> contains ~needle line)
    [ "provider ^ \":\" ^ model"
    ; "run.provider ^ \":\" ^ run.model"
    ; "provider_key ^ \":\""
    ; "prefix ^ model"
    ]
;;

let line_violation line =
  if contains_source_token ~needle:".Provider_adapter.cascade_prefix" line
  then Some "direct adapter record field access"
  else if contains ~needle:".cascade_prefix ^" line
  then Some "manual cascade_prefix label concatenation"
  else if
    contains ~needle:"Provider_adapter.cascade_prefix_of_adapter" line
    && contains ~needle:"^" line
  then Some "manual label concatenation after prefix helper"
  else (
    match adapter_record_field_violation line with
    | Some field -> Some ("external adapter record field access: " ^ field)
    | None ->
      (match manual_provider_model_label_violation line with
       | Some _ -> Some "manual provider:model label construction"
       | None -> None))
;;

let provider_prefix_boundary_has_no_external_leaks () =
  let root = repo_root () in
  let lib_dir = source_path root "lib" in
  let violations =
    ocaml_sources_under lib_dir
    |> List.filter_map (fun path ->
      let rel = relative_path ~root path in
      if is_provider_adapter_source rel || owns_non_llm_adapter_record rel
      then None
      else (
        read_file path
        |> String.split_on_char '\n'
        |> List.mapi (fun idx line ->
          match line_violation line with
          | Some reason -> Some (Printf.sprintf "%s:%d %s" rel (idx + 1) reason)
          | None -> None)
        |> List.filter_map Fun.id
        |> function
        | [] -> None
        | xs -> Some xs))
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
    [ ( "source"
      , [ Alcotest.test_case
            "external modules use Provider_adapter prefix helpers"
            `Quick
            provider_prefix_boundary_has_no_external_leaks
        ] )
    ]
;;
