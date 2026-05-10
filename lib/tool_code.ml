module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Code Navigation Tools - Ripgrep-based code search and file reading

    Phase 1: Core search tools (search, symbols, read)

    Security model:
    - Git root validation: restrict operations to repository root
    - File size limit: reject files > 500KB
    - Binary detection: block .so, .wasm, .jpg, etc.
    - Path traversal prevention: deny access outside root
*)

open Masc_domain
open Tool_args

(* Context required by code tools *)
type context = {
  config: Coord.config;
  agent_name: string;
}

type tool_result = bool * string

(* Security: Binary file extensions *)
let binary_extensions = [
  ".so"; ".a"; ".lib"; ".dll"; ".dylib";
  ".wasm"; ".o"; ".obj";
  ".jpg"; ".jpeg"; ".png"; ".gif"; ".bmp"; ".ico"; ".webp";
  ".mp3"; ".mp4"; ".avi"; ".mov"; ".wav"; ".flac";
  ".zip"; ".tar"; ".gz"; ".bz2"; ".xz"; ".7z";
  ".pdf"; ".doc"; ".docx"; ".xls"; ".xlsx"; ".ppt"; ".pptx";
]

(* Security: Check if file is binary by extension *)
let is_binary_file path =
  List.exists (fun ext ->
    String.length path >= String.length ext &&
    String.equal (String.sub path (String.length path - String.length ext) (String.length ext)) ext
  ) binary_extensions

(* Security: Check file size limit (500KB) *)
let max_file_size = 500 * 1024

(* Security: Normalize path by resolving . and .. segments.
   Returns a clean absolute path with no traversal components. *)
let normalize_path path =
  let parts = String.split_on_char '/' path in
  let is_absolute = String.length path > 0 && Char.equal path.[0] '/' in
  let rec resolve acc = function
    | [] -> List.rev acc
    | ("." | "") :: rest -> resolve acc rest
    | ".." :: rest ->
      (match acc with
       | [] -> resolve [] rest
       | _ :: tl -> resolve tl rest)
    | seg :: rest -> resolve (seg :: acc) rest
  in
  let resolved = resolve [] parts in
  let joined = String.concat "/" resolved in
  if is_absolute then "/" ^ joined else joined

let normalize_agent_relative_path ~(config : Coord.config) ~(agent_name : string)
    (raw_path : string) : string =
  let trimmed = String.trim raw_path in
  let own_bundle_rel = Keeper_alerting_path.playground_path_of_keeper agent_name in
  let trimmed =
    (* Docker containers mount the playground at
       /home/keeper/playground/<keeper-name>/ but the host side validates
       against <base_path>/.masc/playground/docker/<keeper-name>/.  When a
       keeper runs inside Docker, masc_code_read returns container paths;
       masc_code_edit must translate them back. *)
    if not (Filename.is_relative trimmed) then begin
      let container_prefix =
        Filename.concat
          Env_config_keeper.DockerPlayground.container_playground_root
          (Playground_paths.sanitize_keeper_name agent_name)
      in
      if String.starts_with ~prefix:(container_prefix ^ "/") trimmed then begin
        let suffix =
          String.sub trimmed
            (String.length container_prefix + 1)
            (String.length trimmed - String.length container_prefix - 1)
        in
        Filename.concat
          (Filename.concat config.Coord.base_path own_bundle_rel)
          suffix
      end else
        trimmed
    end else
      trimmed
  in
  let trimmed =
    if Filename.is_relative trimmed
       && String.length trimmed >= String.length own_bundle_rel
       && String.starts_with ~prefix:own_bundle_rel trimmed
    then
      let rest =
        String.sub trimmed (String.length own_bundle_rel)
          (String.length trimmed - String.length own_bundle_rel)
      in
      if String.equal rest "" then "." else rest
    else trimmed
  in
  let trimmed =
    if not (Filename.is_relative trimmed) then
      let own_bundle_abs =
        Filename.concat config.Coord.base_path own_bundle_rel
        |> Keeper_alerting_path.strip_trailing_slashes
      in
      let doubled_prefix = own_bundle_abs ^ "/" ^ own_bundle_rel in
      if String.starts_with ~prefix:doubled_prefix trimmed then
        let rest =
          String.sub trimmed (String.length doubled_prefix)
            (String.length trimmed - String.length doubled_prefix)
        in
        Filename.concat own_bundle_abs rest
      else trimmed
    else trimmed
  in
  let is_playground_lane =
    Filename.is_relative trimmed
    && List.exists
         (fun prefix ->
            String.equal trimmed prefix
            || String.starts_with ~prefix:(prefix ^ "/") trimmed)
         [ "mind"; "repos" ]
  in
  if is_playground_lane then
    Filename.concat
      (Filename.concat config.Coord.base_path own_bundle_rel)
      trimmed
  else
    trimmed

(* Security: Validate path is within git root.
   Uses canonical path resolution to prevent .. traversal attacks. *)
let validate_path config path =
  try
    if String.contains path '\x00' then
      Error (System (System_error.IoError "Path contains null byte"))
    else
    match Coord_git.git_root ~base_path:config.Coord.base_path with
    | None -> Error (System (System_error.IoError "Not in a git repository"))
    | Some git_root ->
    let absolute_path =
      if Filename.is_relative path then
        Filename.concat config.Coord.base_path path
      else
        path
    in
    let canonical = normalize_path absolute_path in
    let canonical_root = normalize_path git_root in
    let resolved_root =
      try Some (Unix.realpath canonical_root) with
      | Unix.Unix_error _ -> None
    in
    let resolved_path =
      if Sys.file_exists canonical then
        try Some (Unix.realpath canonical) with
        | Unix.Unix_error _ -> None
      else
        None
    in
    let within root candidate =
      String.starts_with ~prefix:(root ^ "/") candidate
      || String.equal candidate root
    in
    let allowed =
      match resolved_root, resolved_path with
      | Some root, Some candidate -> within root candidate
      | _ -> within canonical_root canonical
    in
    if allowed then Ok canonical
    else Error (System (System_error.IoError "Path traversal detected: access outside git root"))
  with
  | Invalid_argument msg -> Error (System (System_error.IoError msg))
  | exn -> Error (System (System_error.IoError (Stdlib.Printexc.to_string exn)))

(* #6637 iter11 — per-agent playground containment for code-read tools.

   [validate_path] guarantees the target is within the git root, but
   .masc/playground/<other-keeper>/ is also under the git root, so a
   keeper could historically read another keeper's playground
   contents via masc_code_search/symbols/read — a data exfiltration
   surface (secrets in playground .env files, proprietary code
   mid-work, handoff notes, etc.).

   Two-tier gate:
   1. Run the pre-existing [validate_path] (git-root check, null-byte
      rejection, canonicalisation).
   2. If the canonical path is outside the [.masc/playground/] tree,
      it's the shared codebase (lib/, test/, config/, etc.) — allow.
   3. If the canonical path is inside the playground tree, require it
      to be under the caller's own bundle (via [playground_path_of_keeper]).

   Sibling write fix: iter6 #6610 in tool_code_write.ml. *)
let validate_read_path ~agent_name config path =
  let base_path = config.Coord.base_path in
  let path = normalize_agent_relative_path ~config ~agent_name path in
  match validate_path config path with
  | Error e -> Error e
  | Ok canonical_string ->
      (* [validate_path] returns a [normalize_path]-resolved canonical
         string — it collapses [.] and [..] segments but does NOT
         follow symlinks. For the *git-root* boundary check that's
         fine (a link's string path is still inside the git root).
         But for the *playground* containment check we must follow
         symlinks, otherwise a keeper could place a link inside its
         own bundle pointing into another keeper's playground and the
         string-level prefix check would false-accept it (GLM-5.1
         review Issue #2 on PR #6664, with a live test case that
         initially reproduced the bypass). Realpath the canonical
         target once here and use the result for every subsequent
         comparison against the playground roots (which are also
         realpath'd below). *)
      match
        try Ok (Unix.realpath canonical_string) with
        | Unix.Unix_error _ ->
            (* The target vanished between validate_path and here
               (racy deletion, or a broken symlink). Treat as a
               containment failure rather than silently accepting. *)
            Error
              (System (System_error.IoError
                 (Printf.sprintf
                    "target path %S is not accessible (dangling \
                     symlink or racy deletion)" path)))
      with
      | Error e -> Error e
      | Ok canonical ->
      let playground_tree_rel = Playground_paths.all_playgrounds_prefix in
      let playground_tree_abs_raw =
        Filename.concat base_path playground_tree_rel
      in
      let playground_tree_abs = normalize_path playground_tree_abs_raw in
      let target_mentions_playground_tree =
        String.starts_with ~prefix:(playground_tree_abs ^ "/") canonical_string
        || String.equal canonical_string playground_tree_abs
      in
      if not target_mentions_playground_tree then
        (* Shared codebase paths outside [.masc/playground] remain
           readable even when the playground tree has never been
           provisioned in this repo. *)
        Ok canonical
      else
        (* #6637 iter11 GLM review: fail closed on realpath failure.
           [normalize_path] only resolves string-level [.] / [..]
           segments; it does NOT follow symlinks. If the playground
           tree doesn't realpath, a symlink in the filesystem could
           flip the prefix comparison below. Return an explicit error
           that points the LLM at the recovery action (provision the
           playground bundle) instead of silently weakening the gate.
           Mirrors iter10 #6651 fail-closed pattern. *)
        match
          try Ok (Unix.realpath playground_tree_abs_raw) with
          | Unix.Unix_error _ ->
              Error
                (System (System_error.IoError
                   (Printf.sprintf
                      "keeper playground tree %S does not exist; cannot \
                       validate cross-keeper containment. Clone via \
                       keeper_shell op=git_clone to provision your \
                       playground first. See #6527/#6637."
                      playground_tree_rel)))
        with
        | Error e -> Error e
        | Ok playground_tree_canonical ->
          let is_under_any_playground =
            String.starts_with
              ~prefix:(playground_tree_canonical ^ "/") canonical
            || String.equal canonical playground_tree_canonical
          in
          if not is_under_any_playground then
            (* Shared codebase read — allow. *)
            Ok canonical
          else
            let own_rel_trailing =
              Keeper_alerting_path.playground_path_of_keeper agent_name
            in
            (* [playground_path_of_keeper] returns a trailing-slash
               relative path (".masc/playground/<agent>/"). Strip the
               trailing slash for the prefix comparison. *)
            let own_rel =
              let n = String.length own_rel_trailing in
              if n > 0 && Char.equal own_rel_trailing.[n - 1] '/'
              then String.sub own_rel_trailing 0 (n - 1)
              else own_rel_trailing
            in
            let own_abs_raw = Filename.concat base_path own_rel in
            (* Same fail-closed rule for the caller's own playground
               root — again, to preserve symlink-collapse guarantees. *)
            match
              try Ok (Unix.realpath own_abs_raw) with
              | Unix.Unix_error _ ->
                  Error
                    (System (System_error.IoError
                       (Printf.sprintf
                          "keeper playground bundle %S does not exist \
                           yet; cannot validate containment. Provision \
                           via git_clone or masc_worktree_create first. \
                           See #6527/#6637."
                          own_rel_trailing)))
            with
            | Error e -> Error e
            | Ok own_canonical ->
                if String.equal canonical own_canonical
                   || String.starts_with ~prefix:(own_canonical ^ "/") canonical
                then Ok canonical
                else
                  Error (System (System_error.IoError (Printf.sprintf
                    "cross-keeper playground read blocked: agent=%S tried to \
                     read path %S which is under another keeper's playground. \
                     Only %s is readable for this caller; reads outside your \
                     own playground must target the shared codebase (lib/, \
                     test/, config/, etc.). See #6527/#6637."
                    agent_name path own_rel_trailing)))


(* Handler: masc_code_search - Search code using ripgrep *)
let handle_code_search ctx args =
  let query = get_string args "query" "" in
  let path = get_string args "path" "" in
  let file_pattern = get_string args "file_pattern" "" in
  let case_insensitive = get_bool args "case_insensitive" true in
  let is_regex = get_bool args "is_regex" false in
  let max_results = get_int args "max_results" 50 in

  if String.equal query "" then
    (false, "Query required: 'query' parameter")
  else if String.equal (String.trim path) "" then
    (false, "Path required: 'path' parameter")
  else begin
    (* Validate path first *)
    let search_path_result =
      validate_read_path ~agent_name:ctx.agent_name ctx.config path
    in
    match search_path_result with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok search_path ->

    let rg_args =
      [ "--json" ]
      @ (if case_insensitive then [ "-i" ] else [])
      @ (if not is_regex then [ "--fixed-strings" ] else [])
      @ (if not (String.equal file_pattern "") then [ "-g"; file_pattern ] else [])
      @ [ "-C"; "2"; "--max-count"; Int.to_string max_results; "--"; query; search_path ]
    in
    let cmd = "rg" :: rg_args in

    match Masc_exec.Exec_gate.run_argv_with_status ~actor:`Tool_local_runtime ~raw_source:(String.concat " " cmd) ~summary:"rg search in workspace" ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Shell ()) cmd with
    | Unix.WEXITED 0, output ->
        (* Parse rg JSON output *)
        let lines = String.split_on_char '\n' output in
        let results = List.filter_map (fun line ->
          if String.equal line "" then None else
          try Some (Yojson.Safe.from_string line)
          with Yojson.Json_error _ -> None
        ) lines in

        let matches = List.filter_map (fun (json : Yojson.Safe.t) ->
          let module U = Yojson.Safe.Util in
          match U.member "type" json with
          | `String "match" ->
              let data = U.member "data" json in
              (* path is {"text": "..."} not a string *)
              let path_str = U.(data |> member "path" |> member "text" |> to_string) in
              (* lines is {"text": "..."} not a string *)
              let line_content = U.(data |> member "lines" |> member "text" |> to_string) in
              let line_num = U.(data |> member "line_number" |> to_int) in
              Some (`Assoc [
                ("path", `String path_str);
                ("line", `Int line_num);
                ("content", `String line_content);
              ])
          | _ -> None
        ) results in

        let response = `Assoc [
          ("count", `Int (List.length matches));
          ("results", `List matches);
        ] in
        (true, Yojson.Safe.to_string response)
    | Unix.WEXITED 1, _ ->
        (* No matches *)
        let response = `Assoc [
          ("count", `Int 0);
          ("results", `List []);
        ] in
        (true, Yojson.Safe.to_string response)
    | Unix.WEXITED 2, output ->
        (* rg error: invalid regex, missing file, etc. Pick the right hint
           by scanning the rg output, since exit-2 is overloaded. *)
        let trimmed_out = String.trim output in
        let mentions_no_file =
          let lower = String.lowercase_ascii trimmed_out in
          let contains s sub =
            let ls = String.length s and lsub = String.length sub in
            let rec scan i =
              if i + lsub > ls then false
              else if String.equal (Stdlib.String.sub s i lsub) sub then true
              else scan (i + 1)
            in
            scan 0
          in
          contains lower "no such file" || contains lower "is a directory"
        in
        let hint =
          if mentions_no_file then
            Printf.sprintf
              "Search target not found. The 'path' argument resolved to %S — check that it \
               exists and is reachable from the keeper's allowed roots. (Empty/missing 'path' \
               defaults to '.')"
              search_path
          else if is_regex then
            "Regex error: check your pattern syntax, or set is_regex=false for literal search."
          else
            "Literal search failed. If your query contains regex chars (*+?[](){}^$|.\\), \
             try simplifying the query or set is_regex=true with a valid regex."
        in
        (false, Printf.sprintf "%s\nrg output: %s" hint
           (if String.equal trimmed_out "" then "(empty)"
            else String_util.utf8_safe ~max_bytes:303 ~suffix:"..." trimmed_out |> String_util.to_string))
    | status, output ->
        let code = match status with
          | Unix.WEXITED n -> Printf.sprintf "exit %d" n
          | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
          | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n
        in
        (false, Printf.sprintf "ripgrep failed (%s): %s" code
           (if String.equal output "" then "(no output — check rg is in PATH and query is valid)"
            else output))
  end

(* Handler: masc_code_symbols - Extract file symbols using heuristics *)
let handle_code_symbols ctx args =
  let path = get_string args "path" "" in

  if String.equal path "" then
    (false, "Path required: 'path' parameter")
  else begin
    match validate_read_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok validated_path ->
        if not (Sys.file_exists validated_path) then
          (false, Printf.sprintf "File not found: %s" path)
        else if is_binary_file validated_path then
          (false, "Binary file detected")
        else begin
          (* Read file and extract symbols *)
          let file_size = (Unix.stat validated_path).Unix.st_size in
          if file_size > max_file_size then
            (false, Printf.sprintf "File too large: %d bytes (max: %d)" file_size max_file_size)
          else begin
            try
              let content = In_channel.with_open_text validated_path In_channel.input_all in
              let lines = String.split_on_char '\n' content in

              (* Extract symbols using heuristics *)
              let rec extract_symbols acc line_num = function
                | [] -> List.rev acc
                | line :: rest ->
                    let trimmed = String.trim line in
                    (* Try to extract a symbol name from keyword-based patterns *)
                    let try_keyword_extract keyword line =
                      if String.starts_with ~prefix:(keyword ^ " ") line then
                        let rest = String.trim (String.sub line (String.length keyword + 1)
                                     (String.length line - String.length keyword - 1)) in
                        (* Extract name: first identifier (alphanum + _) *)
                        let name_end = ref 0 in
                        while !name_end < String.length rest &&
                              (let c = rest.[!name_end] in
                               (match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '\'' -> true | _ -> false)) do
                          Stdlib.incr name_end
                        done;
                        if !name_end > 0 then
                          Some (String.sub rest 0 !name_end, keyword)
                        else None
                      else None
                    in
                    let ocaml_keywords = ["let"; "and"; "type"; "exception"; "module"; "open"; "include"; "val"; "external"] in
                    let py_keywords = ["def"; "class"; "async def"] in
                    let other_keywords = ["func"; "function"; "interface"; "struct"; "enum"; "impl"; "pub fn"; "const"; "var"] in
                    let all_keywords = ocaml_keywords @ py_keywords @ other_keywords in
                    let symbols =
                      match List.find_map (fun kw -> try_keyword_extract kw trimmed) all_keywords with
                      | Some (name, kind) ->
                          [Some (`Assoc [
                            ("name", `String name);
                            ("kind", `String kind);
                            ("line", `Int line_num);
                          ])]
                      | None -> []
                    in
                    extract_symbols (List.rev_append symbols acc) (line_num + 1) rest
              in

              let symbols = extract_symbols [] 1 lines in
              let symbols_json = List.map (function Some x -> x | None -> `Null) symbols in
              let response : Yojson.Safe.t = `Assoc [
                ("path", `String path);
                ("count", `Int (List.length symbols));
                ("symbols", `List symbols_json);
              ] in
              (true, Yojson.Safe.to_string response)
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              (false, Printf.sprintf "Failed to read file: %s" (Stdlib.Printexc.to_string exn))
          end
        end
  end

(* Handler: masc_code_read - Read file with offset/limit *)
let handle_code_read ctx args =
  let path = get_string args "path" "" in
  let offset = get_int args "offset" 0 in
  let limit = get_int args "limit" 100 in

  if String.equal path "" then
    (false, "Path required: 'path' parameter")
  else begin
    match validate_read_path ~agent_name:ctx.agent_name ctx.config path with
    | Error e -> (false, Masc_domain.masc_error_to_string e)
    | Ok validated_path ->
        if not (Sys.file_exists validated_path) then
          (false, Printf.sprintf "File not found: %s" path)
        else if is_binary_file validated_path then
          (false, "Binary file detected")
        else begin
          let file_size = (Unix.stat validated_path).Unix.st_size in
          if file_size > max_file_size then
            (false, Printf.sprintf "File too large: %d bytes (max: %d)" file_size max_file_size)
          else begin
            try
              let content = In_channel.with_open_text validated_path In_channel.input_all in
              let lines = String.split_on_char '\n' content in
              let total_lines = List.length lines in

              (* Validate offset *)
              let safe_offset = max 0 (min offset total_lines) in

              (* Calculate end line *)
              let safe_limit = min limit (total_lines - safe_offset) in

              (* Extract lines *)
              let selected_lines = ref [] in
              for i = safe_offset to safe_offset + safe_limit - 1 do
                match List.nth_opt lines i with
                | Some line -> selected_lines := line :: !selected_lines
                | None -> ()
              done;

              let result_lines = List.rev !selected_lines in
              let response = `Assoc [
                ("path", `String path);
                ("offset", `Int safe_offset);
                ("limit", `Int safe_limit);
                ("total_lines", `Int total_lines);
                ("lines", `List (List.map (fun s -> `String s) result_lines));
              ] in
              (true, Yojson.Safe.to_string response)
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              (false, Printf.sprintf "Failed to read file: %s" (Stdlib.Printexc.to_string exn))
          end
        end
  end

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_code_search" -> Some (handle_code_search ctx args)
  | "masc_code_symbols" -> Some (handle_code_symbols ctx args)
  | "masc_code_read" -> Some (handle_code_read ctx args)
  | _ -> None

let schemas : Masc_domain.tool_schema list = [
  (* masc_code_search *)
  {
    name = "masc_code_search";
    description = "Search code using ripgrep. Literal match by default (is_regex=false). \
Use simple words/phrases as query. Example: query='handle_request', file_pattern='*.ml'. \
Set is_regex=true only for patterns like 'foo.*bar' or 'class \\w+'.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Search pattern (literal by default, regex if is_regex=true)");
        ]);
        ("is_regex", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Treat query as regex instead of literal string (default: false)");
          ("default", `Bool false);
        ]);
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Search path to scope the query (for example 'lib/', 'test/', or 'workspace/yousleepwhen/masc-mcp/lib/')");
        ]);
        ("file_pattern", `Assoc [
          ("type", `String "string");
          ("description", `String "Glob pattern to filter files (e.g., '*.ml', '*.py')");
          ("default", `String "");
        ]);
        ("case_insensitive", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Case-insensitive search (default: true)");
          ("default", `Bool true);
        ]);
        ("max_results", `Assoc [
          ("type", `String "number");
          ("description", `String "Maximum number of results (default: 50)");
          ("default", `Int 50);
        ]);
      ]);
      ("required", `List [`String "query"; `String "path"]);
    ];
  };

  (* masc_code_symbols *)
  {
    name = "masc_code_symbols";
    description = "Extract symbols (functions, types, classes) from a file as a token-efficient outline (~70% savings vs full read). \
Use when you need to understand a file's structure without reading all content. \
Pair with masc_code_read to then read specific line ranges of interest.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to extract symbols from");
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

  (* masc_code_read *)
  {
    name = "masc_code_read";
    description = "Read a file with offset/limit pagination for token-efficient access to specific sections. \
Use when you know the line range you need, especially for large files. \
After masc_code_symbols identifies the relevant line numbers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "File path to read");
        ]);
        ("offset", `Assoc [
          ("type", `String "number");
          ("description", `String "Starting line number (0-indexed, default: 0)");
          ("default", `Int 0);
        ]);
        ("limit", `Assoc [
          ("type", `String "number");
          ("description", `String "Maximum lines to read (default: 100)");
          ("default", `Int 100);
        ]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };

]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

(* Code tools are not on the public MCP surface but remain callable
   via tools/call and available to managed agents. *)
let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_code
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~visibility:Tool_catalog.Hidden
           ~allow_direct_call_when_hidden:true
           ~is_read_only:true
           ~is_idempotent:true
           ()))
    schemas
