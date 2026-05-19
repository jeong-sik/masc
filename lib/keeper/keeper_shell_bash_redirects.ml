open Keeper_shell_bash_words

let starts_with_at text ~pos ~prefix =
  let len = String.length prefix in
  pos + len <= String.length text
  && String.equal (String.sub text pos len) prefix

let strip_stderr_dev_null_redirects cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let skip_spaces i =
    let rec loop j =
      if j < len && (Char.equal cmd.[j] ' ' || Char.equal cmd.[j] '\t')
      then loop (j + 1)
      else j
    in
    loop i
  in
  let trim_buffer_trailing_spaces () =
    let rec loop () =
      let len = Buffer.length buf in
      if len > 0
         && (Char.equal (Buffer.nth buf (len - 1)) ' '
             || Char.equal (Buffer.nth buf (len - 1)) '\t')
      then (
        Buffer.truncate buf (len - 1);
        loop ())
    in
    loop ()
  in
  let is_redirect_target_boundary i =
    i >= len
    ||
    match cmd.[i] with
    | ' ' | '\t' | '\n' | '\r' | ';' | '&' | '|' -> true
    | _ -> false
  in
  let is_redirect_start_boundary i =
    i = 0
    ||
    match cmd.[i - 1] with
    | ' ' | '\t' | '\n' | '\r' ->
      let rec previous_non_space j =
        if j < 0
        then None
        else
          match cmd.[j] with
          | ' ' | '\t' | '\n' | '\r' -> previous_non_space (j - 1)
          | ch -> Some ch
      in
      (match previous_non_space (i - 1) with
       | Some '&' -> false
       | _ -> true)
    | ';' | '|' -> true
    | _ -> false
  in
  let skip_dev_null_after op_end =
    let target_start = skip_spaces op_end in
    let target_end = target_start + String.length "/dev/null" in
    if starts_with_at cmd ~pos:target_start ~prefix:"/dev/null"
       && is_redirect_target_boundary target_end
    then Some target_end
    else None
  in
  let stderr_dev_null_redirect_end i =
    if not (is_redirect_start_boundary i)
    then None
    else
      let compact_append_end = i + String.length "2>>/dev/null" in
      let compact_write_end = i + String.length "2>/dev/null" in
      if starts_with_at cmd ~pos:i ~prefix:"2>>/dev/null"
         && is_redirect_target_boundary compact_append_end
      then Some compact_append_end
      else if starts_with_at cmd ~pos:i ~prefix:"2>/dev/null"
              && is_redirect_target_boundary compact_write_end
      then Some compact_write_end
      else if starts_with_at cmd ~pos:i ~prefix:"2>>"
      then skip_dev_null_after (i + 3)
      else if starts_with_at cmd ~pos:i ~prefix:"2>"
      then skip_dev_null_after (i + 2)
      else None
  in
  let rec loop quote_state escaped stripped i =
    if i >= len
    then String.trim (Buffer.contents buf), stripped
    else if escaped
    then (
      Buffer.add_char buf cmd.[i];
      loop quote_state false stripped (i + 1))
    else (
      match quote_state, cmd.[i] with
      | Single_quote, '\'' ->
        Buffer.add_char buf cmd.[i];
        loop No_quote false stripped (i + 1)
      | Single_quote, _ ->
        Buffer.add_char buf cmd.[i];
        loop Single_quote false stripped (i + 1)
      | Double_quote, '"' ->
        Buffer.add_char buf cmd.[i];
        loop No_quote false stripped (i + 1)
      | Double_quote, '\\' ->
        Buffer.add_char buf cmd.[i];
        loop Double_quote true stripped (i + 1)
      | Double_quote, _ ->
        Buffer.add_char buf cmd.[i];
        loop Double_quote false stripped (i + 1)
      | No_quote, '\'' ->
        Buffer.add_char buf cmd.[i];
        loop Single_quote false stripped (i + 1)
      | No_quote, '"' ->
        Buffer.add_char buf cmd.[i];
        loop Double_quote false stripped (i + 1)
      | No_quote, '\\' ->
        Buffer.add_char buf cmd.[i];
        loop No_quote true stripped (i + 1)
      | No_quote, _ ->
        match stderr_dev_null_redirect_end i with
        | Some next ->
          let next = skip_spaces next in
          (if next < len && Char.equal cmd.[next] '&' then (
             trim_buffer_trailing_spaces ();
             if Buffer.length buf > 0 then Buffer.add_char buf ' '));
          loop No_quote false true next
        | None ->
          Buffer.add_char buf cmd.[i];
          loop No_quote false stripped (i + 1))
  in
  loop No_quote false false 0
