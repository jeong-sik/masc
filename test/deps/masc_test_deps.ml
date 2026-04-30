(* Shared dependency re-export for MASC test suite.
   Also hosts tiny test helpers that need a single SSOT across files. *)

(** Install the Eio clock + optional switch in every registry the lib
    code reads from.

    MASC stores clock state in two places: [Time_compat] (sleep/now) and
    [Eio_context] (Dashboard_cache and other lib/ code that needs the raw
    [float Eio.Time.clock_ty]). Historically harnesses called only
    [Time_compat.set_clock], so anything hitting [Eio_context.get_clock_opt]
    failed with [failwith "Eio clock unavailable"] on the first cache-compute
    path. Main CI skipped Build and Test for 100+ dashboard-only commits, so
    the regression was invisible.

    Call this once per harness after [Eio_main.run @@ fun env ->]
    (and [Eio.Switch.run @@ fun sw ->] if the test publishes a switch). *)
let init_eio_clock ?sw env =
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Eio_context.set_clock clock;
  Option.iter Eio_context.set_switch sw

let init_keeper_tool_registry () =
  if not (Masc_mcp.Tool_dispatch.is_tag_registry_initialized ()) then
    let _ = Masc_mcp.Mcp_server_eio.governance_defaults in
    ()

(** Test fixture parser for [keeper_meta] JSON.

    The production parser at [Masc_mcp.Keeper_types.meta_of_json] requires
    explicit [sandbox_profile] / [network_mode] fields (see fail-loud change
    in keeper_meta_json_parse.ml). Test fixtures historically built minimal
    [`Assoc] payloads that omitted those fields and depended on the silent
    Local fallback. Rather than thread two new fields through every fixture,
    this helper auto-fills the sandbox policy fields with conservative
    defaults (Local / Inherit) when absent, then delegates to the strict
    production parser.

    Production code MUST NOT use this helper — the strict parser exists to
    catch missing fields at the boundary. *)
let meta_of_json_fixture (json : Yojson.Safe.t) =
  let augment fields =
    let has key = List.exists (fun (k, _) -> String.equal k key) fields in
    let add_if_missing key v fs =
      if has key then fs else fs @ [ (key, v) ]
    in
    fields
    |> add_if_missing "sandbox_profile" (`String "local")
    |> add_if_missing "network_mode"    (`String "inherit")
  in
  let json' =
    match json with
    | `Assoc fields -> `Assoc (augment fields)
    | other -> other
  in
  Masc_mcp.Keeper_types.meta_of_json json'

(** Walk up the directory tree from [Sys.getcwd()] until
    [config/tool_policy.toml] is found, then return that directory.
    Raises [Failure] with a descriptive message if the marker file
    cannot be found by the time the filesystem root is reached. *)
let find_project_root () =
  let marker = "config/tool_policy.toml" in
  let start_dir = Sys.getcwd () in
  let rec walk dir =
    if Sys.file_exists (Filename.concat dir marker) then dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then
        failwith
          (Printf.sprintf
             "Could not find %s when walking upward from %s"
             marker start_dir)
      else
        walk parent
  in
  walk start_dir

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

let tla_quoted_strings content =
  let re = Str.regexp "\"\\([^\"]*\\)\"" in
  let acc = ref [] in
  let pos = ref 0 in
  let keep_scanning = ref true in
  while !keep_scanning do
    match Str.search_forward re content !pos with
    | exception Not_found -> keep_scanning := false
    | _ ->
        acc := Str.matched_group 1 content :: !acc;
        pos := Str.match_end ()
  done;
  List.rev !acc

let tla_find_quoted_set ~symbol content =
  let header = symbol ^ " ==" in
  let len = String.length content in
  let hlen = String.length header in
  let rec find_header i =
    if i + hlen > len then None
    else if String.sub content i hlen = header then Some (i + hlen)
    else find_header (i + 1)
  in
  let rec find_matching_brace depth i =
    if i >= len then None
    else
      match content.[i] with
      | '{' -> find_matching_brace (depth + 1) (i + 1)
      | '}' ->
          let depth = depth - 1 in
          if depth = 0 then Some i else find_matching_brace depth (i + 1)
      | _ -> find_matching_brace depth (i + 1)
  in
  match find_header 0 with
  | None -> None
  | Some after_header -> (
      match String.index_from_opt content after_header '{' with
      | None -> None
      | Some open_brace -> (
          match find_matching_brace 0 open_brace with
          | None -> None
          | Some close_brace ->
              let body =
                String.sub content open_brace
                  (close_brace - open_brace + 1)
              in
              Some (tla_quoted_strings body)))

let tla_quoted_set_exn ?(source = "<tla>") ~symbol content =
  match tla_find_quoted_set ~symbol content with
  | Some values -> values
  | None ->
      failwith
        (Printf.sprintf
           "%s not found in %s; set definition may have moved or been \
            renamed."
           symbol source)

let tla_quoted_set_from_repo_file_exn ~relpath ~symbol =
  let path = Filename.concat (find_project_root ()) relpath in
  tla_quoted_set_exn ~source:relpath ~symbol (read_file path)

let sorted_strings = List.sort String.compare

let assert_same_string_set ~label ~expected ~actual =
  let expected = sorted_strings expected in
  let actual = sorted_strings actual in
  if actual <> expected then begin
    Printf.printf "Expected %s : [%s]\n" label
      (String.concat "; " expected);
    Printf.printf "Actual   %s : [%s]\n" label
      (String.concat "; " actual);
    let only_expected =
      List.filter (fun s -> not (List.mem s actual)) expected
    in
    let only_actual =
      List.filter (fun s -> not (List.mem s expected)) actual
    in
    Printf.printf "Only expected : [%s]\n"
      (String.concat "; " only_expected);
    Printf.printf "Only actual   : [%s]\n"
      (String.concat "; " only_actual);
    failwith (label ^ " differs")
  end
