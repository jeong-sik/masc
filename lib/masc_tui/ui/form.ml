module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Input = Masc_tui_term.Input_decoder

type provenance =
  | Prov_default
  | Prov_global_toml
  | Prov_keeper_toml of string
  | Prov_env of string
  | Prov_tui_pref

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

type section_header = {
  title : Say.t;
  canonical_prefix : string option;
  provenance : provenance;
  reload_scope : reload_scope;
}

type field_value =
  | Text_val of string
  | Multiline_val of string
  | Int_val of { raw : string; parsed : int option }
  | Float_val of { raw : string; parsed : float option }
  | Bool_val of bool
  | Enum_val of { selected : int; options : (string * Say.t) array }
  | Secret_val of { raw : string; revealed : bool }

type validator =
  | Required
  | Int_range of { min : int option; max : int option }
  | Float_range of { min : float option; max : float option }
  | Min_length of int
  | Max_length of int
  | Custom of (field_value -> Say.t option)

type field = {
  key : string;
  label : Say.t;
  help : Say.t option;
  value : field_value;
  initial : field_value;
  provenance : provenance;
  reload_scope : reload_scope;
  validators : validator list;
  read_only : bool;
  error : Say.t option;
}

type state = {
  fields : field array;
  focused : int;
  editing : bool;
  filter : string;
}

let int_val n = Int_val { raw = Int.to_string n; parsed = Some n }

let int_val_of_raw raw =
  let trimmed = String.trim raw in
  let parsed =
    if String.length trimmed = 0 then None else int_of_string_opt trimmed
  in
  Int_val { raw; parsed }

let float_val f =
  let raw = Printf.sprintf "%g" f in
  let parsed = if Float.is_finite f then Some f else None in
  Float_val { raw; parsed }

let float_val_of_raw raw =
  let trimmed = String.trim raw in
  let parsed =
    if String.length trimmed = 0 then None
    else
      match float_of_string_opt trimmed with
      | Some f when Float.is_finite f -> Some f
      | Some _ | None -> None
  in
  Float_val { raw; parsed }

let enum_val ~selected opts =
  let arr = Array.of_list opts in
  let n = Array.length arr in
  let clamped = if n = 0 then 0 else Int.max 0 (Int.min (n - 1) selected) in
  Enum_val { selected = clamped; options = arr }

let secret_val ?(revealed = false) raw = Secret_val { raw; revealed }

let equal_provenance a b =
  match (a, b) with
  | Prov_default, Prov_default
  | Prov_global_toml, Prov_global_toml
  | Prov_tui_pref, Prov_tui_pref ->
      true
  | Prov_keeper_toml x, Prov_keeper_toml y -> String.equal x y
  | Prov_env x, Prov_env y -> String.equal x y
  | ( Prov_default
    | Prov_global_toml
    | Prov_keeper_toml _
    | Prov_env _
    | Prov_tui_pref ),
    _ ->
      false

let reload_scope_rank = function
  | Hot_reload -> 0
  | Next_turn -> 1
  | Restart_required -> 2

let equal_reload_scope a b =
  Int.equal (reload_scope_rank a) (reload_scope_rank b)

let equal_field_value a b =
  match (a, b) with
  | Text_val x, Text_val y -> String.equal x y
  | Multiline_val x, Multiline_val y -> String.equal x y
  | Int_val x, Int_val y ->
      String.equal x.raw y.raw && Option.equal Int.equal x.parsed y.parsed
  | Float_val x, Float_val y ->
      String.equal x.raw y.raw && Option.equal Float.equal x.parsed y.parsed
  | Bool_val x, Bool_val y -> Bool.equal x y
  | Enum_val x, Enum_val y -> Int.equal x.selected y.selected
  | Secret_val x, Secret_val y -> String.equal x.raw y.raw
  | ( Text_val _
    | Multiline_val _
    | Int_val _
    | Float_val _
    | Bool_val _
    | Enum_val _
    | Secret_val _ ),
    _ ->
      false

let strip_key_prefix ~prefix key =
  let plen = String.length prefix in
  if plen = 0 then key
  else
    let with_dot =
      if Char.equal prefix.[plen - 1] '.' then prefix else prefix ^ "."
    in
    let dlen = String.length with_dot in
    if String.starts_with ~prefix:with_dot key && String.length key > dlen then
      String.sub key dlen (String.length key - dlen)
    else key

let make_field ~key ~label ?help ?(provenance = Prov_default)
    ?(reload_scope = Hot_reload) ?(validators = []) ?(read_only = false) value =
  {
    key;
    label;
    help;
    value;
    initial = value;
    provenance;
    reload_scope;
    validators;
    read_only;
    error = None;
  }

let create fields =
  { fields = Array.of_list fields; focused = 0; editing = false; filter = "" }

let masked_display raw =
  let n = String.length raw in
  if n = 0 then "(empty)"
  else
    let dots = Int.min 8 (Int.max 4 n) in
    let mask =
      String.concat ""
        (List.init dots (fun _ -> Glyph.to_utf8 Glyph.Live_healthy))
    in
    Printf.sprintf "%s (%d)" mask n

let provenance_label = function
  | Prov_default -> Say.make ~ko:"기본값" ~en:"Default"
  | Prov_global_toml -> Say.make ~ko:"전역 TOML" ~en:"Global TOML"
  | Prov_keeper_toml k ->
      Say.make
        ~ko:(Printf.sprintf "키퍼:%s" k)
        ~en:(Printf.sprintf "Keeper:%s" k)
  | Prov_env e ->
      Say.make ~ko:(Printf.sprintf "환경:%s" e) ~en:(Printf.sprintf "Env:%s" e)
  | Prov_tui_pref -> Say.make ~ko:"TUI 설정" ~en:"TUI Pref"

let reload_scope_label = function
  | Hot_reload ->
      Say.make
        ~ko:(Glyph.to_utf8 Glyph.Live_healthy ^ " 즉시 반영")
        ~en:(Glyph.to_utf8 Glyph.Live_healthy ^ " Hot-reload")
  | Next_turn ->
      Say.make
        ~ko:(Glyph.to_utf8 Glyph.Focus_caret ^ " 다음 턴")
        ~en:(Glyph.to_utf8 Glyph.Focus_caret ^ " Next turn")
  | Restart_required ->
      Say.make
        ~ko:(Glyph.to_utf8 Glyph.Warning_triangle ^ " 재시작 필요")
        ~en:(Glyph.to_utf8 Glyph.Warning_triangle ^ " Restart")

let reload_scope_token = function
  | Hot_reload -> Theme.Status_ok
  | Next_turn -> Theme.Status_active
  | Restart_required -> Theme.Status_attention

let string_content_of = function
  | Text_val s | Multiline_val s | Secret_val { raw = s; _ } -> Some s
  | Int_val { raw; _ } | Float_val { raw; _ } -> Some raw
  | Bool_val _ | Enum_val _ -> None

let check_validator value = function
  | Required -> (
      match string_content_of value with
      | Some s when String.length (String.trim s) = 0 ->
          Some (Say.make ~ko:"필수 입력 항목입니다" ~en:"Value is required")
      | Some _ | None -> None)
  | Int_range { min; max } -> (
      match value with
      | Int_val { parsed = None; _ } ->
          Some (Say.make ~ko:"유효한 정수를 입력하세요" ~en:"Must be a valid integer")
      | Int_val { parsed = Some n; _ } -> (
          match (min, max) with
          | Some lo, _ when n < lo ->
              Some
                (Say.make
                   ~ko:(Printf.sprintf "최솟값은 %d입니다" lo)
                   ~en:(Printf.sprintf "Minimum value is %d" lo))
          | _, Some hi when n > hi ->
              Some
                (Say.make
                   ~ko:(Printf.sprintf "최댓값은 %d입니다" hi)
                   ~en:(Printf.sprintf "Maximum value is %d" hi))
          | _ -> None)
      | Text_val _
      | Multiline_val _
      | Float_val _
      | Bool_val _
      | Enum_val _
      | Secret_val _ ->
          None)
  | Float_range { min; max } -> (
      match value with
      | Float_val { parsed = None; _ } ->
          Some (Say.make ~ko:"유효한 실수를 입력하세요" ~en:"Must be a valid number")
      | Float_val { parsed = Some f; _ } -> (
          match (min, max) with
          | Some lo, _ when f < lo ->
              Some
                (Say.make
                   ~ko:(Printf.sprintf "최솟값은 %g입니다" lo)
                   ~en:(Printf.sprintf "Minimum value is %g" lo))
          | _, Some hi when f > hi ->
              Some
                (Say.make
                   ~ko:(Printf.sprintf "최댓값은 %g입니다" hi)
                   ~en:(Printf.sprintf "Maximum value is %g" hi))
          | _ -> None)
      | Text_val _
      | Multiline_val _
      | Int_val _
      | Bool_val _
      | Enum_val _
      | Secret_val _ ->
          None)
  | Min_length min_len -> (
      match string_content_of value with
      | Some s when String.length s < min_len ->
          Some
            (Say.make
               ~ko:(Printf.sprintf "최소 %d자 이상 입력하세요" min_len)
               ~en:(Printf.sprintf "Minimum length is %d" min_len))
      | Some _ | None -> None)
  | Max_length max_len -> (
      match string_content_of value with
      | Some s when String.length s > max_len ->
          Some
            (Say.make
               ~ko:(Printf.sprintf "최대 %d자 이하로 입력하세요" max_len)
               ~en:(Printf.sprintf "Maximum length is %d" max_len))
      | Some _ | None -> None)
  | Custom fn -> fn value

let validate_field (f : field) =
  let inherent =
    match f.value with
    | Int_val { raw; parsed = None } when String.length (String.trim raw) > 0 ->
        Some (Say.make ~ko:"유효한 정수가 아닙니다" ~en:"Invalid integer")
    | Float_val { raw; parsed = None } when String.length (String.trim raw) > 0 ->
        Some (Say.make ~ko:"유효한 실수가 아닙니다" ~en:"Invalid floating-point number")
    | Text_val _
    | Multiline_val _
    | Int_val _
    | Float_val _
    | Bool_val _
    | Enum_val _
    | Secret_val _ ->
        None
  in
  match inherent with
  | Some _ as err -> err
  | None -> List.find_map (check_validator f.value) f.validators

let validate_all (st : state) =
  let all_ok = ref true in
  let fields =
    Array.map
      (fun f ->
        let error = validate_field f in
        if Option.is_some error then all_ok := false;
        { f with error })
      st.fields
  in
  ({ st with fields }, !all_ok)

let is_field_dirty (f : field) = not (equal_field_value f.value f.initial)

let is_dirty (st : state) = Array.exists is_field_dirty st.fields

let dirty_fields (st : state) =
  st.fields |> Array.to_list |> List.filter is_field_dirty

let update_field_at idx fn (st : state) =
  let n = Array.length st.fields in
  if idx < 0 || idx >= n then st
  else
    let next = Array.copy st.fields in
    let f = next.(idx) in
    let updated = fn f in
    next.(idx) <- { updated with error = validate_field updated };
    { st with fields = next }

let has_substring ~needle ~haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec scan i =
      if i + n > h then false
      else if String.equal (String.sub haystack i n) needle then true
      else scan (i + 1)
    in
    scan 0

let matches_filter_any filter (f : field) =
  let q = String.lowercase_ascii (String.trim filter) in
  if String.length q = 0 then true
  else
    has_substring ~needle:q ~haystack:(String.lowercase_ascii f.key)
    || has_substring ~needle:q
         ~haystack:(String.lowercase_ascii (Say.resolve Say.Lang_ko f.label))
    || has_substring ~needle:q
         ~haystack:(String.lowercase_ascii (Say.resolve Say.Lang_en f.label))

let visible_indices (st : state) =
  let n = Array.length st.fields in
  let rec collect i acc =
    if i >= n then List.rev acc
    else if matches_filter_any st.filter st.fields.(i) then
      collect (i + 1) (i :: acc)
    else collect (i + 1) acc
  in
  collect 0 []

let resolved_focused_index (st : state) =
  let vis = visible_indices st in
  match vis with
  | [] -> None
  | first :: _ ->
      if List.exists (Int.equal st.focused) vis then Some st.focused
      else Some first

let set_filter filter (st : state) =
  let next = { st with filter; editing = false } in
  let focused =
    match resolved_focused_index next with
    | Some idx -> idx
    | None -> 0
  in
  { next with focused }

let set_value ~key value (st : state) =
  let next =
    Array.map
      (fun f ->
        if String.equal f.key key && not f.read_only then
          let f' = { f with value } in
          { f' with error = validate_field f' }
        else f)
      st.fields
  in
  { st with fields = next }

let move_focus ~dir (st : state) =
  let vis = Array.of_list (visible_indices st) in
  let count = Array.length vis in
  if count = 0 then { st with editing = false }
  else
    let cur_pos =
      let rec find i =
        if i >= count then None
        else if Int.equal vis.(i) st.focused then Some i
        else find (i + 1)
      in
      find 0
    in
    let next_pos =
      match (cur_pos, dir) with
      | Some pos, `Next -> (pos + 1) mod count
      | Some pos, `Prev -> (pos - 1 + count) mod count
      | None, `Next -> 0
      | None, `Prev -> count - 1
    in
    { st with focused = vis.(next_pos); editing = false }

let update_focused_if_visible fn (st : state) =
  match resolved_focused_index st with
  | None -> st
  | Some idx when Int.equal idx st.focused -> update_field_at idx fn st
  | Some _ -> st

let toggle_bool (st : state) =
  update_focused_if_visible
    (fun f ->
      if f.read_only then f
      else
        match f.value with
        | Bool_val b -> { f with value = Bool_val (not b) }
        | Text_val _
        | Multiline_val _
        | Int_val _
        | Float_val _
        | Enum_val _
        | Secret_val _ ->
            f)
    st

let step_enum ~dir (st : state) =
  update_focused_if_visible
    (fun f ->
      if f.read_only then f
      else
        match f.value with
        | Enum_val { selected; options } ->
            let n = Array.length options in
            if n = 0 then f
            else
              let next_sel =
                match dir with
                | `Next -> (selected + 1) mod n
                | `Prev -> (selected - 1 + n) mod n
              in
              { f with value = Enum_val { selected = next_sel; options } }
        | Text_val _
        | Multiline_val _
        | Int_val _
        | Float_val _
        | Bool_val _
        | Secret_val _ ->
            f)
    st

let toggle_secret_reveal (st : state) =
  update_focused_if_visible
    (fun f ->
      match f.value with
      | Secret_val { raw; revealed } ->
          { f with value = Secret_val { raw; revealed = not revealed } }
      | Text_val _
      | Multiline_val _
      | Int_val _
      | Float_val _
      | Bool_val _
      | Enum_val _ ->
          f)
    st

let drop_last_utf8_scalar s =
  let len = String.length s in
  if len = 0 then ""
  else
    let i = ref (len - 1) in
    while !i > 0 && (Char.code s.[!i] land 0xC0) = 0x80 do
      decr i
    done;
    String.sub s 0 !i

let edit_string_field fn (st : state) =
  update_focused_if_visible
    (fun f ->
      if f.read_only then f
      else
        match f.value with
        | Text_val s -> { f with value = Text_val (fn s) }
        | Multiline_val s -> { f with value = Multiline_val (fn s) }
        | Int_val { raw; _ } -> { f with value = int_val_of_raw (fn raw) }
        | Float_val { raw; _ } -> { f with value = float_val_of_raw (fn raw) }
        | Secret_val { raw; revealed } ->
            { f with value = Secret_val { raw = fn raw; revealed } }
        | Bool_val _ | Enum_val _ -> f)
    st

let handle_key (ev : Input.key_event) (st : state) =
  if Array.length st.fields = 0 || ev.mods.ctrl || ev.mods.alt then st
  else
    match resolved_focused_index st with
    | None -> { st with editing = false }
    | Some active_idx ->
        let st =
          if Int.equal active_idx st.focused then st
          else { st with focused = active_idx; editing = false }
        in
        let cur = st.fields.(active_idx) in
        match ev.key with
        | Input.Up -> move_focus ~dir:`Prev st
        | Input.Down -> move_focus ~dir:`Next st
        | Input.Tab ->
            move_focus ~dir:(if ev.mods.shift then `Prev else `Next) st
        | Input.Left -> step_enum ~dir:`Prev st
        | Input.Right -> step_enum ~dir:`Next st
        | Input.Char " " when not st.editing -> (
            match cur.value with
            | Bool_val _ -> toggle_bool st
            | Enum_val _ -> step_enum ~dir:`Next st
            | Secret_val _ -> toggle_secret_reveal st
            | Text_val _ | Multiline_val _ | Int_val _ | Float_val _ ->
                if cur.read_only then st else { st with editing = true })
        | Input.Enter -> (
            match cur.value with
            | Bool_val _ -> toggle_bool st
            | Enum_val _ -> step_enum ~dir:`Next st
            | Multiline_val _ when st.editing ->
                edit_string_field (fun s -> s ^ "\n") st
            | Text_val _ | Multiline_val _ | Int_val _ | Float_val _ | Secret_val _ ->
                if cur.read_only then st else { st with editing = not st.editing })
        | Input.Escape -> if st.editing then { st with editing = false } else st
        | Input.Backspace ->
            if st.editing then edit_string_field drop_last_utf8_scalar st else st
        | Input.Char s ->
            if st.editing && String.length s > 0 then
              edit_string_field (fun prev -> prev ^ s) st
            else st
        | Input.Delete
        | Input.Insert
        | Input.Home
        | Input.End
        | Input.Page_up
        | Input.Page_down
        | Input.Function _ ->
            st

let format_diff_value ~after = function
  | Text_val s -> Printf.sprintf "\"%s\"" s
  | Multiline_val s -> Printf.sprintf "\"\"\"%s\"\"\"" (String.escaped s)
  | Int_val { raw; _ } -> raw
  | Float_val { raw; _ } -> raw
  | Bool_val b -> if b then "true" else "false"
  | Enum_val { selected; options } ->
      if selected >= 0 && selected < Array.length options then
        Printf.sprintf "\"%s\"" (fst options.(selected))
      else "\"\""
  | Secret_val { raw; _ } ->
      if String.length raw = 0 then "\"(empty)\""
      else if after then "\"[redacted] (modified)\""
      else "\"[redacted]\""

let diff_preview (st : state) =
  let modified = dirty_fields st in
  if modified = [] then []
  else
    let before =
      modified
      |> List.map (fun f ->
             Printf.sprintf "%s = %s" f.key
               (format_diff_value ~after:false f.initial))
      |> String.concat "\n"
    in
    let after =
      modified
      |> List.map (fun f ->
             Printf.sprintf "%s = %s" f.key
               (format_diff_value ~after:true f.value))
      |> String.concat "\n"
    in
    Diff.rows ~before ~after |> Diff.number ~old_start:1 ~new_start:(Some 1)

let format_display_value ~lang = function
  | Text_val s -> s
  | Multiline_val s ->
      let lines = String.split_on_char '\n' s in
      let first = match lines with h :: _ -> h | [] -> "" in
      let count = List.length lines in
      if count <= 1 then first
      else Printf.sprintf "%s (+%dL)" first (count - 1)
  | Int_val { raw; _ } -> raw
  | Float_val { raw; _ } -> raw
  | Bool_val b ->
      if b then
        Glyph.to_utf8 Glyph.Check_mark ^ " " ^ Say.resolve lang (Say.make ~ko:"켜짐" ~en:"ON")
      else
        Glyph.to_utf8 Glyph.Live_idle ^ " " ^ Say.resolve lang (Say.make ~ko:"꺼짐" ~en:"OFF")
  | Enum_val { selected; options } ->
      if selected >= 0 && selected < Array.length options then
        let _, lbl = options.(selected) in
        Printf.sprintf "\xe2\x80\xb9 %s \xe2\x80\xba" (Say.resolve lang lbl)
      else "\xe2\x80\xb9\xe2\x80\xba"
  | Secret_val { raw; revealed } ->
      if revealed then raw else masked_display raw

let field_row_height ~inline_help ~is_focused (f : field) =
  match (f.error, inline_help && is_focused, f.help) with
  | Some _, _, _ -> 2
  | None, true, Some _ -> 2
  | None, true, None | None, false, (Some _ | None) -> 1

let compute_scroll_start ~avail_h ~focused_pos heights =
  let count = Array.length heights in
  if count = 0 || avail_h <= 0 then 0
  else
    let pos = Int.max 0 (Int.min (count - 1) focused_pos) in
    let sum_to_pos = ref 0 in
    for i = 0 to pos do
      sum_to_pos := !sum_to_pos + heights.(i)
    done;
    if !sum_to_pos <= avail_h then 0
    else
      let used = ref heights.(pos) in
      let start = ref pos in
      while !start > 0 && !used + heights.(!start - 1) <= avail_h do
        decr start;
        used := !used + heights.(!start)
      done;
      !start

let exception_chip ~lang ~(theme : Theme.t) ~bg ~(hdr : section_header option)
    (f : field) =
  if is_field_dirty f then
    Some
      ( Glyph.to_utf8 Glyph.Live_healthy
        ^ " "
        ^ Say.resolve lang (Say.make ~ko:"수정됨" ~en:"Modified"),
        Typography.status ~bg ~bold:true theme Theme.Status_attention )
  else
    match f.value with
    | Secret_val { revealed = false; _ } ->
        Some
          ( Say.resolve lang (Say.make ~ko:"[비밀·마스킹]" ~en:"[Secret]"),
            Typography.whisper ~bg theme )
    | Text_val _
    | Multiline_val _
    | Int_val _
    | Float_val _
    | Bool_val _
    | Enum_val _
    | Secret_val { revealed = true; _ } -> (
        match hdr with
        | None -> None
        | Some h -> (
            match f.provenance with
            | Prov_env _ when not (equal_provenance f.provenance h.provenance) ->
                Some
                  ( Say.resolve lang (Say.make ~ko:"[환경변수]" ~en:"[Env]"),
                    Typography.status ~bg theme Theme.Status_active )
            | Prov_default when not (equal_provenance f.provenance h.provenance) ->
                Some
                  ( Say.resolve lang (Say.make ~ko:"[기본값]" ~en:"[Default]"),
                    Typography.whisper ~bg theme )
            | Prov_keeper_toml _ | Prov_global_toml | Prov_tui_pref
            | Prov_env _ | Prov_default ->
                if not (equal_reload_scope f.reload_scope h.reload_scope) then
                  Some
                    ( Say.resolve lang (reload_scope_label f.reload_scope),
                      Typography.status ~bg theme (reload_scope_token f.reload_scope) )
                else None))

let draw_section_header_band ~pad_x grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~lang (hdr : section_header) =
  let bg = Color.of_rgb theme.surface_2 in
  let band_h = if rect.h >= 2 then 2 else 1 in
  let band_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:band_h in
  Cell_grid.fill_rect ~clip:rect grid ~rect:band_r
    ~style:(Typography.primary ~bg theme) ();
  let px = Int.max 0 (Int.min pad_x ((rect.w - 1) / 2)) in
  let ix = rect.x + px in
  let iw = Int.max 0 (rect.w - (2 * px)) in
  if iw > 0 then begin
    let row0 = Rect.make ~x:ix ~y:rect.y ~w:iw ~h:1 in
    let title = Say.resolve lang hdr.title in
    let prefix_str =
      match hdr.canonical_prefix with Some p -> String.trim p | None -> ""
    in
    let pw = Grapheme.display_width prefix_str in
    let title_max = if pw > 0 && iw > pw + 4 then iw - pw - 2 else iw in
    let adv =
      Cell_grid.put_text ~clip:row0 grid ~x:ix ~y:rect.y
        ~style:(Typography.anchor ~bg theme)
        (Grapheme.truncate_to_width ~max_width:title_max title)
    in
    if pw > 0 && adv + 2 < iw then begin
      let fit_p = Grapheme.truncate_to_width ~max_width:(iw - adv - 2) prefix_str in
      let fw = Grapheme.display_width fit_p in
      ignore
        (Cell_grid.put_text ~clip:row0 grid ~x:(ix + iw - fw) ~y:rect.y
           ~style:(Typography.whisper ~bg theme) fit_p)
    end;
    if band_h >= 2 then begin
      let py = rect.y + 1 in
      let row1 = Rect.make ~x:ix ~y:py ~w:iw ~h:1 in
      let prov_prefix =
        Say.resolve lang (Say.make ~ko:"출처: " ~en:"Source: ")
        ^ Say.resolve lang (provenance_label hdr.provenance)
      in
      let apply_lbl =
        Typography.sep_dot
        ^ Say.resolve lang (Say.make ~ko:"적용: " ~en:"Apply: ")
      in
      let scope_str = Say.resolve lang (reload_scope_label hdr.reload_scope) in
      let cx = ref ix in
      let adv1 =
        Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:py
          ~style:(Typography.structure ~bg theme) prov_prefix
      in
      cx := !cx + adv1;
      let adv2 =
        Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:py
          ~style:(Typography.whisper ~bg ~italic:false theme) apply_lbl
      in
      cx := !cx + adv2;
      ignore
        (Cell_grid.put_text ~clip:row1 grid ~x:!cx ~y:py
           ~style:(Typography.status ~bg theme (reload_scope_token hdr.reload_scope))
           scope_str)
    end
  end;
  band_h

let draw_focused_help_footer ~pad_x grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~lang (focused_field : field option) =
  if rect.h < 2 then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:(Typography.primary ~bg theme) ();
    Card.draw_hairline ~pad_x ~bg grid ~rect ~y:rect.y ~theme;
    let px = Int.max 0 (Int.min pad_x ((rect.w - 1) / 2)) in
    let ix = rect.x + px in
    let iw = Int.max 0 (rect.w - (2 * px)) in
    if iw > 0 then
      match focused_field with
      | None -> ()
      | Some f ->
          let y1 = rect.y + 1 in
          if y1 < Rect.bottom rect then begin
            let key_prefix = Say.resolve lang (Say.make ~ko:"키: " ~en:"Key: ") in
            let r1 = Rect.make ~x:ix ~y:y1 ~w:iw ~h:1 in
            let adv =
              Cell_grid.put_text ~clip:r1 grid ~x:ix ~y:y1
                ~style:(Typography.whisper ~bg ~italic:false theme) key_prefix
            in
            ignore
              (Cell_grid.put_text ~clip:r1 grid ~x:(ix + adv) ~y:y1
                 ~style:(Typography.structure ~bg theme)
                 (Grapheme.truncate_to_width ~max_width:(Int.max 0 (iw - adv)) f.key))
          end;
          let y2 = rect.y + 2 in
          let showed_shortcut_hint_on_y2 =
            Option.is_none f.error && Option.is_none f.help
          in
          if y2 < Rect.bottom rect then begin
            let r2 = Rect.make ~x:ix ~y:y2 ~w:iw ~h:1 in
            match (f.error, f.help) with
            | Some err, _ ->
                let msg = Glyph.to_utf8 Glyph.Live_failing ^ " " ^ Say.resolve lang err in
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:ix ~y:y2
                     ~style:(Typography.status ~bg ~bold:true theme Theme.Status_critical)
                     (Grapheme.truncate_to_width ~max_width:iw msg))
            | None, Some h ->
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:ix ~y:y2
                     ~style:(Typography.whisper ~bg theme)
                     (Grapheme.truncate_to_width ~max_width:iw (Say.resolve lang h)))
            | None, None ->
                let fallback =
                  Say.resolve lang
                    (Say.make
                       ~ko:"[Enter] 편집 · [d] 검증 · [Ctrl+S] 저장"
                       ~en:"[Enter] Edit · [d] Validate · [Ctrl+S] Save")
                in
                ignore
                  (Cell_grid.put_text ~clip:r2 grid ~x:ix ~y:y2
                     ~style:(Typography.whisper ~bg theme)
                     (Grapheme.truncate_to_width ~max_width:iw fallback))
          end;
          let y3 = rect.y + 3 in
          if y3 < Rect.bottom rect then begin
            let r3 = Rect.make ~x:ix ~y:y3 ~w:iw ~h:1 in
            if is_field_dirty f then begin
              let before_s = format_diff_value ~after:false f.initial in
              let after_s = format_diff_value ~after:true f.value in
              let lbl = Say.resolve lang (Say.make ~ko:"변경: " ~en:"Changed: ") in
              let cx = ref ix in
              let a0 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:(Typography.whisper ~bg ~italic:false theme) lbl
              in
              cx := !cx + a0;
              let a1 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:(Typography.status ~bg theme Theme.Status_critical) before_s
              in
              cx := !cx + a1;
              let a2 =
                Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                  ~style:(Typography.whisper ~bg ~italic:false theme) " -> "
              in
              cx := !cx + a2;
              ignore
                (Cell_grid.put_text ~clip:r3 grid ~x:!cx ~y:y3
                   ~style:(Typography.status ~bg ~bold:true theme Theme.Status_ok)
                   (Grapheme.truncate_to_width
                      ~max_width:(Int.max 0 (ix + iw - !cx)) after_s))
            end
            else if not showed_shortcut_hint_on_y2 then
              let hint =
                Say.resolve lang
                  (Say.make
                     ~ko:"[Enter] 편집 · [d] 검증 · [Ctrl+S] 저장"
                     ~en:"[Enter] Edit · [d] Validate · [Ctrl+S] Save")
              in
              ignore
                (Cell_grid.put_text ~clip:r3 grid ~x:ix ~y:y3
                   ~style:(Typography.whisper ~bg theme)
                   (Grapheme.truncate_to_width ~max_width:iw hint))
          end

let is_utf8_cont b = b land 0xC0 = 0x80

let clamp_utf8_cursor s c =
  let len = String.length s in
  let c = Int.max 0 (Int.min len c) in
  let rec align i =
    if i <= 0 || i >= len then i
    else if is_utf8_cont (Char.code s.[i]) then align (i - 1)
    else i
  in
  align c

(* Compute horizontally scrolled before/after slices keeping the 1-column
   editing cursor inside [max_w] display columns (reserving 1 column for the
   cursor glyph and 1 column for ["‹"] when scrolled past column 0). *)
let slice_editing_value ~max_w ~cursor_byte raw =
  if max_w <= 1 then ("", "")
  else
    let len = String.length raw in
    let c = clamp_utf8_cursor raw cursor_byte in
    let before = String.sub raw 0 c in
    let after = String.sub raw c (len - c) in
    let before_w = Grapheme.display_width before in
    let avail = max_w - 1 in
    if before_w <= avail then
      let rem_w = avail - before_w in
      let vis_after =
        if rem_w > 0 then Grapheme.truncate_to_width ~max_width:rem_w after
        else ""
      in
      (before, vis_after)
    else
      let ind = "‹" in
      let ind_w = Grapheme.display_width ind in
      if avail <= ind_w then (ind, "")
      else
        let tail_budget = avail - ind_w in
        (* Walk UTF-8 boundaries in [before] until suffix fits in [tail_budget]. *)
        let rec drop_from i =
          if i >= c then c
          else
            let sub = String.sub before i (c - i) in
            if Grapheme.display_width sub <= tail_budget then i
            else
              let d = String.get_utf_8_uchar before i in
              drop_from (i + Int.max 1 (Uchar.utf_decode_length d))
        in
        let start = drop_from 0 in
        let visible_before = String.sub before start (c - start) in
        let rem_w =
          Int.max 0 (tail_budget - Grapheme.display_width visible_before)
        in
        let visible_after =
          if rem_w > 0 then Grapheme.truncate_to_width ~max_width:rem_w after
          else ""
        in
        (ind ^ visible_before, visible_after)

let inline_text_rows text =
  let rec count from rows =
    if rows = 4 then rows
    else
      match String.index_from_opt text from '\n' with
      | None -> rows
      | Some newline -> count (newline + 1) (rows + 1)
  in
  count 0 1

let draw_editing_line grid ~(row : Rect.t) ~x ~width ~style ~cursor_style
    ~cursor_byte text =
  let before, after = slice_editing_value ~max_w:width ~cursor_byte text in
  let offset =
    Cell_grid.put_text ~clip:row grid ~x ~y:row.y ~style before
  in
  let cursor_x = x + offset in
  if cursor_x < x + width && cursor_x < Rect.right row then begin
    let advance =
      Cell_grid.put_text ~clip:row grid ~x:cursor_x ~y:row.y ~style:cursor_style
        "▏"
    in
    let after_x = cursor_x + advance in
    if after_x < x + width && after_x < Rect.right row then
      ignore (Cell_grid.put_text ~clip:row grid ~x:after_x ~y:row.y ~style after)
  end

let draw_inline_text grid ~(row : Rect.t) ~x ~width ~rows ~style ~cursor_style
    ~base_style ~cursor_byte text =
  let lines = String.split_on_char '\n' text |> Array.of_list in
  let rec locate line offset =
    let len = String.length lines.(line) in
    if offset <= len || line = Array.length lines - 1 then line, Int.min len offset
    else locate (line + 1) (offset - len - 1)
  in
  let cursor_line, offset = locate 0 (Int.max 0 cursor_byte) in
  let first = Int.max 0 (cursor_line - rows + 1) in
  for i = 0 to Int.min (rows - 1) (Array.length lines - 1 - first) do
    let line = first + i in
    let clip = Rect.make ~x:row.x ~y:(row.y + i) ~w:row.w ~h:1 in
    if i > 0 then Cell_grid.fill_rect ~clip grid ~rect:clip ~style:base_style ();
    if line = cursor_line then
      draw_editing_line grid ~row:clip ~x ~width ~style ~cursor_style
        ~cursor_byte:offset lines.(line)
    else
      ignore
        (Cell_grid.put_text ~clip grid ~x ~y:clip.y ~style
           (Grapheme.truncate_to_width ~max_width:width lines.(line)))
  done

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang ?pad_x ?label_width
    ?section_header ?show_row_badges ?show_help_footer ?(focused = true)
    ?(elevated = false) ?edit_cursor (st : state) =
  if Rect.is_empty rect then 0
  else
    let base_bg_rgb = if elevated then theme.surface_2 else theme.surface_1 in
    let surface_card = Color.of_rgb base_bg_rgb in
    Cell_grid.fill_rect ~clip:rect grid ~rect
      ~style:(Typography.primary ~bg:surface_card theme) ();
    let eff_pad_x =
      match pad_x with
      | Some p -> Int.max 0 p
      | None -> (match section_header with Some _ -> 2 | None -> 0)
    in
    let eff_row_badges =
      match show_row_badges with
      | Some b -> b
      | None -> Option.is_none section_header
    in
    let want_help_footer =
      match show_help_footer with
      | Some b -> b
      | None -> Option.is_some section_header && rect.h >= 10
    in
    let header_h =
      match section_header with
      | Some hdr when rect.h >= 5 ->
          let bh = draw_section_header_band ~pad_x:eff_pad_x grid ~rect ~theme ~lang hdr in
          if rect.h >= 8 then bh + 1 else bh
      | Some _ | None -> 0
    in
    let body_top = rect.y + header_h in
    let body_avail_h = Int.max 0 (rect.h - header_h) in
    let help_footer_h =
      if want_help_footer && body_avail_h >= 6 then 4 else 0
    in
    let eff_help_footer = help_footer_h > 0 in
    let preview = if eff_help_footer then [] else diff_preview st in
    let preview_h =
      if preview = [] || body_avail_h - help_footer_h < 6 then 0
      else Int.min (Int.max 2 (List.length preview + 1)) ((body_avail_h - help_footer_h) / 3)
    in
    let fields_h = Int.max 0 (body_avail_h - help_footer_h - preview_h) in
    let fields_rect = Rect.make ~x:rect.x ~y:body_top ~w:rect.w ~h:fields_h in
    let diff_rect =
      Rect.make ~x:rect.x ~y:(Rect.bottom fields_rect) ~w:rect.w ~h:preview_h
    in
    let footer_rect =
      Rect.make ~x:rect.x ~y:(Rect.bottom diff_rect) ~w:rect.w ~h:help_footer_h
    in
    let vis_arr = Array.of_list (visible_indices st) in
    let vis_count = Array.length vis_arr in
    let active_idx = resolved_focused_index st in
    let focused_field =
      match active_idx with
      | Some idx when idx >= 0 && idx < Array.length st.fields ->
          Some st.fields.(idx)
      | Some _ | None -> None
    in
    let inline_text =
      if not (focused && st.editing) then None
      else
        match focused_field, edit_cursor with
        | Some f, Some cursor -> (
            match f.value with
            | Multiline_val text -> Some (text, cursor)
            | Text_val _ | Secret_val _ | Int_val _ | Float_val _ | Bool_val _
            | Enum_val _ -> None)
        | Some _, None | None, (Some _ | None) -> None
    in
    let editor_rows =
      match inline_text with
      | None -> 1
      | Some (text, _) -> Int.min (Int.max 1 fields_rect.h) (inline_text_rows text)
    in
    let focused_pos =
      match active_idx with
      | None -> 0
      | Some target ->
          let rec find i =
            if i >= vis_count then 0
            else if Int.equal vis_arr.(i) target then i
            else find (i + 1)
          in
          find 0
    in
    let inline_help = not eff_help_footer in
    let heights =
      Array.init vis_count (fun pos ->
          let idx = vis_arr.(pos) in
          let is_focused =
            match active_idx with Some a -> Int.equal a idx | None -> false
          in
          field_row_height ~inline_help ~is_focused st.fields.(idx)
          + if is_focused then editor_rows - 1 else 0)
    in
    let start_pos =
      compute_scroll_start ~avail_h:fields_rect.h ~focused_pos heights
    in
    let y = ref fields_rect.y in
    let bottom = Rect.bottom fields_rect in
    let drawn = ref 0 in
    let rpad = Int.max 0 (Int.min eff_pad_x ((fields_rect.w - 1) / 4)) in
    let rail_x = fields_rect.x + rpad in
    let label_x = rail_x + 2 in
    let usable_w = Int.max 0 (fields_rect.w - (2 * rpad)) in
    let eff_label_w =
      match label_width with
      | Some lw -> Int.max 10 (Int.min (Int.max 10 (usable_w / 2)) lw)
      | None ->
          if Option.is_some section_header then
            Int.max 12 (Int.min 22 (usable_w / 3))
          else Int.max 12 (Int.min 28 (usable_w / 3))
    in
    let right_edge = Rect.right fields_rect - rpad in
    for pos = start_pos to vis_count - 1 do
      let idx = vis_arr.(pos) in
      let f = st.fields.(idx) in
      if !y < bottom then begin
        let is_selected =
          match active_idx with Some a -> Int.equal a idx | None -> false
        in
        let is_focused = is_selected && focused in
        let bg_rgb =
          if is_focused then theme.selection_bg
          else if is_selected then theme.surface_2
          else base_bg_rgb
        in
        let bg = Color.of_rgb bg_rgb in
        let row_rect = Rect.make ~x:fields_rect.x ~y:!y ~w:fields_rect.w ~h:1 in
        let base_style = Typography.primary ~bg theme in
        Cell_grid.fill_rect ~clip:fields_rect grid ~rect:row_rect ~style:base_style ();
        if is_focused then
          Cell_grid.put_glyph ~clip:row_rect grid ~x:rail_x ~y:!y
            ~style:(Typography.accent ~bg ~bold:true theme)
            Glyph.Left_rail;
        let lbl_style =
          if is_focused then Typography.anchor ~bg theme
          else if is_selected then Typography.primary ~bg theme
          else Typography.structure ~bg theme
        in
        let label_str =
          let dirty_mark =
            if eff_row_badges && is_field_dirty f then
              Glyph.to_utf8 Glyph.Live_healthy ^ " "
            else ""
          in
          dirty_mark ^ Say.resolve lang f.label
        in
        ignore
          (Cell_grid.put_text ~clip:row_rect grid ~x:label_x ~y:!y
             ~style:lbl_style
             (Grapheme.truncate_to_width ~max_width:eff_label_w label_str));
        let val_x = label_x + eff_label_w + 2 in
        let avail_right = Int.max 0 (right_edge - val_x) in
        let chip =
          if eff_row_badges then
            let badges_str =
              Printf.sprintf "[%s] %s"
                (Say.resolve lang (provenance_label f.provenance))
                (Say.resolve lang (reload_scope_label f.reload_scope))
            in
            Some
              ( badges_str,
                Typography.status ~bg theme (reload_scope_token f.reload_scope) )
          else exception_chip ~lang ~theme ~bg ~hdr:section_header f
        in
        let chip_w =
          match chip with
          | Some (s, _) -> Grapheme.display_width s
          | None -> 0
        in
        let show_chip = chip_w > 0 && avail_right > chip_w + 8 in
        let val_w =
          if show_chip then avail_right - chip_w - 2 else avail_right
        in
        let val_str = format_display_value ~lang f.value in
        let val_fg =
          match f.value with
          | Bool_val true -> theme.status_ok
          | Bool_val false -> theme.text_muted
          | Secret_val { revealed = false; _ } -> theme.status_attention
          | Text_val _
          | Multiline_val _
          | Int_val _
          | Float_val _
          | Enum_val _
          | Secret_val { revealed = true; _ } ->
              if f.read_only then theme.text_muted
              else if is_focused then theme.text_bright
              else theme.text_primary
        in
        let val_attrs =
          if is_focused && st.editing then Attr.underline
          else
            match f.value with
            | Bool_val true -> Attr.bold
            | Bool_val false
            | Text_val _
            | Multiline_val _
            | Int_val _
            | Float_val _
            | Enum_val _
            | Secret_val _ ->
                Attr.none
        in
        let val_style = Style.make ~fg:(Color.of_rgb val_fg) ~bg ~attrs:val_attrs () in
        if val_w > 0 then begin
          let cursor_style =
            Style.make ~fg:(Color.of_rgb theme.accent) ~bg ~attrs:Attr.bold ()
          in
          match (if is_focused then inline_text else None) with
          | Some (text, cursor_byte) ->
              let rows = Int.min editor_rows (bottom - !y) in
              draw_inline_text grid ~row:row_rect ~x:val_x ~width:val_w ~rows
                ~style:val_style ~cursor_style ~base_style ~cursor_byte text
          | None ->
              let is_text_editing =
                is_focused && st.editing
                &&
                match f.value with
                | Text_val _ | Multiline_val _ | Int_val _ | Float_val _
                | Secret_val _ -> true
                | Bool_val _ | Enum_val _ -> false
              in
              if is_text_editing then begin
                let cursor_byte =
                  match f.value with
                  | Secret_val { revealed = false; _ } -> String.length val_str
                  | Text_val _
                  | Multiline_val _
                  | Int_val _
                  | Float_val _
                  | Bool_val _
                  | Enum_val _
                  | Secret_val { revealed = true; _ } -> (
                      match edit_cursor with
                      | Some cursor -> cursor
                      | None -> String.length val_str)
                in
                draw_editing_line grid ~row:row_rect ~x:val_x ~width:val_w
                  ~style:val_style ~cursor_style ~cursor_byte val_str
              end
              else
                ignore
                  (Cell_grid.put_text ~clip:row_rect grid ~x:val_x ~y:!y
                     ~style:val_style
                     (Grapheme.truncate_to_width ~max_width:val_w val_str))
        end;
        (match chip with
         | Some (chip_str, chip_style) when show_chip ->
             let bx = right_edge - chip_w in
             ignore
               (Cell_grid.put_text ~clip:row_rect grid ~x:bx ~y:!y
                  ~style:chip_style chip_str)
         | Some _ | None -> ());
        y := !y + (if is_focused then editor_rows else 1);
        incr drawn;
        (* Validation error line (if any) *)
        (match f.error with
         | Some err when !y < bottom ->
             let err_rect = Rect.make ~x:fields_rect.x ~y:!y ~w:fields_rect.w ~h:1 in
             let err_style =
               Typography.status ~bg:surface_card ~bold:true theme Theme.Status_critical
             in
             Cell_grid.fill_rect ~clip:fields_rect grid ~rect:err_rect ~style:err_style ();
             Cell_grid.put_glyph ~clip:err_rect grid ~x:rail_x ~y:!y
               ~style:err_style Glyph.Left_rail;
             let msg =
               Glyph.to_utf8 Glyph.Live_failing ^ " " ^ Say.resolve lang err
             in
             ignore
               (Cell_grid.put_text ~clip:err_rect grid ~x:label_x ~y:!y
                  ~style:err_style
                  (Grapheme.truncate_to_width
                     ~max_width:(Int.max 0 (right_edge - label_x)) msg));
             incr y
         | Some _ | None -> ());
        (* Optional Tier-4 italic help line for focused field when no error and no bottom footer *)
        (match (inline_help, is_focused, f.error, f.help) with
         | true, true, None, Some h when !y < bottom ->
             let help_rect = Rect.make ~x:fields_rect.x ~y:!y ~w:fields_rect.w ~h:1 in
             let help_style = Typography.whisper ~bg:surface_card theme in
             Cell_grid.fill_rect ~clip:fields_rect grid ~rect:help_rect ~style:help_style ();
             ignore
               (Cell_grid.put_text ~clip:help_rect grid ~x:label_x ~y:!y
                  ~style:help_style
                  (Grapheme.truncate_to_width
                     ~max_width:(Int.max 0 (right_edge - label_x))
                     (Say.resolve lang h)));
             incr y
         | _ -> ())
      end
    done;
    if preview_h >= 2 then begin
      let hdr_rect = Rect.make ~x:diff_rect.x ~y:diff_rect.y ~w:diff_rect.w ~h:1 in
      let hdr_bg = Color.of_rgb theme.surface_2 in
      let hdr_style = Typography.structure ~bg:hdr_bg ~bold:true theme in
      Cell_grid.fill_rect ~clip:diff_rect grid ~rect:hdr_rect ~style:hdr_style ();
      let rem, add = Diff.counts (List.map (fun (n : Diff.numbered) -> n.nrow) preview) in
      let title =
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "변경 미리보기 (-%d / +%d)" rem add)
             ~en:(Printf.sprintf "Diff Preview (-%d / +%d)" rem add))
      in
      ignore
        (Cell_grid.put_text ~clip:hdr_rect grid ~x:(diff_rect.x + rpad)
           ~y:diff_rect.y ~style:hdr_style title);
      let body_rect =
        Rect.make ~x:diff_rect.x ~y:(diff_rect.y + 1) ~w:diff_rect.w
          ~h:(Int.max 0 (diff_rect.h - 1))
      in
      ignore (Diff.draw grid ~rect:body_rect ~theme ~language:Code_lexer.Toml preview)
    end;
    if help_footer_h >= 2 then
      draw_focused_help_footer ~pad_x:eff_pad_x grid ~rect:footer_rect ~theme
        ~lang focused_field;
    !drawn
