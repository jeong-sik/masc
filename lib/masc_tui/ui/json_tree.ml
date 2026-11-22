module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid

type value_display =
  | Object_node of { count : int }
  | Array_node of { count : int }
  | String_val of string
  | Redacted_secret
  | Int_val of int
  | Float_val of float
  | Bool_val of bool
  | Null_val

type line = {
  path : string;
  depth : int;
  key : string option;
  collapsible : bool;
  expanded : bool;
  value : value_display;
}

let equal_value_display a b =
  match (a, b) with
  | Object_node x, Object_node y -> Int.equal x.count y.count
  | Array_node x, Array_node y -> Int.equal x.count y.count
  | String_val x, String_val y -> String.equal x y
  | Redacted_secret, Redacted_secret -> true
  | Int_val x, Int_val y -> Int.equal x y
  | Float_val x, Float_val y -> Float.equal x y
  | Bool_val x, Bool_val y -> Bool.equal x y
  | Null_val, Null_val -> true
  | ( Object_node _
    | Array_node _
    | String_val _
    | Redacted_secret
    | Int_val _
    | Float_val _
    | Bool_val _
    | Null_val ),
    _ ->
      false

let equal_line a b =
  String.equal a.path b.path
  && Int.equal a.depth b.depth
  && Option.equal String.equal a.key b.key
  && Bool.equal a.collapsible b.collapsible
  && Bool.equal a.expanded b.expanded
  && equal_value_display a.value b.value

let contains_substring ~needle ~haystack =
  let n_len = String.length needle in
  let h_len = String.length haystack in
  if n_len = 0 then true
  else if n_len > h_len then false
  else
    let rec scan i =
      if i + n_len > h_len then false
      else
        let rec match_at k =
          if k >= n_len then true
          else if Char.equal haystack.[i + k] needle.[k] then match_at (k + 1)
          else false
        in
        if match_at 0 then true else scan (i + 1)
    in
    scan 0

let split_key_segments s =
  let len = String.length s in
  let rec scan start i acc =
    if i >= len then
      let acc =
        if i > start then String.sub s start (i - start) :: acc else acc
      in
      List.rev acc
    else
      match s.[i] with
      | '_' | '-' | '.' | ' ' | '/' | ':' ->
          let acc =
            if i > start then String.sub s start (i - start) :: acc else acc
          in
          scan (i + 1) (i + 1) acc
      | _ -> scan start (i + 1) acc
  in
  scan 0 0 []

let safe_metadata_suffixes =
  [
    "_env"; "-env"; "_file"; "-file"; "_path"; "-path"; "_count"; "-count";
    "_counts"; "_limit"; "-limit"; "_budget"; "_rate"; "_per_sec"; "_usage";
    "-usage"; "_tokens"; "-tokens"; "_len"; "_length"; "_size"; "_hash";
    "_sha256"; "_id"; "_ids"; "_name"; "_names"; "_type"; "_kind"; "_mode";
    "_source"; "_header"; "_prefix"; "_set"; "_present"; "_configured";
  ]

let exact_non_secret_keys =
  [
    "tokens"; "token_usage"; "token_count"; "tokens_per_sec";
    "input_tokens"; "output_tokens"; "cache_read_tokens"; "cache_write_tokens";
    "max_tokens"; "total_tokens"; "prompt_tokens"; "completion_tokens";
    "context_tokens";
  ]

let secret_key_needles =
  [
    "secret"; "password"; "passwd"; "passphrase"; "credential";
    "api_key"; "api-key"; "apikey"; "access_key"; "access-key";
    "private_key"; "private-key"; "signing_key"; "signing-key";
    "encryption_key"; "encryption-key"; "authorization"; "bearer";
  ]

let is_secret_key key =
  let lower = String.lowercase_ascii (String.trim key) in
  if String.length lower = 0 then false
  else if List.exists (String.equal lower) exact_non_secret_keys then false
  else if
    List.exists (fun suffix -> String.ends_with ~suffix lower) safe_metadata_suffixes
  then false
  else if
    List.exists
      (fun needle -> contains_substring ~needle ~haystack:lower)
      secret_key_needles
  then true
  else
    let segs = split_key_segments lower in
    let has_pat_seg = List.exists (String.equal "pat") segs in
    let is_credential_token =
      String.equal lower "token"
      || String.ends_with ~suffix:"_token" lower
      || String.ends_with ~suffix:"-token" lower
    in
    has_pat_seg || is_credential_token

let is_alnum_ascii c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

let is_upper_alnum_ascii c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

let has_url_credentials s =
  let len = String.length s in
  let rec find_scheme i =
    if i + 3 > len then None
    else if
      Char.equal s.[i] ':' && Char.equal s.[i + 1] '/' && Char.equal s.[i + 2] '/'
    then Some (i + 3)
    else find_scheme (i + 1)
  in
  match find_scheme 0 with
  | None -> false
  | Some after_scheme ->
      (* Find '@' before authority ends ('/', '?', '#', whitespace). *)
      let rec scan i colon_idx =
        if i >= len then false
        else
          match s.[i] with
          | '/' | '?' | '#' | ' ' | '\t' | '\n' | '\r' -> false
          | ':' ->
              let next_colon =
                match colon_idx with None -> Some i | Some _ as c -> c
              in
              scan (i + 1) next_colon
          | '@' -> (
              match colon_idx with
              | Some c -> c > after_scheme && i > c + 1
              | None -> false)
          | _ -> scan (i + 1) colon_idx
      in
      scan after_scheme None

let is_secret_value raw =
  let s = String.trim raw in
  let len = String.length s in
  if len < 8 then false
  else
    let lower = String.lowercase_ascii s in
    let has_prefix p = String.starts_with ~prefix:p s in
    if
      has_prefix "sk-"
      || has_prefix "sk_live_"
      || has_prefix "sk_test_"
      || has_prefix "rk_live_"
      || has_prefix "ghp_"
      || has_prefix "gho_"
      || has_prefix "ghu_"
      || has_prefix "ghs_"
      || has_prefix "ghr_"
      || has_prefix "github_pat_"
      || has_prefix "xoxb-"
      || has_prefix "xoxp-"
      || has_prefix "xoxa-"
      || has_prefix "xoxr-"
      || has_prefix "xoxs-"
    then true
    else if
      (has_prefix "AKIA" || has_prefix "ASIA")
      && len >= 16
      &&
      let ok = ref true in
      for i = 4 to 15 do
        if not (is_upper_alnum_ascii s.[i]) then ok := false
      done;
      !ok
    then true
    else if
      String.starts_with ~prefix:"bearer " lower
      &&
      let rest = String.trim (String.sub s 7 (len - 7)) in
      String.length rest >= 6 && is_alnum_ascii rest.[0]
    then true
    else if
      contains_substring ~needle:"-----BEGIN " ~haystack:s
      && contains_substring ~needle:"PRIVATE KEY-----" ~haystack:s
    then true
    else has_url_credentials s

let toggle_path path ~collapsed =
  if List.exists (String.equal path) collapsed then
    List.filter (fun p -> not (String.equal p path)) collapsed
  else path :: collapsed

let flatten ?(max_depth = 8) ?(collapsed = []) ?(redact_secrets = true) json =
  let is_collapsed path depth =
    depth >= max_depth || List.exists (String.equal path) collapsed
  in
  let acc = ref [] in
  let push line = acc := line :: !acc in
  let rec visit ~path ~depth ~key ~in_secret_container (node : Yojson.Safe.t) =
    let key_is_secret =
      redact_secrets
      &&
      match key with
      | Some k -> is_secret_key k
      | None -> false
    in
    let next_secret_container = in_secret_container || key_is_secret in
    match node with
    | `Assoc fields ->
        let count = List.length fields in
        let collapsible = count > 0 in
        let expanded = collapsible && not (is_collapsed path depth) in
        push
          {
            path;
            depth;
            key;
            collapsible;
            expanded;
            value = Object_node { count };
          };
        if expanded then
          List.iter
            (fun (k, v) ->
              visit ~path:(path ^ "." ^ k) ~depth:(depth + 1) ~key:(Some k)
                ~in_secret_container:next_secret_container v)
            fields
    | `List items ->
        let count = List.length items in
        let collapsible = count > 0 in
        let expanded = collapsible && not (is_collapsed path depth) in
        push
          {
            path;
            depth;
            key;
            collapsible;
            expanded;
            value = Array_node { count };
          };
        if expanded then
          List.iteri
            (fun idx v ->
              visit
                ~path:(Printf.sprintf "%s[%d]" path idx)
                ~depth:(depth + 1) ~key:(Some (Printf.sprintf "[%d]" idx))
                ~in_secret_container:next_secret_container v)
            items
    | `String s ->
        let should_redact =
          redact_secrets
          && (key_is_secret || in_secret_container || is_secret_value s)
        in
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = (if should_redact then Redacted_secret else String_val s);
          }
    | `Int i ->
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = Int_val i;
          }
    | `Intlit s ->
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = String_val s;
          }
    | `Float f ->
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = Float_val f;
          }
    | `Bool b ->
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = Bool_val b;
          }
    | `Null ->
        push
          {
            path;
            depth;
            key;
            collapsible = false;
            expanded = false;
            value = Null_val;
          }
  in
  visit ~path:"$" ~depth:0 ~key:None ~in_secret_container:false json;
  List.rev !acc

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ?(scroll = 0) ?selected
    (lines : line list) =
  let total = List.length lines in
  if Rect.is_empty rect || total = 0 then total
  else
    let arr = Array.of_list lines in
    let max_start = Int.max 0 (total - rect.h) in
    let start = Int.max 0 (Int.min max_start scroll) in
    let visible = Int.min rect.h (total - start) in
    for i = 0 to visible - 1 do
      let idx = start + i in
      let line = arr.(idx) in
      let py = rect.y + i in
      let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      let is_selected =
        match selected with Some s -> Int.equal s idx | None -> false
      in
      let bg_rgb = if is_selected then theme.selection_bg else theme.surface_1 in
      let bg = Color.of_rgb bg_rgb in
      let fill_style =
        Style.make
          ~fg:(Color.of_rgb (if is_selected then theme.text_bright else theme.text_primary))
          ~bg ()
      in
      Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:fill_style ();
      (* Preserve calibrated semantic syntax hues on calm selection_bg *)
      let muted_style = Style.make ~fg:(Color.of_rgb theme.text_muted) ~bg () in
      let key_style =
        Style.make ~fg:(Color.of_rgb theme.status_active) ~bg
          ~attrs:(if is_selected then Attr.bold else Attr.none) ()
      in
      let str_style = Style.make ~fg:(Color.of_rgb theme.status_ok) ~bg () in
      let num_style = Style.make ~fg:(Color.of_rgb theme.status_attention) ~bg () in
      let lit_style =
        Style.make ~fg:(Color.of_rgb theme.accent) ~bg ~attrs:Attr.bold ()
      in
      let redact_style =
        Style.make ~fg:(Color.of_rgb theme.status_attention) ~bg ~attrs:Attr.bold ()
      in
      let has_selection_gutter = Option.is_some selected in
      let cx = ref (if has_selection_gutter then rect.x + 2 else rect.x) in
      let limit = Rect.right rect in
      if is_selected then
        Cell_grid.put_glyph ~clip:row_rect grid ~x:rect.x ~y:py
          ~style:(Style.make ~fg:(Color.of_rgb theme.accent) ~bg ~attrs:Attr.bold ())
          Glyph.Left_rail;
      (* Indent guides *)
      for _ = 1 to line.depth do
        if !cx + 2 <= limit then begin
          Cell_grid.put_glyph ~clip:row_rect grid ~x:!cx ~y:py ~style:muted_style
            Glyph.Tree_pipe;
          cx := !cx + 2
        end
      done;
      (* Expand/collapse indicator *)
      if !cx + 2 <= limit then begin
        if line.collapsible then
          let g =
            if line.expanded then Glyph.Expand_open else Glyph.Expand_closed
          in
          Cell_grid.put_glyph ~clip:row_rect grid ~x:!cx ~y:py ~style:muted_style g
        else
          Cell_grid.put_glyph ~clip:row_rect grid ~x:!cx ~y:py ~style:muted_style
            Glyph.Separator_dot;
        cx := !cx + 2
      end;
      (* Optional key *)
      (match line.key with
       | Some k when !cx < limit ->
           let adv_k =
             Cell_grid.put_text ~clip:row_rect grid ~x:!cx ~y:py ~style:key_style k
           in
           cx := !cx + adv_k;
           let adv_sep =
             Cell_grid.put_text ~clip:row_rect grid ~x:!cx ~y:py
               ~style:muted_style ": "
           in
           cx := !cx + adv_sep
       | Some _ | None -> ());
      (* Value display *)
      let avail = Int.max 0 (limit - !cx) in
      if avail > 0 then
        let put_val style s =
          let fit = Grapheme.truncate_to_width ~max_width:avail s in
          ignore (Cell_grid.put_text ~clip:row_rect grid ~x:!cx ~y:py ~style fit)
        in
        match line.value with
        | Object_node { count } ->
            let summary =
              if line.expanded then Printf.sprintf "{%d}" count
              else Printf.sprintf "{%d keys}" count
            in
            put_val muted_style summary
        | Array_node { count } ->
            let summary =
              if line.expanded then Printf.sprintf "[%d]" count
              else Printf.sprintf "[%d items]" count
            in
            put_val muted_style summary
        | String_val s -> put_val str_style (Printf.sprintf "\"%s\"" s)
        | Redacted_secret -> put_val redact_style "[redacted]"
        | Int_val n -> put_val num_style (Int.to_string n)
        | Float_val f -> put_val num_style (Printf.sprintf "%g" f)
        | Bool_val b -> put_val lit_style (if b then "true" else "false")
        | Null_val -> put_val lit_style "null"
    done;
    total
