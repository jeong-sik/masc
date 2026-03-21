(** Episode flush and list handlers.
    Extracted from tool_inline_dispatch.ml to reduce file size. *)

let handle_episode_flush ~config ~arguments ~(state : Mcp_server.server_state) ~sw =
  let arg_get_int key default = Safe_ops.json_int ~default key arguments in
  let arg_get_bool key default = Safe_ops.json_bool ~default key arguments in
  let limit = arg_get_int "limit" 10 in
  let dry_run = arg_get_bool "dry_run" false in
  let base_path = config.Room_utils.base_path in
  let pending_dir = Filename.concat base_path ".masc/pending_episodes" in

  let pending_files =
    try
      Sys.readdir pending_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.sort String.compare
      |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
    with Sys_error _ -> []
  in

  if dry_run then begin
    let response = `Assoc [
      ("dry_run", `Bool true);
      ("pending", `Int (List.length pending_files));
      ("would_flush", `List (List.map (fun f -> `String f) pending_files));
    ] in
    Some (true, Yojson.Safe.pretty_to_string response)
  end else begin
    let flushed = ref 0 in
    let failed = ref 0 in


    List.iter (fun file ->
      let file_path = Filename.concat pending_dir file in
      try
        let content = Fs_compat.load_file file_path in
        let json = Yojson.Safe.from_string content in
        let module U = Yojson.Safe.Util in
        let ep_id = match Json_util.get_string json "ep_id" with Some v -> v | None -> raise Not_found in

        (* Episode DB save removed — Jiphyeon module retired (#2135).
           Episodes are still persisted as JSONL files. *)
        ignore (sw, state);
        Log.Misc.info "[EPISODE/FILE] Episode %s recorded to JSONL (DB save disabled)" ep_id;

        let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
        Fs_compat.mkdir_p processed_dir;
        let new_path = Filename.concat processed_dir file in
        Sys.rename file_path new_path;
        Printf.printf "[EPISODE/FLUSH] Processed episode %s -> %s\n%!" ep_id new_path;
        incr flushed
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Misc.error "Failed to flush %s: %s" file (Printexc.to_string exn);
        incr failed
    ) pending_files;

    let remaining =
      try Array.length (Sys.readdir pending_dir) with Sys_error _ -> 0
    in
    let response = `Assoc [
      ("flushed", `Int !flushed);
      ("failed", `Int !failed);
      ("remaining", `Int remaining);
      ("message", `String (Printf.sprintf "Flushed %d episodes (%d failed, %d remaining)" !flushed !failed remaining));
    ] in
    Some (true, Yojson.Safe.pretty_to_string response)
  end

let handle_episode_list ~config ~arguments =
  let arg_get_int key default = Safe_ops.json_int ~default key arguments in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let agent_filter = arg_get_string_opt "agent_name" in
  let gen_filter = match arguments with
    | `Assoc fields -> (match List.assoc_opt "generation" fields with
        | Some (`Int n) -> Some n
        | _ -> None)
    | _ -> None
  in
  let limit = arg_get_int "limit" 20 in
  let base_path = config.Room_utils.base_path in

  let processed_dir = Filename.concat base_path ".masc/processed_episodes" in
  let module U = Yojson.Safe.Util in
  let episodes =
    try
      Sys.readdir processed_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.sort (fun a b -> String.compare b a)
      |> (fun l -> if List.length l > limit then List.filteri (fun i _ -> i < limit) l else l)
      |> List.filter_map (fun file ->
          try
            let path = Filename.concat processed_dir file in
            let content = Fs_compat.load_file path in
            let json = Yojson.Safe.from_string content in
            let ep_agent = U.(json |> member "agent_name" |> to_string) in
            let ep_gen = U.(json |> member "generation" |> to_int) in
            let agent_ok = match agent_filter with None -> true | Some a -> ep_agent = a in
            let gen_ok = match gen_filter with None -> true | Some g -> ep_gen = g in
            if agent_ok && gen_ok then Some json else None
          with
          | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
        )
    with Sys_error _ -> []
  in

  let response = `Assoc [
    ("count", `Int (List.length episodes));
    ("episodes", `List episodes);
  ] in
  Some (true, Yojson.Safe.pretty_to_string response)
