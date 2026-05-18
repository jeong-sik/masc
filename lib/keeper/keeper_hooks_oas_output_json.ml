(** Output JSON and command parsers used by keeper OAS hook metrics. *)

let json_int_opt key json = Safe_ops.json_int_opt key json

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let observe_output_parse_failure ~surface ~output_bytes =
  Safe_ops.protect ~default:() (fun () ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_oas_hook_output_parse_failures
        ~labels:[ (Keeper_hooks_oas_types.label_surface, surface) ] ());
  Safe_ops.protect ~default:() (fun () ->
      Log.Keeper.warn
        "keeper_hooks_oas output JSON parse failed: surface=%s output_bytes=%d"
        surface output_bytes)

let find_substring_from text ~needle ~start =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then Some i
    else if i + needle_len > text_len then None
    else if String.sub text i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop start

let strip_fence_language block =
  let block = String.trim block in
  match String.index_opt block '\n' with
  | None -> block
  | Some first_line_end ->
      let first_line =
        String.sub block 0 first_line_end
        |> String.trim
        |> String.lowercase_ascii
      in
      let rest =
        String.sub block (first_line_end + 1)
          (String.length block - first_line_end - 1)
        |> String.trim
      in
      if first_line = "json" || first_line = "jsonc" then rest else block

let fenced_json_candidates text =
  let fence = "```" in
  let rec loop start acc =
    match find_substring_from text ~needle:fence ~start with
    | None -> List.rev acc
    | Some open_at ->
        let content_start = open_at + String.length fence in
        (match find_substring_from text ~needle:fence ~start:content_start with
         | None -> List.rev acc
         | Some close_at ->
             let raw =
               String.sub text content_start (close_at - content_start)
               |> strip_fence_language
             in
             let acc = if raw = "" then acc else raw :: acc in
             loop (close_at + String.length fence) acc)
  in
  loop 0 []

let json_close_for_open = function
  | '{' -> Some '}'
  | '[' -> Some ']'
  | _ -> None

let balanced_json_candidates text =
  let len = String.length text in
  let rec finish_candidate i in_string escaped stack =
    if i >= len then None
    else
      let ch = text.[i] in
      if in_string then
        if escaped then finish_candidate (i + 1) true false stack
        else
          match ch with
          | '\\' -> finish_candidate (i + 1) true true stack
          | '"' -> finish_candidate (i + 1) false false stack
          | _ -> finish_candidate (i + 1) true false stack
      else
        match ch with
        | '"' -> finish_candidate (i + 1) true false stack
        | '{' | '[' ->
            (match json_close_for_open ch with
             | None -> finish_candidate (i + 1) false false stack
             | Some close ->
                 finish_candidate (i + 1) false false (close :: stack))
        | '}' | ']' ->
            (match stack with
             | close :: rest when close = ch ->
                 if rest = [] then Some i
                 else finish_candidate (i + 1) false false rest
             | _ -> None)
        | _ -> finish_candidate (i + 1) false false stack
  in
  let rec loop i acc =
    if i >= len then List.rev acc
    else
      match json_close_for_open text.[i] with
      | None -> loop (i + 1) acc
      | Some expected ->
          (match finish_candidate (i + 1) false false [ expected ] with
           | None -> loop (i + 1) acc
           | Some close_at ->
               let candidate =
                 String.sub text i (close_at - i + 1)
                 |> String.trim
               in
               loop (close_at + 1) (candidate :: acc))
  in
  loop 0 []

let parse_json_candidate ~surface candidate =
  Safe_ops.parse_json_safe
    ~context:("Keeper_hooks_oas." ^ surface ^ ".output.embedded")
    candidate

let output_json_opt ?(observe_failure = true) ~surface output_text =
  match
    Safe_ops.parse_json_safe
      ~context:("Keeper_hooks_oas." ^ surface ^ ".output")
      output_text
  with
  | Ok json -> Some json
  | Error _ ->
      let candidates =
        fenced_json_candidates output_text @ balanced_json_candidates output_text
      in
      (match
         List.find_map
           (fun candidate ->
              match parse_json_candidate ~surface candidate with
              | Ok json -> Some json
              | Error _ -> None)
           candidates
       with
       | Some json -> Some json
       | None ->
           if observe_failure then
             observe_output_parse_failure ~surface
               ~output_bytes:(String.length output_text);
           None)

let normalized_route_via raw =
  let value = String.trim raw |> String.lowercase_ascii in
  if value = "" then None else Some value

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let route_via_of_json json =
  let direct key =
    match assoc_field key json with
    | Some (`String value) -> normalized_route_via value
    | _ -> None
  in
  let nested parent key =
    match assoc_field parent json with
    | Some nested_json ->
        (match assoc_field key nested_json with
         | Some (`String value) -> normalized_route_via value
         | _ -> None)
    | None -> None
  in
  [
    direct "via";
    direct "execution_via";
    direct "route_via";
    nested "route" "via";
    nested "route" "execution_via";
    nested "route" "route_via";
    nested "metadata" "via";
    nested "metadata" "execution_via";
    nested "metadata" "route_via";
    nested "tool_metadata" "via";
    nested "tool_metadata" "execution_via";
    nested "tool_metadata" "route_via";
  ]
  |> List.find_map Fun.id

let non_empty_string_opt = function
  | Some value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | None -> None

let string_field_opt key json = Safe_ops.json_string_opt key json |> non_empty_string_opt

let nested_string_field_opt parent key json =
  match assoc_field parent json with
  | Some nested_json -> string_field_opt key nested_json
  | None -> None

let github_pr_url_from_text raw =
  let normalized =
    raw
    |> String.map (function
         | '\n' | '\r' | '\t' | '"' | '\'' -> ' '
         | ch -> ch)
  in
  normalized
  |> String.split_on_char ' '
  |> List.find_map (fun token ->
       let token = String.trim token in
       if
         String.starts_with ~prefix:"https://github.com/" token
         && String_util.contains_substring token "/pull/"
       then Some token
       else None)

let pr_url_of_json json =
  [
    string_field_opt "pr_url" json;
    string_field_opt "pull_request_url" json;
    string_field_opt "url" json;
    string_field_opt "html_url" json;
    string_field_opt "output" json;
    nested_string_field_opt "result" "pr_url" json;
    nested_string_field_opt "result" "pull_request_url" json;
    nested_string_field_opt "result" "url" json;
    nested_string_field_opt "result" "html_url" json;
    nested_string_field_opt "result" "output" json;
    nested_string_field_opt "route_evidence" "pr_url" json;
  ]
  |> List.find_map (function
       | None -> None
       | Some value -> github_pr_url_from_text value)

let pr_create_ref_of_input input =
  [
    string_field_opt "head" input;
    string_field_opt "branch" input;
    string_field_opt "head_ref" input;
  ]
  |> List.find_map Fun.id

let command_input_of_tool ~(tool_name : string) (input : Yojson.Safe.t) =
  match tool_name with
  | "keeper_shell" ->
      let op =
        Safe_ops.json_string ~default:"" "op" input
        |> String.trim |> String.lowercase_ascii
      in
      if op = "gh" then
        Safe_ops.json_string_opt "cmd" input
        |> Option.map (fun cmd -> "gh " ^ String.trim cmd)
      else None
  | "keeper_bash" ->
      Safe_ops.json_string_opt "cmd" input
  | "masc_code_shell" ->
      Safe_ops.json_string_opt "command" input
  | _ -> None

let output_command_of_json = function
  | Some json -> Safe_ops.json_string_opt "command" json
  | None -> None

let command_candidates_of_tool_io ~tool_name ~input ~output_json =
  let add_candidate candidate acc =
    match candidate with
    | None -> acc
    | Some value ->
        let command = String.trim value in
        if command = "" || List.mem command acc then acc else acc @ [ command ]
  in
  []
  |> add_candidate (command_input_of_tool ~tool_name input)
  |> add_candidate (output_command_of_json output_json)

let shell_words_prefix ?(max_words = 8) command =
  let len = String.length command in
  let buf = Buffer.create 32 in
  let push acc =
    if Buffer.length buf = 0 then acc
    else
      let word = Buffer.contents buf in
      Buffer.clear buf;
      word :: acc
  in
  let rec loop acc i in_single in_double escaped =
    if i >= len || List.length acc >= max_words then List.rev (push acc)
    else
      let c = command.[i] in
      if escaped then (
        Buffer.add_char buf c;
        loop acc (i + 1) in_single in_double false)
      else
        match c with
        | '\\' when not in_single ->
            loop acc (i + 1) in_single in_double true
        | '\'' when not in_double ->
            loop acc (i + 1) (not in_single) in_double false
        | '"' when not in_single ->
            loop acc (i + 1) in_single (not in_double) false
        | ' ' | '\t' | '\r' | '\n' when (not in_single) && not in_double ->
            let acc = push acc in
            loop acc (i + 1) in_single in_double false
        | _ ->
            Buffer.add_char buf c;
            loop acc (i + 1) in_single in_double false
  in
  loop [] 0 false false false

let gh_argv_of_segment segment =
  match Keeper_gh_shared.parse_simple_gh_command segment with
  | Ok cmd -> Some (Keeper_gh_shared.gh_simple_command_argv cmd)
  | Error _ ->
      (match shell_words_prefix segment with
       | bin :: args when String.equal (String.lowercase_ascii bin) "gh" ->
           Some args
       | _ -> None)

let gh_pr_review_action_of_command command =
  match gh_argv_of_segment command with
  | Some (subcommand :: action :: pr_number :: args)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "review" ->
      let has_flag flag =
        List.exists
          (fun arg -> String.equal (String.lowercase_ascii arg) flag)
          args
      in
      let action =
        if has_flag "--approve" then Some "APPROVE"
        else if has_flag "--request-changes" then Some "REQUEST_CHANGES"
        else if has_flag "--comment" then Some "COMMENT"
        else None
      in
      Option.map (fun action -> (action, int_of_string_opt pr_number)) action
  | Some (subcommand :: action :: pr_number :: _)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "comment" ->
      Some ("COMMENT", int_of_string_opt pr_number)
  | _ -> None

let assoc_json_opt key json =
  match assoc_field key json with
  | Some (`Assoc _ as value) -> Some value
  | _ -> None

let output_success ~transport_success = function
  | Some json ->
      (match Safe_ops.json_bool_opt "ok" json with
       | Some value -> value
       | None ->
           let status =
             Safe_ops.json_string ~default:"" "status" json
             |> String.trim |> String.lowercase_ascii
           in
           if status = "ok" then true else transport_success)
  | None -> transport_success
