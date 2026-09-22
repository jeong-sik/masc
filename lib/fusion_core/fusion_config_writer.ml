(* Fusion 설정 작성기 (구현). 계약: fusion_config_writer.mli *)

module E = Toml_line_editor

let ( let* ) = Result.bind

type error =
  | Preset_absent of string
  | Preset_exists of string
  | Unaddressable_preset of string
  | Unreadable of string

let error_message = function
  | Preset_absent name -> Printf.sprintf "preset %s does not exist" name
  | Preset_exists name -> Printf.sprintf "preset %s already exists" name
  | Unaddressable_preset name ->
    Printf.sprintf
      "preset %s is not one [fusion.presets.%s] table holding all its keys, with only \
       its panels and judges entries right below it; edit it in the raw runtime.toml"
      name name
  | Unreadable detail -> "runtime.toml does not parse as TOML: " ^ detail
;;

type settings =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  }

let parse content =
  Result.map_error (fun detail -> Unreadable detail) (Otoml.Parser.from_string_result content)
;;

(* ── line classification ─────────────────────────────────────────────── *)

type line_kind =
  | Header of E.header
  | Key of string
  | Comment
  | Blank
  | Data  (** inside a value opened on an earlier line, or no structure at all *)

let is_blank line = String.equal (String.trim line) ""

let is_comment line =
  let trimmed = String.trim line in
  String.length trimmed > 0 && Char.equal trimmed.[0] '#'
;;

(* A header, key or comment counts only on a structural line: the same text
   inside a triple-quoted prompt is data. *)
let classify lines =
  List.map2
    (fun structural line ->
       if not structural
       then Data
       else (
         match E.header_of_line line with
         | Some header -> Header header
         | None ->
           if is_blank line
           then Blank
           else if is_comment line
           then Comment
           else (
             match E.key_of_line line with
             | Some key -> Key key
             | None -> Data)))
    (E.structural_lines lines)
    lines
;;

let read_lines content =
  let line_list, _trailing = E.split_lines content in
  line_list, Array.of_list line_list, Array.of_list (classify line_list)
;;

let header_path = function
  | E.Table path | E.Table_array path -> path
;;

let rec has_prefix ~prefix path =
  match prefix, path with
  | [], _ -> true
  | expected :: prefix, segment :: path ->
    String.equal expected segment && has_prefix ~prefix path
  | _ :: _, [] -> false
;;

let fusion_path = [ "fusion" ]
let panels_key = "panels"
let judges_key = "judges"
let panel_key = "panel"
let preset_path name = fusion_path @ [ "presets"; name ]
let panels_path name = preset_path name @ [ panels_key ]
let judges_path name = preset_path name @ [ judges_key ]
let render_path path = String.concat "." (List.map E.render_key path)
let table_header path = "[" ^ render_path path ^ "]"
let table_array_header path = "[[" ^ render_path path ^ "]]"

let preset_declared toml name = Otoml.path_exists toml (preset_path name)

(* The comments right above [index], with no blank line between: the note a
   header carries. *)
let attached_comments_start kinds index =
  let rec up index =
    if index > 0
    then (
      match kinds.(index - 1) with
      | Comment -> up (index - 1)
      | Header _ | Key _ | Blank | Data -> index)
    else index
  in
  up index
;;

(* ── the preset region ─────────────────────────────────────────────────── *)

(* [\[start, stop)]: [start] is the preset header. The region runs to the next
   header outside the preset, minus the comments and blanks right above that
   header, which document it. *)
type region =
  { start : int
  ; stop : int
  }

let find_region kinds name =
  let prefix = preset_path name in
  let count = Array.length kinds in
  let rec find_header index =
    if index >= count
    then None
    else (
      match kinds.(index) with
      | Header (E.Table path) when List.equal String.equal path prefix -> Some index
      | Header _ | Key _ | Comment | Blank | Data -> find_header (index + 1))
  in
  match find_header 0 with
  | None -> None
  | Some start ->
    let rec find_next index =
      if index >= count
      then count
      else (
        match kinds.(index) with
        | Header header when not (has_prefix ~prefix (header_path header)) -> index
        | Header _ | Key _ | Comment | Blank | Data -> find_next (index + 1))
    in
    let rec back index =
      if index > start + 1
      then (
        match kinds.(index - 1) with
        | Comment | Blank -> back (index - 1)
        | Header _ | Key _ | Data -> index)
      else index
    in
    Some { start; stop = back (find_next (start + 1)) }
;;

let header_outside_region kinds region name =
  let prefix = preset_path name in
  let rec scan index =
    if index >= Array.length kinds
    then false
    else (
      let outside = index < region.start || index >= region.stop in
      let under_preset =
        match kinds.(index) with
        | Header header -> has_prefix ~prefix (header_path header)
        | Key _ | Comment | Blank | Data -> false
      in
      (outside && under_preset) || scan (index + 1))
  in
  scan 0
;;

(* ── the region as keys and entries ────────────────────────────────────── *)

(* One key and its lines: the comments and blanks since the previous value,
   then every line the value spans. *)
type item =
  { key : string
  ; lead : string list
  ; value_lines : string list
  }

type entry_kind =
  | Panels
  | Judges

let same_kind a b =
  match a, b with
  | Panels, Panels | Judges, Judges -> true
  | Panels, Judges | Judges, Panels -> false
;;

type entry =
  { kind : entry_kind
  ; head : string list  (** comments and blanks above the header *)
  ; header : string
  ; items : item list
  }

type layout =
  { body : item list
  ; entries : entry list  (** in file order *)
  ; tail : string list
  }

let empty_layout = { body = []; entries = []; tail = [] }

type reading =
  { read : item list
  ; after : string list  (** comments and blanks after the last item *)
  ; next : int
  ; at_header : E.header option  (** the header at [next]; [None] at [stop] *)
  }

(* Items from [index] until a header or [stop]. *)
let read_items lines kinds ~stop index =
  let slice from until = Array.to_list (Array.sub lines from (until - from)) in
  let rec value_end index =
    if index >= stop
    then index
    else (
      match kinds.(index) with
      | Data -> value_end (index + 1)
      | Header _ | Key _ | Comment | Blank -> index)
  in
  let rec walk index pending read =
    let finish at_header =
      { read = List.rev read; after = List.rev pending; next = index; at_header }
    in
    if index >= stop
    then finish None
    else (
      match kinds.(index) with
      | Header header -> finish (Some header)
      | Key key ->
        let next = value_end (index + 1) in
        walk next [] ({ key; lead = List.rev pending; value_lines = slice index next } :: read)
      | Comment | Blank | Data -> walk (index + 1) (lines.(index) :: pending) read)
  in
  walk index [] []
;;

let entry_kind name = function
  | E.Table_array path when List.equal String.equal path (panels_path name) -> Some Panels
  | E.Table_array path when List.equal String.equal path (judges_path name) -> Some Judges
  | E.Table_array _ | E.Table _ -> None
;;

(* [None] when a header in the region opens something other than a panels or
   judges entry of this preset. *)
let read_layout lines kinds region name =
  let first = read_items lines kinds ~stop:region.stop (region.start + 1) in
  let rec entries acc (reading : reading) =
    match reading.at_header with
    | None -> Some { body = first.read; entries = List.rev acc; tail = reading.after }
    | Some header ->
      (match entry_kind name header with
       | None -> None
       | Some kind ->
         let inner = read_items lines kinds ~stop:region.stop (reading.next + 1) in
         entries
           ({ kind; head = reading.after; header = lines.(reading.next); items = inner.read }
            :: acc)
           inner)
  in
  entries [] first
;;

(* Every key of the preset's table must come from the region. A key written
   elsewhere, such as a dotted [presets.x.min_answered] under [\[fusion\]],
   would stay where it is beside the one the writer writes. *)
let keys_in_region toml name (layout : layout) =
  let has_entry kind = List.exists (fun (entry : entry) -> same_kind entry.kind kind) layout.entries in
  match Otoml.find_result toml Otoml.get_table (preset_path name) with
  | Error _ -> false
  | Ok table ->
    List.for_all
      (fun (key, _) ->
         List.exists (fun (item : item) -> String.equal item.key key) layout.body
         || (String.equal key panels_key && has_entry Panels)
         || (String.equal key judges_key && has_entry Judges))
      table
;;

let addressable_layout toml lines kinds region name =
  match read_layout lines kinds region name with
  | Some layout
    when (not (header_outside_region kinds region name)) && keys_in_region toml name layout ->
    Ok layout
  | Some _ | None -> Error (Unaddressable_preset name)
;;

(* ── values ────────────────────────────────────────────────────────────── *)

type field =
  | Text of string
  | Texts of string list
  | Whole of int
  | Seconds of float
  | Flag of bool

let same_value (written : field) (read : field) =
  match written, read with
  | Text a, Text b -> String.equal a b
  | Texts a, Texts b -> List.equal String.equal a b
  | Whole a, Whole b -> Int.equal a b
  | Seconds a, Seconds b -> Float.equal a b
  (* The loader reads seconds with [~strict:false]: [120] is [120.0]. *)
  | Seconds a, Whole b -> Float.equal a (Float.of_int b)
  | Flag a, Flag b -> Bool.equal a b
  | Text _, (Texts _ | Whole _ | Seconds _ | Flag _)
  | Texts _, (Text _ | Whole _ | Seconds _ | Flag _)
  | Whole _, (Text _ | Texts _ | Seconds _ | Flag _)
  | Seconds _, (Text _ | Texts _ | Flag _)
  | Flag _, (Text _ | Texts _ | Whole _ | Seconds _) -> false
;;

let text_of_toml = function
  | Otoml.TomlString text -> Some text
  | Otoml.TomlInteger _
  | Otoml.TomlFloat _
  | Otoml.TomlBoolean _
  | Otoml.TomlArray _
  | Otoml.TomlTable _
  | Otoml.TomlInlineTable _
  | Otoml.TomlTableArray _
  | Otoml.TomlOffsetDateTime _
  | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ -> None
;;

let field_of_toml = function
  | Otoml.TomlString text -> Some (Text text)
  | Otoml.TomlInteger whole -> Some (Whole whole)
  | Otoml.TomlFloat seconds -> Some (Seconds seconds)
  | Otoml.TomlBoolean flag -> Some (Flag flag)
  | Otoml.TomlArray values ->
    let texts = List.filter_map text_of_toml values in
    if Int.equal (List.compare_lengths texts values) 0 then Some (Texts texts) else None
  | Otoml.TomlTable _
  | Otoml.TomlInlineTable _
  | Otoml.TomlTableArray _
  | Otoml.TomlOffsetDateTime _
  | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ -> None
;;

(* The value an item's own lines hold. [None] when they do not read alone. *)
let item_field (item : item) =
  match Otoml.Parser.from_string_result (String.concat "\n" item.value_lines) with
  | Error _ -> None
  | Ok toml -> Option.bind (Otoml.find_opt toml Fun.id [ item.key ]) field_of_toml
;;

(* A multi-line basic string. The newline right after the opening delimiter is
   not part of the value, so the value reads back exactly as given. A quote is
   escaped wherever it stands, which keeps a run of three from closing early. *)
let multiline_string_lines ~key text =
  let buffer = Buffer.create (String.length text + 16) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\n' -> Buffer.add_char buffer '\n'
      | '\t' -> Buffer.add_char buffer '\t'
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
        Buffer.add_string buffer (Printf.sprintf "\\u%04X" (Char.code c))
      | c -> Buffer.add_char buffer c)
    text;
  String.split_on_char '\n'
    (E.render_key key ^ " = \"\"\"\n" ^ Buffer.contents buffer ^ "\"\"\"")
;;

let field_lines ~key = function
  | Text text ->
    if String.contains text '\n'
    then multiline_string_lines ~key text
    else [ E.value_line ~key ~value:(E.String text) ]
  | Texts texts ->
    (E.render_key key ^ " = [")
    :: List.map (fun text -> "  \"" ^ E.escape_string text ^ "\",") texts
    @ [ "]" ]
  | Whole whole -> [ E.value_line ~key ~value:(E.Int whole) ]
  | Seconds seconds -> [ E.value_line ~key ~value:(E.Float seconds) ]
  | Flag flag -> [ E.value_line ~key ~value:(E.Bool flag) ]
;;

(* ── what each table holds ─────────────────────────────────────────────── *)

type presence =
  | Always of field
  | Unless_default of
      { field : field
      ; is_default : bool  (** the loader reads this value when the key is absent *)
      }
  | When_set of field option

(* A key at its default is written only when the file already spells it out. *)
let resolve presence ~present =
  match presence with
  | Always field -> Some field
  | Unless_default { field; is_default } ->
    if is_default && not present then None else Some field
  | When_set field -> field
;;

let label_presence label = Unless_default { field = Text label; is_default = String.equal label "" }
let flag_presence flag = Unless_default { field = Flag flag; is_default = not flag }
let whole_presence value = When_set (Option.map (fun whole -> Whole whole) value)
let seconds_presence value = When_set (Option.map (fun seconds -> Seconds seconds) value)

let group_fields (group : Fusion_policy.panel_group) =
  [ "label", label_presence group.label
  ; panel_key, Always (Texts group.models)
  ; "panel_system_prompt", Always (Text group.system_prompt)
  ; "web_tools", flag_presence group.web_tools
  ; "max_output_tokens_per_panel", whole_presence group.max_output_tokens
  ; "panel_timeout_s", seconds_presence group.timeout_s
  ]
;;

let judge_fields (preset : Fusion_policy.preset) =
  [ "judge", Always (Text preset.judge)
  ; "judge_system_prompt", Always (Text preset.judge_system_prompt)
  ; "judge_max_output_tokens", whole_presence preset.judge_max_output_tokens
  ; "judge_timeout_s", seconds_presence preset.judge_timeout_s
  ; ( "min_answered"
    , Unless_default
        { field = Whole preset.min_answered
        ; is_default = Int.equal preset.min_answered Fusion_policy.default_min_answered
        } )
  ]
;;

let judge_entry_fields (judge : Fusion_policy.judge_spec) =
  [ "model", Always (Text judge.jmodel)
  ; "label", label_presence judge.jlabel
  ; "system_prompt", Always (Text judge.jsystem_prompt)
  ; "web_tools", flag_presence judge.jweb_tools
  ; "max_output_tokens", whole_presence judge.jmax_output_tokens
  ; "timeout_s", seconds_presence judge.jtimeout_s
  ]
;;

let settings_fields (settings : settings) =
  [ "enabled", Always (Flag settings.enabled)
  ; "default_preset", Always (Text settings.default_preset)
  ; ( "staged_judge_group_size"
    , Unless_default
        { field = Whole settings.staged_judge_group_size
        ; is_default =
            Int.equal settings.staged_judge_group_size
              Fusion_policy.default_staged_judge_group_size
        } )
  ]
;;

(* The lines of one table body. A key keeps its place and its lines while its
   value is unchanged; a changed value is rewritten where it stands, under its
   note; a key the table no longer carries goes with its note; keys the file
   did not have follow the last item, in [fields] order. A key the writer does
   not manage stays as written. *)
let render_items items fields =
  let present key = List.exists (fun (item : item) -> String.equal item.key key) items in
  let kept =
    List.concat_map
      (fun (item : item) ->
         match List.assoc_opt item.key fields with
         | None -> item.lead @ item.value_lines
         | Some presence ->
           (match resolve presence ~present:true with
            | None -> []
            | Some field ->
              let unchanged =
                match item_field item with
                | Some read -> same_value field read
                | None -> false
              in
              item.lead
              @ (if unchanged then item.value_lines else field_lines ~key:item.key field)))
      items
  in
  let added =
    List.concat_map
      (fun (key, presence) ->
         if present key
         then []
         else (
           match resolve presence ~present:false with
           | Some field -> field_lines ~key field
           | None -> []))
      fields
  in
  kept @ added
;;

(* ── entries ───────────────────────────────────────────────────────────── *)

type identity =
  { label : string
  ; routes : string list
  }

let equal_identity a b = String.equal a.label b.label && List.equal String.equal a.routes b.routes

(* A key the loader reads with a default: absent reads as [absent]; a value of
   another type leaves the entry without an identity. *)
let read_key toml key accessor ~absent =
  if Otoml.path_exists toml [ key ]
  then Result.to_option (Otoml.find_result toml accessor [ key ])
  else Some absent
;;

let old_identity (entry : entry) =
  let text = String.concat "\n" (List.concat_map (fun (item : item) -> item.value_lines) entry.items) in
  match Otoml.Parser.from_string_result text with
  | Error _ -> None
  | Ok toml ->
    Option.bind (read_key toml "label" Otoml.get_string ~absent:"") (fun label ->
      match entry.kind with
      | Panels ->
        Option.map
          (fun routes -> { label; routes })
          (read_key toml panel_key (Otoml.get_array Otoml.get_string) ~absent:[])
      | Judges ->
        Option.map
          (fun model -> { label; routes = [ model ] })
          (read_key toml "model" Otoml.get_string ~absent:""))
;;

(* Pair each wanted entry with the old entry it continues: first the one with
   the same label and routes, then, among those left, the one with the same
   non-empty label. An identity that two old entries share, or a label that two
   wanted entries still share, pairs with neither. *)
let pair_entries (old : entry list) (wanted : (identity * 'a) list) =
  let old = Array.of_list (List.map (fun entry -> entry, old_identity entry) old) in
  let wanted = Array.of_list wanted in
  let claimed = Array.make (Array.length old) false in
  let paired = Array.make (Array.length wanted) None in
  let claim index matches =
    let candidates =
      List.filter
        (fun at ->
           (not claimed.(at))
           &&
           match snd old.(at) with
           | Some identity -> matches identity
           | None -> false)
        (List.init (Array.length old) Fun.id)
    in
    match candidates with
    | [ at ] ->
      claimed.(at) <- true;
      paired.(index) <- Some (fst old.(at))
    | [] | _ :: _ :: _ -> ()
  in
  Array.iteri (fun index (identity, _) -> claim index (equal_identity identity)) wanted;
  let unpaired_labels =
    List.filteri (fun index _ -> Option.is_none paired.(index)) (Array.to_list wanted)
    |> List.map (fun ((identity : identity), _) -> identity.label)
  in
  let shared label = List.length (List.filter (String.equal label) unpaired_labels) > 1 in
  Array.iteri
    (fun index ((identity : identity), _) ->
       if Option.is_none paired.(index)
          && (not (String.equal identity.label ""))
          && not (shared identity.label)
       then claim index (fun (candidate : identity) -> String.equal candidate.label identity.label))
    wanted;
  Array.to_list (Array.mapi (fun index (_, value) -> paired.(index), value) wanted)
;;

(* Entries fill the places entries of their kind held in the file, in preset
   order. Entries past the last such place follow it. Panels the file had no
   place for go first, judges it had no place for go last. *)
let place_entries ~slots ~panels ~judges =
  let rec place slots ~panels ~judges =
    match slots with
    | [] -> List.concat panels @ List.concat judges
    | kind :: rest ->
      let last = not (List.exists (same_kind kind) rest) in
      (match kind with
       | Panels ->
         if last
         then List.concat panels @ place rest ~panels:[] ~judges
         else (
           match panels with
           | entry :: others -> entry @ place rest ~panels:others ~judges
           | [] -> place rest ~panels:[] ~judges)
       | Judges ->
         if last
         then List.concat judges @ place rest ~panels ~judges:[]
         else (
           match judges with
           | entry :: others -> entry @ place rest ~panels ~judges:others
           | [] -> place rest ~panels ~judges:[]))
  in
  if List.exists (same_kind Panels) slots
  then place slots ~panels ~judges
  else List.concat panels @ place slots ~panels:[] ~judges
;;

(* ── the rendered region ───────────────────────────────────────────────── *)

(* The grammar the file already uses wins: a preset written with [[panels]]
   entries keeps them, a flat one stays flat while it has one group. A new
   preset is flat when its one group has no label. *)
let flat_group (layout : layout) (preset : Fusion_policy.preset) =
  let had_entries =
    List.exists (fun (entry : entry) -> same_kind entry.kind Panels) layout.entries
  in
  let had_flat_panel = List.exists (fun (item : item) -> String.equal item.key panel_key) layout.body in
  match preset.panels with
  | [ group ] when (not had_entries) && (had_flat_panel || String.equal group.label "") ->
    Some group
  | [] | [ _ ] | _ :: _ :: _ -> None
;;

let render_region ~header_line (layout : layout) (preset : Fusion_policy.preset) =
  let flat = flat_group layout preset in
  let body_fields =
    match flat with
    | Some group -> group_fields group @ judge_fields preset
    | None ->
      (* With entries the body holds no group keys: the loader would refuse a
         flat [panel] beside them, and ignore the rest. *)
      List.concat_map
        (fun group -> List.map (fun (key, _) -> key, When_set None) (group_fields group))
        preset.panels
      @ judge_fields preset
  in
  let render_entries kind ~header wanted =
    let old = List.filter (fun (entry : entry) -> same_kind entry.kind kind) layout.entries in
    List.map
      (fun (paired, fields) ->
         match paired with
         | Some (entry : entry) -> entry.head @ (entry.header :: render_items entry.items fields)
         | None -> "" :: header :: render_items [] fields)
      (pair_entries old wanted)
  in
  let panels =
    match flat with
    | Some _ -> []
    | None ->
      render_entries Panels
        ~header:(table_array_header (panels_path preset.name))
        (List.map
           (fun (group : Fusion_policy.panel_group) ->
              { label = group.label; routes = group.models }, group_fields group)
           preset.panels)
  in
  let judges =
    render_entries Judges
      ~header:(table_array_header (judges_path preset.name))
      (List.map
         (fun (judge : Fusion_policy.judge_spec) ->
            { label = judge.jlabel; routes = [ judge.jmodel ] }, judge_entry_fields judge)
         preset.judges)
  in
  let slots = List.map (fun (entry : entry) -> entry.kind) layout.entries in
  (header_line :: render_items layout.body body_fields)
  @ place_entries ~slots ~panels ~judges
  @ layout.tail
;;

(* ── edits ─────────────────────────────────────────────────────────────── *)

let splice lines ~start ~stop replacement =
  let before, rest = E.split_at start lines in
  let _, after = E.split_at (stop - start) rest in
  before @ replacement @ after
;;

let join lines = E.join_lines lines ~trailing_newline:true

(* Where a new preset goes: after the last region whose header sits under
   [fusion], so the section stays together; at the end of the file when there is
   no [fusion] table at all. *)
let insertion_index kinds =
  let count = Array.length kinds in
  let last_fusion = ref None in
  Array.iteri
    (fun index kind ->
       match kind with
       | Header header when has_prefix ~prefix:fusion_path (header_path header) ->
         last_fusion := Some index
       | Header _ | Key _ | Comment | Blank | Data -> ())
    kinds;
  match !last_fusion with
  | None -> count
  | Some header ->
    let rec find_next index =
      if index >= count
      then count
      else (
        match kinds.(index) with
        | Header header when not (has_prefix ~prefix:fusion_path (header_path header)) -> index
        | Header _ | Key _ | Comment | Blank | Data -> find_next (index + 1))
    in
    let rec back index =
      if index > header + 1
      then (
        match kinds.(index - 1) with
        | Comment | Blank -> back (index - 1)
        | Header _ | Key _ | Data -> index)
      else index
    in
    back (find_next (header + 1))
;;

(* [block] at [at], with a blank line on each side it does not already have. *)
let insert_block lines ~at block =
  let count = Array.length lines in
  let separator = if at > 0 && not (is_blank lines.(at - 1)) then [ "" ] else [] in
  let trailer = if at < count && not (is_blank lines.(at)) then [ "" ] else [] in
  separator @ block @ trailer
;;

let upsert_preset content validated =
  let (preset : Fusion_policy.preset) = Fusion_policy.Validated_preset.preset validated in
  let* toml = parse content in
  let line_list, lines, kinds = read_lines content in
  match find_region kinds preset.name with
  | Some region ->
    let* layout = addressable_layout toml lines kinds region preset.name in
    let rendered = render_region ~header_line:lines.(region.start) layout preset in
    Ok (join (splice line_list ~start:region.start ~stop:region.stop rendered))
  | None ->
    if preset_declared toml preset.name
    then Error (Unaddressable_preset preset.name)
    else (
      let rendered =
        render_region ~header_line:(table_header (preset_path preset.name)) empty_layout preset
      in
      let at = insertion_index kinds in
      Ok (join (splice line_list ~start:at ~stop:at (insert_block lines ~at rendered))))
;;

let locate content name =
  let* toml = parse content in
  let line_list, lines, kinds = read_lines content in
  match find_region kinds name with
  | Some region ->
    let* _layout = addressable_layout toml lines kinds region name in
    Ok (toml, line_list, kinds, region)
  | None ->
    if preset_declared toml name
    then Error (Unaddressable_preset name)
    else Error (Preset_absent name)
;;

let is_blank_kind = function
  | Blank -> true
  | Header _ | Key _ | Comment | Data -> false
;;

let delete_preset content ~name =
  let* _toml, line_list, kinds, region = locate content name in
  let start = attached_comments_start kinds region.start in
  (* One blank line separated the preset from what came before. Left behind,
     it would stack on the blank below, or end the file with a blank line. *)
  let start =
    if start > 0
       && is_blank_kind kinds.(start - 1)
       && (region.stop >= Array.length kinds || is_blank_kind kinds.(region.stop))
    then start - 1
    else start
  in
  Ok (join (splice line_list ~start ~stop:region.stop []))
;;

let rename_preset content ~from ~target =
  if String.equal from target
  then Result.map (fun _ -> content) (locate content from)
  else
    let* toml, line_list, kinds, region = locate content from in
    if preset_declared toml target
    then Error (Preset_exists target)
    else (
      let old_prefix = preset_path from in
      let renamed path = preset_path target @ List.filteri (fun index _ -> index >= 3) path in
      let keep_comment line header =
        header ^ Option.value ~default:"" (E.header_trailing_comment line)
      in
      let line_list =
        List.mapi
          (fun index line ->
             if index < region.start || index >= region.stop
             then line
             else (
               match kinds.(index) with
               | Header (E.Table path) when has_prefix ~prefix:old_prefix path ->
                 keep_comment line (table_header (renamed path))
               | Header (E.Table_array path) when has_prefix ~prefix:old_prefix path ->
                 keep_comment line (table_array_header (renamed path))
               | Header _ | Key _ | Comment | Blank | Data -> line))
          line_list
      in
      let renamed_content = join line_list in
      match Otoml.find_result toml Otoml.get_string (fusion_path @ [ "default_preset" ]) with
      | Ok current when String.equal current from ->
        Ok
          (E.edit_table_scalar renamed_content ~path:(render_path fusion_path)
             ~key:"default_preset" ~value:(Some target))
      | Ok _ | Error _ -> Ok renamed_content)
;;

let set_settings content (settings : settings) =
  let line_list, lines, kinds = read_lines content in
  let count = Array.length kinds in
  let fields = settings_fields settings in
  let rec find_header index ~matches =
    if index >= count
    then None
    else (
      match kinds.(index) with
      | Header header when matches header -> Some index
      | Header _ | Key _ | Comment | Blank | Data -> find_header (index + 1) ~matches)
  in
  let is_fusion_table = function
    | E.Table path -> List.equal String.equal path fusion_path
    | E.Table_array _ -> false
  in
  match find_header 0 ~matches:is_fusion_table with
  | Some header ->
    let reading = read_items lines kinds ~stop:count (header + 1) in
    let rendered = (lines.(header) :: render_items reading.read fields) @ reading.after in
    join (splice line_list ~start:header ~stop:reading.next rendered)
  | None ->
    let table = table_header fusion_path :: render_items [] fields in
    let at =
      match
        find_header 0 ~matches:(fun header -> has_prefix ~prefix:fusion_path (header_path header))
      with
      | Some first -> attached_comments_start kinds first
      | None -> count
    in
    join (splice line_list ~start:at ~stop:at (insert_block lines ~at table))
;;
