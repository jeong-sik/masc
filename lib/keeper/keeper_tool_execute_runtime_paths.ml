open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let replace_all_substrings ~needle ~replacement text =
  let needle_len = String.length needle in
  if needle_len = 0 || not (String_util.contains_substring text needle) then text
  else
    let text_len = String.length text in
    let buf = Buffer.create text_len in
    let rec loop i =
      if i >= text_len then ()
      else if i + needle_len <= text_len
              && String.sub text i needle_len = needle then (
        Buffer.add_string buf replacement;
        loop (i + needle_len))
      else (
        Buffer.add_char buf text.[i];
        loop (i + 1))
    in
    loop 0;
    Buffer.contents buf

let rewrite_turn_runtime_paths_to_host
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      text
  =
  replace_all_substrings
    ~needle:(Keeper_sandbox.container_root meta.name)
    ~replacement:
      (Keeper_sandbox.host_root_abs_of_meta ~config meta
       |> Keeper_alerting_path.strip_trailing_slashes)
    text

let rewrite_docker_host_paths_to_container
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      text
  =
  let raw_host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let normalized_host_root =
    raw_host_root
    |> Keeper_alerting_path.normalize_path_for_check
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let container_root =
    Keeper_sandbox.container_root meta.name
    |> Keeper_alerting_path.strip_trailing_slashes
  in
  let rewritten =
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:raw_host_root ~container_root text
  in
  if String.equal raw_host_root normalized_host_root then rewritten
  else
    Keeper_sandbox_runtime.rewrite_host_root_to_container_root
      ~host_root:normalized_host_root ~container_root rewritten
