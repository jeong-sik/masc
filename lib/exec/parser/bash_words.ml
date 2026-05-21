type word = {
  value : string;
  quoted : bool;
  escaped : bool;
  globbed : bool;
  braced : bool;
}

type error =
  | Unclosed_quote
  | Trailing_escape

type quote =
  | No_quote
  | Single_quote
  | Double_quote

let make_word ~value ~quoted ~escaped ~globbed ~braced =
  { value; quoted; escaped; globbed; braced }
;;

let stages source =
  let len = String.length source in
  let buf = Buffer.create 32 in
  let quoted = ref false in
  let escaped = ref false in
  let globbed = ref false in
  let braced = ref false in
  let current = ref [] in
  let stages = ref [] in
  let reset_word_flags () =
    quoted := false;
    escaped := false;
    globbed := false;
    braced := false
  in
  let push_word () =
    if Buffer.length buf > 0 || !quoted || !escaped || !globbed || !braced
    then (
      let word =
        make_word
          ~value:(Buffer.contents buf)
          ~quoted:!quoted
          ~escaped:!escaped
          ~globbed:!globbed
          ~braced:!braced
      in
      current := word :: !current;
      Buffer.clear buf;
      reset_word_flags ())
  in
  let push_stage () =
    push_word ();
    match !current with
    | [] -> ()
    | words ->
      stages := List.rev words :: !stages;
      current := []
  in
  let rec scan quote i =
    if i >= len
    then (
      match quote with
      | Single_quote | Double_quote -> Error Unclosed_quote
      | No_quote ->
        push_stage ();
        Ok (List.rev !stages))
    else (
      match quote, source.[i] with
      | No_quote, (' ' | '\t' | '\n' | '\r') ->
        push_word ();
        scan No_quote (i + 1)
      | No_quote, '\'' ->
        quoted := true;
        scan Single_quote (i + 1)
      | No_quote, '"' ->
        quoted := true;
        scan Double_quote (i + 1)
      | No_quote, '|' ->
        push_stage ();
        scan No_quote (i + 1)
      | Single_quote, '\'' -> scan No_quote (i + 1)
      | Double_quote, '"' -> scan No_quote (i + 1)
      | _, '\\' ->
        escaped := true;
        if i + 1 < len
        then (
          Buffer.add_char buf source.[i + 1];
          scan quote (i + 2))
        else Error Trailing_escape
      | _, ('*' | '?' | '[' | ']') ->
        globbed := true;
        Buffer.add_char buf source.[i];
        scan quote (i + 1)
      | _, ('{' | '}') ->
        braced := true;
        Buffer.add_char buf source.[i];
        scan quote (i + 1)
      | _, ch ->
        Buffer.add_char buf ch;
        scan quote (i + 1))
  in
  scan No_quote 0
;;
