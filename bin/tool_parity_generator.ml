(** Tool definition parity artifact generator (task-1363).

    Reads every [config/tools/<name>.toml] through the production loader
    ([Tool_definition_toml.load ~name ~contents]) and emits the parity
    baselines under [test/golden/]:

      - tool_parity_description.txt  — name, description (byte-exact prose)
      - tool_parity_params.txt       — name, Yojson.Safe.to_string input_schema
      - tool_parity_visibility.txt   — name, loading, keeper projection
      - tool_parity_availability.txt — name, loading

    One line per tool, tab-separated, sorted by name, LF endings, trailing
    newline. The loader is the only decoder: whatever it accepts is the
    parity truth, and drift between the TOML declarations and a consumer's
    expectation shows up as a baseline diff.

    Invoked manually by: dune build @regen_tool_parity_artifacts
    (the alias lives in test/dune via tools/tool_parity_regen.inc). *)

let tool_config_dir = "config/tools"

let output_dir = "test/golden"

(* Read a whole file as a string (the loader takes [contents], not a path). *)
let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* [description]: the exact sentence the loader decoded — the prose every
   projection inherits unless it overrides it. *)
let render_description (loaded : Tool_definition_toml.loaded) : string =
  loaded.schema.description

(* [params]: the loader-assembled input schema, serialized with the same
   [Yojson.Safe.to_string] whose byte-identity property the loader's .mli
   documents — key order preserved, so a TOML edit that only reorders keys
   is not a parity change. *)
let render_params (loaded : Tool_definition_toml.loaded) : string =
  Yojson.Safe.to_string loaded.schema.input_schema

(* [visibility]: which surfaces see the tool — the loading axis and whether
   a narrower keeper projection was declared. *)
let render_visibility (loaded : Tool_definition_toml.loaded) : string =
  Printf.sprintf "%s\t%s"
    (Tool_definition_toml.loading_to_string loaded.loading)
    (match loaded.keeper_projection with
     | None -> "none"
     | Some _ -> "keeper_projection")

(* [availability]: the loading axis alone — always-loaded tools ride every
   request, deferrable ones wait to be named. *)
let render_availability (loaded : Tool_definition_toml.loaded) : string =
  Tool_definition_toml.loading_to_string loaded.loading

let dimensions : (string * (Tool_definition_toml.loaded -> string)) list =
  [ ("description", render_description)
  ; ("params", render_params)
  ; ("visibility", render_visibility)
  ; ("availability", render_availability) ]

let () =
  if not (Sys.file_exists output_dir) then Sys.mkdir output_dir 0o755;
  let names =
    Sys.readdir tool_config_dir |> Array.to_list
    |> List.filter (fun file -> String.ends_with ~suffix:".toml" file)
    |> List.map (fun file -> String.sub file 0 (String.length file - 5))
    |> List.sort String.compare
  in
  match names with
  | [] ->
      Printf.eprintf "tool_parity_generator: no .toml in %s\n" tool_config_dir;
      exit 1
  | _ ->
      let defs =
        List.map
          (fun name ->
            let path = Filename.concat tool_config_dir (name ^ ".toml") in
            match Tool_definition_toml.load ~name ~contents:(read_file path) with
            | Ok loaded -> (name, loaded)
            | Error err ->
                Printf.eprintf "tool_parity_generator: %s failed to load: %s\n"
                  path err;
                exit 1)
          names
      in
      List.iter
        (fun (suffix, render) ->
          let path = Filename.concat output_dir ("tool_parity_" ^ suffix ^ ".txt") in
          let oc = open_out_bin path in
          List.iter
            (fun (name, loaded) ->
              Printf.fprintf oc "%s\t%s\n" name (render loaded))
            defs;
          close_out oc;
          Printf.printf "generated %s (%d tools)\n" path (List.length defs))
        dimensions
