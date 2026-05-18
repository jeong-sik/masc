open Keeper_shell_bash_words

type t = {
  primary_cmd : string;
}

let primary_rewrite ~shape_block_of_command primary_cmd =
  match shape_block_of_command primary_cmd with
  | Some _ -> None
  | None ->
    if Worker_dev_tools.is_write_operation primary_cmd
    then None
    else (
      match
        Worker_dev_tools.validate_command_coding_with_allowlist
          ~allow_pipes:false
          ~allowed_commands:Worker_dev_tools.dev_allowed_commands
          primary_cmd
      with
      | Ok () -> Some { primary_cmd }
      | Error _ -> None)

let find_unquoted_logic_or cmd =
  let len = String.length cmd in
  let rec loop quote_state escaped i =
    if i + 1 >= len
    then None
    else if escaped
    then loop quote_state false (i + 1)
    else (
      match quote_state, cmd.[i] with
      | Single_quote, '\'' -> loop No_quote false (i + 1)
      | Single_quote, _ -> loop Single_quote false (i + 1)
      | Double_quote, '"' -> loop No_quote false (i + 1)
      | Double_quote, '\\' -> loop Double_quote true (i + 1)
      | Double_quote, _ -> loop Double_quote false (i + 1)
      | No_quote, '\'' -> loop Single_quote false (i + 1)
      | No_quote, '"' -> loop Double_quote false (i + 1)
      | No_quote, '\\' -> loop No_quote true (i + 1)
      | No_quote, '|' when Char.equal cmd.[i + 1] '|' -> Some i
      | No_quote, _ -> loop No_quote false (i + 1))
  in
  loop No_quote false 0

let strip_suffix_ci text suffix =
  let text_len = String.length text in
  let suffix_len = String.length suffix in
  if suffix_len > text_len
  then None
  else (
    let tail = String.sub text (text_len - suffix_len) suffix_len in
    if String.equal (String.lowercase_ascii tail) suffix
    then Some (String.sub text 0 (text_len - suffix_len) |> String.trim)
    else None)

let strip_trailing_dev_null_redirect cmd =
  let cmd = String.trim cmd in
  [
    "2>/dev/null";
    "1>/dev/null";
    ">/dev/null";
    "2>>/dev/null";
    "1>>/dev/null";
    ">>/dev/null";
    "2> /dev/null";
    "1> /dev/null";
    "> /dev/null";
    "2>> /dev/null";
    "1>> /dev/null";
    ">> /dev/null";
  ]
  |> List.find_map (strip_suffix_ci cmd)
  |> function
  | Some primary when not (String.equal primary "") -> Some primary
  | Some _ | None -> None

let literal_echo_is_safe text =
  match Masc_exec_bash_parser.Bash.parse_string text with
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple simple)
    when simple.env = []
         && simple.redirects = []
         && Option.is_none simple.cwd
         && String.equal (Masc_exec.Bin.to_string simple.bin) "echo" ->
    let rec literal_arg_text = function
      | Masc_exec.Shell_ir.Lit arg -> Some arg
      | Masc_exec.Shell_ir.Concat parts ->
        let rec loop acc = function
          | [] -> Some (String.concat "" (List.rev acc))
          | part :: rest ->
            (match literal_arg_text part with
             | Some text -> loop (text :: acc) rest
             | None -> None)
        in
        loop [] parts
      | Masc_exec.Shell_ir.Var _ -> None
    in
    let rec loop = function
      | [] -> true
      | arg :: rest ->
        (match literal_arg_text arg with
         | Some text -> (not (String.starts_with ~prefix:"-" text)) && loop rest
         | None -> false)
    in
    loop simple.args
  | _ -> false

let or_echo_fallback_of_command ~shape_block_of_command cmd =
  match find_unquoted_logic_or cmd with
  | None -> None
  | Some split ->
    let left = String.sub cmd 0 split in
    let right =
      String.sub cmd (split + 2) (String.length cmd - split - 2) |> String.trim
    in
    if not (literal_echo_is_safe right)
    then None
    else
      let primary_cmd =
        match strip_trailing_dev_null_redirect left with
        | Some primary -> Some primary
        | None ->
          let primary = String.trim left in
          if String.equal primary "" then None else Some primary
      in
      Option.bind primary_cmd (primary_rewrite ~shape_block_of_command)

let of_command ~shape_block_of_command ~write_enabled:_ ~stderr_dev_null_stripped cmd =
  match or_echo_fallback_of_command ~shape_block_of_command cmd with
  | Some _ as rewrite -> rewrite
  | None ->
    (match strip_trailing_dev_null_redirect cmd with
     | Some primary_cmd -> primary_rewrite ~shape_block_of_command primary_cmd
     | None ->
       if stderr_dev_null_stripped
       then primary_rewrite ~shape_block_of_command cmd
       else None)
