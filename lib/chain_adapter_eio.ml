(** Chain Adapter - Transform functions for Adapter nodes

    Adapter transforms apply data transformations between nodes:
    - Extract: JSON path extraction
    - Template: String templating
    - Summarize: Token-based truncation
    - Truncate: Character-based truncation
    - JsonPath: JSONPath extraction
    - Regex: Regex replacement
    - ValidateSchema: JSON Schema validation
    - ParseJson: JSON validation
    - Stringify: Convert to JSON string
    - Chain: Sequential transforms
    - Conditional: Expression-based branching
    - Custom: Built-in functions

    @author Chain Engine
    @since 2026-01
*)

open Chain_types

(** Apply adapter transformation to input value *)
let rec apply_adapter_transform (transform : adapter_transform) (input : string) : (string, string) result =
  match transform with
  | Extract path ->
      (* Simple dot-path extraction from JSON *)
      (try
        let json = Yojson.Safe.from_string input in
        let parts = String.split_on_char '.' path in
        let rec extract_path j = function
          | [] -> Ok (Yojson.Safe.to_string j)
          | key :: rest ->
              (match j with
               | `Assoc fields ->
                   (match List.assoc_opt key fields with
                    | Some v -> extract_path v rest
                    | None -> Error (Printf.sprintf "Key '%s' not found in path '%s'" key path))
               | `List items when String.length key >= 3 && key.[0] = '[' && key.[String.length key - 1] = ']' ->
                   (* Handle array index: [0], [1], etc. - requires at least "[N]" format *)
                   let idx_str = String.sub key 1 (String.length key - 2) in
                   (try
                     let idx = int_of_string idx_str in
                     if idx >= 0 && idx < List.length items then
                       extract_path (List.nth items idx) rest
                     else
                       Error (Printf.sprintf "Index %d out of bounds" idx)
                   with Invalid_argument _ | Failure _ -> Error (Printf.sprintf "Invalid index: %s" key))
               | _ -> Error (Printf.sprintf "Cannot extract '%s' from non-object" key))
        in
        extract_path json parts
      with Yojson.Json_error msg -> Error (Printf.sprintf "JSON parse error: %s" msg))

  | Template tpl ->
      (* Simple {{value}} substitution *)
      let result = Str.global_replace (Str.regexp "{{value}}") input tpl in
      Ok result

  | Summarize max_tokens ->
      (* Token-based truncation using char estimation (1 token ≈ 4 chars).
         This is more accurate than word count for LLM context budgets.
         For actual summarization, use LLM node with summarization prompt. *)
      let estimated_chars = max_tokens * 4 in
      if String.length input <= estimated_chars then
        Ok input
      else
        (* Truncate at word boundary to avoid cutting words *)
        let truncated = String.sub input 0 estimated_chars in
        let last_space =
          try String.rindex truncated ' '
          with Not_found -> estimated_chars
        in
        Ok (String.sub truncated 0 last_space ^ "...")

  | Truncate max_chars ->
      if String.length input <= max_chars then Ok input
      else Ok (String.sub input 0 max_chars ^ "...")

  | JsonPath path ->
      (* Simplified JSONPath - supports $.field.subfield and $[0].field syntax *)
      let normalized_path =
        (* Strip $. or $ prefix if present *)
        if String.length path >= 2 && String.sub path 0 2 = "$." then
          String.sub path 2 (String.length path - 2)
        else if String.length path >= 1 && path.[0] = '$' then
          String.sub path 1 (String.length path - 1)
        else
          path
      in
      if String.length normalized_path = 0 then
        Ok input  (* $ alone means root *)
      else
        apply_adapter_transform (Extract normalized_path) input

  | Regex (pattern, replacement) ->
      (try
        let re = Str.regexp pattern in
        Ok (Str.global_replace re replacement input)
      with Failure _ -> Error (Printf.sprintf "Invalid regex pattern: %s" pattern))

  | ValidateSchema schema_str ->
      (* JSON Schema validation (subset of draft-07).
         schema_str can be:
         - Inline JSON Schema: {"type":"object","required":["name"]}
         - Simple type name: "object", "string", "number", "array"

         Supported validations:
         - type: string, number, integer, boolean, array, object, null
         - required: array of field names (for objects)
         - enum: array of allowed values
         - minLength/maxLength: for strings
         - minimum/maximum: for numbers *)
      let validate_type expected json =
        match expected, json with
        | "string", `String _ -> true
        | "number", `Float _ | "number", `Int _ -> true
        | "integer", `Int _ -> true
        | "boolean", `Bool _ -> true
        | "array", `List _ -> true
        | "object", `Assoc _ -> true
        | "null", `Null -> true
        | _ -> false
      in
      let validate_required required json =
        match json with
        | `Assoc fields ->
            let field_names = List.map fst fields in
            List.for_all (fun r -> List.mem r field_names) required
        | _ -> false
      in
      let validate_enum allowed json =
        List.exists (fun v -> v = json) allowed
      in
      let validate_string_length min_len max_len json =
        match json with
        | `String s ->
            let len = String.length s in
            (match min_len with Some m -> len >= m | None -> true) &&
            (match max_len with Some m -> len <= m | None -> true)
        | _ -> true
      in
      let validate_number_range minimum maximum json =
        match json with
        | `Float f ->
            (match minimum with Some m -> f >= m | None -> true) &&
            (match maximum with Some m -> f <= m | None -> true)
        | `Int i ->
            let f = float_of_int i in
            (match minimum with Some m -> f >= m | None -> true) &&
            (match maximum with Some m -> f <= m | None -> true)
        | _ -> true
      in
      (try
        let data = Yojson.Safe.from_string input in
        (* Parse schema - either inline JSON or simple type name *)
        let schema =
          if String.length schema_str > 0 && schema_str.[0] = '{' then
            Yojson.Safe.from_string schema_str
          else
            `Assoc [("type", `String schema_str)]
        in
        let open Yojson.Safe.Util in
        let errors = ref [] in

        (* Validate type *)
        (match schema |> member "type" with
         | `String t when not (validate_type t data) ->
             errors := Printf.sprintf "expected type '%s'" t :: !errors
         | _ -> ());

        (* Validate required fields *)
        (match schema |> member "required" with
         | `List req_list ->
             let required = List.filter_map (function `String s -> Some s | _ -> None) req_list in
             if not (validate_required required data) then
               errors := Printf.sprintf "missing required fields: %s"
                 (String.concat ", " required) :: !errors
         | _ -> ());

        (* Validate enum *)
        (match schema |> member "enum" with
         | `List enum_list when not (validate_enum enum_list data) ->
             errors := "value not in enum" :: !errors
         | _ -> ());

        (* Validate string length *)
        let min_len = match schema |> member "minLength" with `Int n -> Some n | _ -> None in
        let max_len = match schema |> member "maxLength" with `Int n -> Some n | _ -> None in
        if not (validate_string_length min_len max_len data) then
          errors := "string length constraint violated" :: !errors;

        (* Validate number range *)
        let minimum = match schema |> member "minimum" with
          | `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None in
        let maximum = match schema |> member "maximum" with
          | `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None in
        if not (validate_number_range minimum maximum data) then
          errors := "number range constraint violated" :: !errors;

        if !errors = [] then Ok input
        else Error (Printf.sprintf "Schema validation failed: %s" (String.concat "; " !errors))
      with
      | Yojson.Json_error msg ->
          Error (Printf.sprintf "Invalid JSON: %s" msg)
      | _ ->
          Error "Schema validation error")

  | ParseJson ->
      (* Validate input is valid JSON and return as-is *)
      (try
        let _ = Yojson.Safe.from_string input in
        Ok input
      with Yojson.Json_error msg -> Error (Printf.sprintf "Not valid JSON: %s" msg))

  | Stringify ->
      (* Wrap in JSON string if not already *)
      (try
        let _ = Yojson.Safe.from_string input in
        Ok input  (* Already JSON *)
      with Yojson.Json_error _ ->
        Ok (Yojson.Safe.to_string (`String input)))

  | Chain transforms ->
      (* Apply transforms sequentially *)
      List.fold_left
        (fun acc t ->
          match acc with
          | Error _ -> acc
          | Ok v -> apply_adapter_transform t v)
        (Ok input)
        transforms

  | Conditional { condition; on_true; on_false } ->
      (* Expression-based condition evaluation
         Supported operators:
         - "contains:text" - input contains text (no trimming)
         - "eq:value" - input equals value (input trimmed, value not trimmed)
         - "neq:value" - input not equals value (input trimmed)
         - "gt:number" - input > number (both trimmed for parsing)
         - "gte:number" - input >= number
         - "lt:number" - input < number
         - "lte:number" - input <= number
         - "empty" - input is empty or whitespace only
         - "nonempty" - input has non-whitespace content
         - "startswith:prefix" - input starts with prefix (no trimming)
         - "endswith:suffix" - input ends with suffix (no trimming)
         - "matches:regex" - input matches regex pattern (max 100 chars, ReDoS-protected)
         - Plain text - input contains the text (legacy behavior)

         Whitespace handling:
         - eq/neq: Input is trimmed before comparison
         - gt/gte/lt/lte: Both sides trimmed for numeric parsing
         - contains/startswith/endswith/matches: No trimming (exact match)
         - empty/nonempty: Checks after trimming

         Security:
         - matches: patterns limited to 100 chars
         - matches: catastrophic backtracking patterns (e.g., (a+)+) are rejected
      *)
      let evaluate_condition cond inp =
        let try_parse_float s =
          try Some (float_of_string (String.trim s))
          with Failure _ -> None
        in
        if String.length cond >= 9 && String.sub cond 0 9 = "contains:" then
          let text = String.sub cond 9 (String.length cond - 9) in
          try Str.search_forward (Str.regexp_string text) inp 0 >= 0
          with Not_found -> false
        else if String.length cond >= 3 && String.sub cond 0 3 = "eq:" then
          let value = String.sub cond 3 (String.length cond - 3) in
          String.trim inp = value
        else if String.length cond >= 4 && String.sub cond 0 4 = "neq:" then
          let value = String.sub cond 4 (String.length cond - 4) in
          String.trim inp <> value
        else if String.length cond >= 3 && String.sub cond 0 3 = "gt:" then
          let threshold = String.sub cond 3 (String.length cond - 3) in
          (match try_parse_float inp, try_parse_float threshold with
           | Some v, Some t -> v > t
           | _ -> false)
        else if String.length cond >= 4 && String.sub cond 0 4 = "gte:" then
          let threshold = String.sub cond 4 (String.length cond - 4) in
          (match try_parse_float inp, try_parse_float threshold with
           | Some v, Some t -> v >= t
           | _ -> false)
        else if String.length cond >= 3 && String.sub cond 0 3 = "lt:" then
          let threshold = String.sub cond 3 (String.length cond - 3) in
          (match try_parse_float inp, try_parse_float threshold with
           | Some v, Some t -> v < t
           | _ -> false)
        else if String.length cond >= 4 && String.sub cond 0 4 = "lte:" then
          let threshold = String.sub cond 4 (String.length cond - 4) in
          (match try_parse_float inp, try_parse_float threshold with
           | Some v, Some t -> v <= t
           | _ -> false)
        else if cond = "empty" then
          String.length (String.trim inp) = 0
        else if cond = "nonempty" then
          String.length (String.trim inp) > 0
        else if String.length cond >= 11 && String.sub cond 0 11 = "startswith:" then
          let prefix = String.sub cond 11 (String.length cond - 11) in
          String.length inp >= String.length prefix &&
          String.sub inp 0 (String.length prefix) = prefix
        else if String.length cond >= 9 && String.sub cond 0 9 = "endswith:" then
          let suffix = String.sub cond 9 (String.length cond - 9) in
          String.length inp >= String.length suffix &&
          String.sub inp (String.length inp - String.length suffix) (String.length suffix) = suffix
        else if String.length cond >= 8 && String.sub cond 0 8 = "matches:" then
          let pattern = String.sub cond 8 (String.length cond - 8) in
          (* ReDoS protection: limit pattern length and block catastrophic patterns *)
          let max_pattern_len = 100 in
          let has_redos_pattern p =
            (* Detect patterns that can cause exponential backtracking:
               - Nested quantifiers: (a+)+, (a[*])+, (a+)[*], (a[*])[*]
               - Overlapping alternations with quantifiers *)
            try
              let redos_re = Str.regexp "\\([+*]\\)[+*]\\|[+*])\\+\\|[+*])\\*" in
              Str.search_forward redos_re p 0 >= 0
            with Not_found -> false
          in
          if String.length pattern > max_pattern_len then
            false  (* Pattern too long - reject for safety *)
          else if has_redos_pattern pattern then
            false  (* Potentially catastrophic pattern - reject *)
          else
            (try
              let re = Str.regexp pattern in
              (* Use search_forward for contains-like matching *)
              Str.search_forward re inp 0 >= 0
            with Not_found | Failure _ -> false)
        else
          (* Legacy: plain text means "contains" *)
          try Str.search_forward (Str.regexp_string cond) inp 0 >= 0
          with Not_found -> false
      in
      let result = evaluate_condition condition input in
      let transform = if result then on_true else on_false in
      apply_adapter_transform transform input

  | Split { delimiter; chunk_size; overlap } ->
      (* Split input into chunks for parallel processing.

         Delimiter options:
         - "line" - split by newline (\n)
         - "paragraph" - split by double newline (\n\n)
         - "sentence" - split by sentence endings (. ! ?)
         - custom string - split by literal string

         chunk_size: Maximum size per chunk in estimated tokens (chars/4)
         overlap: Number of overlap tokens between chunks (for context preservation)

         Output: JSON array of chunks
         Example: ["chunk1", "chunk2", "chunk3"]

         Use with Fanout node to process chunks in parallel:
         Doc → Adapter(Split) → Fanout → [LLM×N] → Merge
      *)
      let split_by_delimiter delim text =
        match delim with
        | "line" -> String.split_on_char '\n' text
        | "paragraph" ->
            (* Split by double newline, preserving structure *)
            let re = Str.regexp "\n\n+" in
            Str.split re text
        | "sentence" ->
            (* Split by sentence endings: . ! ? followed by space or newline *)
            let re = Str.regexp "[.!?][ \n]+" in
            Str.split re text
        | custom ->
            (* Split by custom delimiter string *)
            let re = Str.regexp_string custom in
            Str.split re text
      in
      let merge_chunks_by_size chunks max_chars overlap_chars =
        (* Merge small chunks until they reach max_chars, with overlap *)
        let rec merge acc current_chunk = function
          | [] ->
              if String.length current_chunk > 0 then
                List.rev (current_chunk :: acc)
              else
                List.rev acc
          | chunk :: rest ->
              let chunk = String.trim chunk in
              if String.length chunk = 0 then
                merge acc current_chunk rest
              else if String.length current_chunk = 0 then
                merge acc chunk rest
              else if String.length current_chunk + String.length chunk + 1 <= max_chars then
                (* Merge chunks with space separator *)
                merge acc (current_chunk ^ " " ^ chunk) rest
              else
                (* Start new chunk, optionally with overlap from previous *)
                let overlap_text =
                  if overlap_chars > 0 && String.length current_chunk > overlap_chars then
                    let start = String.length current_chunk - overlap_chars in
                    (* Try to find word boundary for overlap *)
                    let overlap_start =
                      try
                        let space_pos = String.rindex_from current_chunk (start + overlap_chars - 1) ' ' in
                        if space_pos >= start then space_pos + 1 else start
                      with Not_found -> start
                    in
                    String.sub current_chunk overlap_start (String.length current_chunk - overlap_start)
                  else
                    ""
                in
                let new_chunk =
                  if String.length overlap_text > 0 then
                    overlap_text ^ " " ^ chunk
                  else
                    chunk
                in
                merge (current_chunk :: acc) new_chunk rest
        in
        merge [] "" chunks
      in
      let max_chars = chunk_size * 4 in  (* Token to char conversion *)
      let overlap_chars = overlap * 4 in
      let raw_chunks = split_by_delimiter delimiter input in
      let sized_chunks = merge_chunks_by_size raw_chunks max_chars overlap_chars in
      (* Return as JSON array *)
      let json_chunks = `List (List.map (fun c -> `String c) sized_chunks) in
      Ok (Yojson.Safe.to_string json_chunks)

  | Custom func_name ->
      (* Custom function placeholder *)
      (match func_name with
       | "identity" -> Ok input
       | "uppercase" -> Ok (String.uppercase_ascii input)
       | "lowercase" -> Ok (String.lowercase_ascii input)
       | "trim" -> Ok (String.trim input)
       | "extract_json" | "extract_json_object" | "extract_json_array" ->
           let len = String.length input in
           let rec find_start i =
             if i >= len then None
             else
               match input.[i] with
               | '{' | '[' -> Some i
               | _ -> find_start (i + 1)
           in
           let extract_from start =
             let open_ch = input.[start] in
             let close_ch = if open_ch = '{' then '}' else ']' in
             let rec scan i depth in_string escape =
               if i >= len then
                 Error "Unbalanced JSON: no closing bracket found"
               else
                 let c = input.[i] in
                 if in_string then
                   if escape then
                     scan (i + 1) depth in_string false
                   else if c = '\\' then
                     scan (i + 1) depth in_string true
                   else if c = '"' then
                     scan (i + 1) depth false false
                   else
                     scan (i + 1) depth in_string false
                 else
                   match c with
                   | '"' -> scan (i + 1) depth true false
                   | _ when c = open_ch ->
                       scan (i + 1) (depth + 1) false false
                   | _ when c = close_ch ->
                       let new_depth = depth - 1 in
                       if new_depth = 0 then
                         Ok (String.sub input start (i - start + 1))
                       else
                         scan (i + 1) new_depth false false
                   | _ ->
                       scan (i + 1) depth false false
             in
             scan start 0 false false
           in
           (match find_start 0 with
            | None -> Error "No JSON object/array found in input"
            | Some start -> extract_from start)
       | "extract_html" ->
           (* Robust HTML extraction for LLM outputs that append metadata.
              Strategy:
              - Find the first <!doctype html ...> or <html ...>
              - Find the next </html>
              - Return that slice if both are present
           *)
           let lower = String.lowercase_ascii input in
           let find_from start needle =
             try Some (Str.search_forward (Str.regexp_string needle) lower start)
             with Not_found -> None
           in
           let start_candidates =
             [ "<!doctype html"; "<html" ]
             |> List.filter_map (find_from 0)
             |> List.sort compare
           in
           (match start_candidates with
            | [] -> Ok input
            | start_pos :: _ -> (
                match find_from start_pos "</html>" with
                | None -> Ok input
                | Some end_pos ->
                    let end_pos = end_pos + String.length "</html>" in
                    if end_pos <= start_pos then Ok input
                    else Ok (String.sub input start_pos (end_pos - start_pos))))
       | "extract_html_field" ->
           (* First try to parse a JSON object with an "html" field.
              If that fails, try extracting the first JSON object/array,
              then fall back to raw HTML extraction. *)
           let parse_html_field s =
             try
               match Yojson.Safe.from_string s with
               | `Assoc fields -> (
                   match List.assoc_opt "html" fields with
                   | Some (`String h) when String.length (String.trim h) > 0 -> Some h
                   | _ -> None)
               | _ -> None
             with _ -> None
           in
           let parse_from_extracted_json () =
             match apply_adapter_transform (Custom "extract_json") input with
             | Ok json_str -> parse_html_field json_str
             | Error _ -> None
           in
           (match parse_html_field input with
            | Some h -> Ok h
            | None -> (
                match parse_from_extracted_json () with
                | Some h -> Ok h
                | None -> apply_adapter_transform (Custom "extract_html") input))
       | "unescape_json_string" ->
           (* Safely unescape common JSON string escape sequences without regex. *)
           let len = String.length input in
           let buf = Buffer.create len in
           let rec loop i =
             if i >= len then ()
             else
               let c = input.[i] in
               if c = '\\' && i + 1 < len then
                 match input.[i + 1] with
                 | 'n' -> Buffer.add_char buf '\n'; loop (i + 2)
                 | 't' -> Buffer.add_char buf '\t'; loop (i + 2)
                 | '"' -> Buffer.add_char buf '"'; loop (i + 2)
                 | '\\' -> Buffer.add_char buf '\\'; loop (i + 2)
                 | _ ->
                     Buffer.add_char buf c;
                     loop (i + 1)
               else (
                 Buffer.add_char buf c;
                 loop (i + 1))
           in
           loop 0;
           Ok (Buffer.contents buf)
       | "figma_summary_to_spec" ->
           (try
             let open Yojson.Safe.Util in
             let json = Yojson.Safe.from_string input in
             let get_string key = Safe_parse.json_string ~context:"FigmaSummary" ~default:"" json key in
             let get_int key = Safe_parse.json_int ~context:"FigmaSummary" ~default:0 json key in
             let get_bool key = Safe_parse.json_bool ~context:"FigmaSummary" ~default:false json key in
             let get_string_opt key = Safe_parse.json_string ~context:"FigmaSummary" ~default:"" json key in
             let name = get_string "name" in
             let typ = get_string "type" in
             let children = Safe_parse.json_list ~context:"FigmaSummary" json "children" in
             let child_entries =
               List.filter_map (fun child ->
                 try
                   let cname = child |> member "name" |> to_string in
                   let ctype = child |> member "type" |> to_string in
                   Some (ctype, cname)
                 with _ -> None
               ) children
             in
             let texts =
               let names =
                 child_entries
                 |> List.map (fun (_, cname) -> cname)
                 |> List.filter (fun s -> s <> "")
               in
               let base = if name <> "" then [name] else [] in
               base @ names
             in
             let structure =
               let root =
                 if typ <> "" || name <> "" then
                   [Printf.sprintf "%s: %s" (if typ = "" then "NODE" else typ) name]
                 else []
               in
               let children_lines =
                 child_entries
                 |> List.map (fun (ctype, cname) ->
                     Printf.sprintf "  - %s: %s" (if ctype = "" then "NODE" else ctype) cname)
               in
               root @ children_lines
             in
             let children_count = get_int "children_count" in
             let truncated = get_bool "truncated" in
             let hint = get_string_opt "hint" in
             let layout_notes =
               let base = Printf.sprintf "children=%d%s"
                 children_count (if truncated then " (truncated)" else "")
               in
               base
             in
             let impl_notes =
               let base = [
                 "Generated from Figma summary; design tokens not available at this depth."
               ] in
               let base =
                 if truncated then
                   base @ ["Summary is truncated; use figma_get_node_chunk for full details."]
                 else base
               in
               let base =
                 if hint <> "" then base @ [hint] else base
               in
               base
             in
             let spec = `Assoc [
               ("component_name", `String name);
               ("component_type", `String typ);
               ("layout", `Assoc [
                 ("type", `String (if typ = "" then "UNKNOWN" else typ));
                 ("notes", `String layout_notes);
               ]);
               ("tokens", `Assoc [
                 ("colors", `List []);
                 ("spacing", `List []);
                 ("typography", `List []);
               ]);
               ("texts", `List (List.map (fun s -> `String s) texts));
               ("structure", `List (List.map (fun s -> `String s) structure));
               ("implementation_notes", `List (List.map (fun s -> `String s) impl_notes));
             ] in
             Ok (Yojson.Safe.to_string spec)
           with _ ->
             Error "Failed to parse figma summary JSON")
       | "reverse" ->
           let chars = String.to_seq input |> List.of_seq |> List.rev in
           Ok (String.of_seq (List.to_seq chars))
       | _ -> Error (Printf.sprintf "Unknown custom function: %s" func_name))
