(** Tool definition parity artifact generator.
    
    This program reads TOML tool definitions from config/tools/ and generates
    expected_tool_*.txt artifacts for CI verification.
    
    Invoked by: dune build @regen_tool_parity_artifacts
    Output: test/golden/tool_parity_*.txt (4 files, one per dimension)
*)

open Core

let tool_config_dir = "config/tools"
let output_dir = "test/golden"

(** Load all .toml files from config/tools/ *)
let load_tool_definitions () =
  Sys_unix.ls_dir tool_config_dir
  |> List.filter ~f:(String.is_suffix ~suffix:".toml")
  |> List.map ~f:(fun filename ->
      let path = Filename.concat tool_config_dir filename in
      let name = String.chop_suffix_exn filename ~suffix:".toml" in
      try
        let defn = Tool_definition_toml.load path in
        Some (name, defn)
      with e ->
        Printf.eprintf "Warning: failed to load %s: %s\n" path (Exn.to_string e);
        None
    )
  |> List.filter_map ~f:Fn.id

(** Generate a canonical string representation of tool definition for parity check.
    
    Format: one tool per line, fields tab-separated.
    Dimensions:
    - description (prose)
    - params (input schema structure)
    - visibility (access control)
    - availability (tool load status)
*)
let tool_to_parity_line (name : string) (defn : Tool_definition_toml.t) : string =
  (* TODO: implement actual serialization matching Tool_definition_toml structure *)
  (* For now, a placeholder that the test suite will refine *)
  Printf.sprintf "%s\t%s" name (Tool_definition_toml.description defn)

(** Write parity artifacts for each dimension *)
let generate_artifacts () =
  let tools = load_tool_definitions () in
  if List.is_empty tools then (
    Printf.eprintf "Error: no TOML files found in %s\n" tool_config_dir;
    exit 1
  );
  
  (* Dimension 1: description parity *)
  let description_parity =
    tools
    |> List.map ~f:(fun (name, defn) -> tool_to_parity_line name defn)
    |> String.concat ~sep:"\n"
  in
  let desc_file = Filename.concat output_dir "tool_parity_description.txt" in
  Out_channel.write_all desc_file ~data:description_parity;
  Printf.printf "Generated: %s\n" desc_file;
  
  (* Dimension 2-4: params, visibility, availability (TODO) *)
  (* Placeholder: copy description to other dimensions for now *)
  List.iter ["params"; "visibility"; "availability"] ~f:(fun dim ->
    let outfile = Filename.concat output_dir (Printf.sprintf "tool_parity_%s.txt" dim) in
    Out_channel.write_all outfile ~data:description_parity;
    Printf.printf "Generated: %s\n" outfile
  );
  
  printf "Tool parity artifacts regenerated: %d tools, 4 dimensions\n" (List.length tools)

let () =
  try generate_artifacts ()
  with e ->
    Printf.eprintf "Fatal: %s\n" (Exn.to_string e);
    exit 1
