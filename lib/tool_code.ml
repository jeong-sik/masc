(** Code Navigation Tools - Ripgrep-based code search and file reading

    Phase 1: Core search tools (search, symbols, read)

    Security model:
    - Git root validation: restrict operations to repository root
    - File size limit: reject files > 500KB
    - Binary detection: block .so, .wasm, .jpg, etc.
    - Path traversal prevention: deny access outside root
*)

open Types
open Tool_args

(* Context required by code tools *)
type context = {
  config: Room.config;
  agent_name: string;
}

type result = bool * string

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
  let is_absolute = String.length path > 0 && path.[0] = '/' in
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

(* Security: Validate path is within git root.
   Uses canonical path resolution to prevent .. traversal attacks. *)
let validate_path config path =
  try
    if String.contains path '\x00' then
      Error (IoError "Path contains null byte")
    else
    let git_root = match Room_git.git_root ~base_path:config.Room.base_path with
      | None -> raise (Invalid_argument "Not in a git repository")
      | Some root -> root
    in
    let absolute_path =
      if Filename.is_relative path then
        Filename.concat config.Room.base_path path
      else
        path
    in
    let canonical = normalize_path absolute_path in
    let canonical_root = normalize_path git_root in
    if String.starts_with ~prefix:(canonical_root ^ "/") canonical
       || String.equal canonical canonical_root then
      Ok canonical
    else
      Error (IoError "Path traversal detected: access outside git root")
  with
  | Invalid_argument msg -> Error (IoError msg)
  | exn -> Error (IoError (Printexc.to_string exn))

(* Handler: masc_code_search - Search code using ripgrep *)
let handle_code_search ctx args =
  let query = get_string args "query" "" in
  let path = get_string args "path" "." in
  let file_pattern = get_string args "file_pattern" "" in
  let case_insensitive = get_bool args "case_insensitive" true in
  let is_regex = get_bool args "is_regex" false in
  let max_results = get_int args "max_results" 50 in

  if query = "" then
    (false, "❌ Query required: 'query' parameter")
  else begin
    (* Validate path first *)
    let search_path_result = validate_path ctx.config path in
    match search_path_result with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok search_path ->

    (* Build ripgrep command as list (order is important - prepend in reverse!) *)
    let rg_args_list = ref [] in

    (* Ripgrep order: rg [OPTIONS] PATTERN PATH *)
    (* PATH comes LAST, PATTERN second-to-last, so prepend PATH first *)
    rg_args_list := search_path :: !rg_args_list;
    rg_args_list := query :: !rg_args_list;

    (* Max results: --max-count VALUE - prepend VALUE first, then FLAG *)
    rg_args_list := "--max-count" :: string_of_int max_results :: !rg_args_list;

    (* Context lines: -C VALUE - prepend VALUE first, then FLAG *)
    rg_args_list := "-C" :: "2" :: !rg_args_list;

    (* File pattern if specified: -g PATTERN *)
    if file_pattern <> "" then
      rg_args_list := file_pattern :: "-g" :: !rg_args_list;

    (* Fixed-strings mode (default): treat query as literal, not regex *)
    if not is_regex then
      rg_args_list := "--fixed-strings" :: !rg_args_list;

    (* Case insensitive flag: -i *)
    if case_insensitive then
      rg_args_list := "-i" :: !rg_args_list;

    (* JSON output: --json *)
    rg_args_list := "--json" :: !rg_args_list;

    (* Executable name: rg - comes FIRST in final command, prepend LAST *)
    rg_args_list := "rg" :: !rg_args_list;

    let cmd = !rg_args_list in

    match Process_eio.run_argv_with_status ~timeout_sec:30.0 cmd with
    | Unix.WEXITED 0, output ->
        (* Parse rg JSON output *)
        let lines = String.split_on_char '\n' output in
        let results = List.filter_map (fun line ->
          if line = "" then None else
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
        (true, Yojson.Safe.pretty_to_string response)
    | Unix.WEXITED 1, _ ->
        (* No matches *)
        let response = `Assoc [
          ("count", `Int 0);
          ("results", `List []);
        ] in
        (true, Yojson.Safe.pretty_to_string response)
    | Unix.WEXITED 2, output ->
        (* rg error: invalid regex, missing file, etc. Provide actionable help. *)
        let hint =
          if is_regex then
            "Regex error: check your pattern syntax, or set is_regex=false for literal search."
          else
            "Literal search failed. If your query contains regex chars (*+?[](){}^$|.\\), \
             try simplifying the query or set is_regex=true with a valid regex."
        in
        (false, Printf.sprintf "❌ %s\nrg output: %s" hint
           (if output = "" then "(empty)" else
             let s = String.trim output in
             if String.length s > 300 then String.sub s 0 300 ^ "..." else s))
    | status, output ->
        let code = match status with
          | Unix.WEXITED n -> Printf.sprintf "exit %d" n
          | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
          | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n
        in
        (false, Printf.sprintf "ripgrep failed (%s): %s" code
           (if output = "" then "(no output — check rg is in PATH and query is valid)"
            else output))
  end

(* Handler: masc_code_symbols - Extract file symbols using heuristics *)
let handle_code_symbols ctx args =
  let path = get_string args "path" "" in

  if path = "" then
    (false, "❌ Path required: 'path' parameter")
  else begin
    match validate_path ctx.config path with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok validated_path ->
        if not (Sys.file_exists validated_path) then
          (false, Printf.sprintf "❌ File not found: %s" path)
        else if is_binary_file validated_path then
          (false, "❌ Binary file detected")
        else begin
          (* Read file and extract symbols *)
          let file_size = (Unix.stat validated_path).Unix.st_size in
          if file_size > max_file_size then
            (false, Printf.sprintf "❌ File too large: %d bytes (max: %d)" file_size max_file_size)
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
                               (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                               (c >= '0' && c <= '9') || c = '_' || c = '\'') do
                          incr name_end
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
              (true, Yojson.Safe.pretty_to_string response)
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              (false, Printf.sprintf "❌ Failed to read file: %s" (Printexc.to_string exn))
          end
        end
  end

(* Handler: masc_code_read - Read file with offset/limit *)
let handle_code_read ctx args =
  let path = get_string args "path" "" in
  let offset = get_int args "offset" 0 in
  let limit = get_int args "limit" 100 in

  if path = "" then
    (false, "❌ Path required: 'path' parameter")
  else begin
    match validate_path ctx.config path with
    | Error e -> (false, Types.masc_error_to_string e)
    | Ok validated_path ->
        if not (Sys.file_exists validated_path) then
          (false, Printf.sprintf "❌ File not found: %s" path)
        else if is_binary_file validated_path then
          (false, "❌ Binary file detected")
        else begin
          let file_size = (Unix.stat validated_path).Unix.st_size in
          if file_size > max_file_size then
            (false, Printf.sprintf "❌ File too large: %d bytes (max: %d)" file_size max_file_size)
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
              (true, Yojson.Safe.pretty_to_string response)
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              (false, Printf.sprintf "❌ Failed to read file: %s" (Printexc.to_string exn))
          end
        end
  end

(* Dispatch function - returns None if tool not handled *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_code_search" -> Some (handle_code_search ctx args)
  | "masc_code_symbols" -> Some (handle_code_symbols ctx args)
  | "masc_code_read" -> Some (handle_code_read ctx args)
  | _ -> None

let schemas : Types.tool_schema list = [
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
          ("description", `String "Search path (default: current directory)");
          ("default", `String ".");
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
      ("required", `List [`String "query"]);
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
           ~visibility:Tool_catalog.Hidden
           ~allow_direct_call_when_hidden:true
           ~is_read_only:true
           ~is_idempotent:true
           ()))
    schemas
