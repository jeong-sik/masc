(* Fusion 설정 작성기 (구현). 계약: fusion_config_writer.mli *)

module E = Toml_line_editor

let ( let* ) = Result.bind

type error =
  | Preset_absent of string
  | Preset_exists of string
  | Unaddressable_preset of string
  | Unaddressable_settings
  | Unreadable of string

let error_message = function
  | Preset_absent name -> Printf.sprintf "preset %s does not exist" name
  | Preset_exists name -> Printf.sprintf "preset %s already exists" name
  | Unaddressable_preset name ->
    Printf.sprintf
      "preset %s is not one [fusion.presets.%s] table holding all its keys, with only \
       its panels and judges entries right below it; edit it in the raw runtime.toml"
      name name
  | Unaddressable_settings ->
    "fusion is not written as a [fusion] table with its keys right below the header; \
     edit it in the raw runtime.toml"
  | Unreadable detail -> "runtime.toml does not parse as TOML: " ^ detail
;;

type settings =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  }

let fusion_path = [ "fusion" ]
let panels_key = "panels"
let judges_key = "judges"
let panel_key = "panel"

(* A file the writer can edit: it parses, and [fusion], when present, is a
   table. Writing [\[fusion.presets.x\]] beside a scalar [fusion] would name
   the key twice. *)
let parse content =
  let* toml =
    Result.map_error (fun detail -> Unreadable detail) (Otoml.Parser.from_string_result content)
  in
  match Otoml.find_opt toml Fun.id fusion_path with
  | None | Some (Otoml.TomlTable _) -> Ok toml
  | Some
      ( Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ | Otoml.TomlArray _
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ ) -> Error Unaddressable_settings
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

type source =
  { line_list : string list
  ; lines : string array
  ; kinds : line_kind array
  ; trailing_newline : bool
  }

let read_lines content =
  let line_list, trailing_newline = E.split_lines content in
  { line_list
  ; lines = Array.of_list line_list
  ; kinds = Array.of_list (classify line_list)
  ; trailing_newline
  }
;;

(* Lines read on their own, as the grammar reads them in the file. A CRLF
   file keeps its [\r] on every line, so a value that spans lines holds the
   same line endings the loader read; the final newline makes the last line
   whole. *)
let parse_lines lines = Otoml.Parser.from_string_result (String.concat "\n" lines ^ "\n")

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

(* One key and its lines: the comments and blanks above it, every line the
   value spans, and the comments right below the value. A comment block sits
   with the key it touches without a blank line; a block touching neither, or
   both, is the lead of the key below (TOML comments precede what they
   describe). *)
type item =
  { key : string
  ; lead : string list
  ; value_lines : string list
  ; trail : string list
  }

let item_lines (item : item) = item.lead @ item.value_lines @ item.trail

type entry_kind =
  | Panels
  | Judges

let same_kind a b =
  match a, b with
  | Panels, Panels | Judges, Judges -> true
  | Panels, Judges | Judges, Panels -> false
;;

(* What an entry names, read from its own lines: the label and the routes a
   panel group holds, or a first judge's label and model. *)
type identity =
  { label : string
  ; routes : string list
  }

type entry =
  { kind : entry_kind
  ; head : string list  (** comments and blanks above the header *)
  ; header : string
  ; items : item list
  ; identity : identity
  }

type layout =
  { body : item list
  ; entries : entry list  (** in file order *)
  }

let empty_layout = { body = []; entries = [] }

type reading =
  { read : item list
  ; after : string list  (** the lead of what follows the last item *)
  ; next : int
  ; at_header : E.header option  (** the header at [next]; [None] at [stop] *)
  }

(* The comments and blanks between two values, split between them: what
   comes before the last blank line trails the value above, the last blank
   and what follows lead the key or header below. With no blank line the
   block leads what follows; with nothing following it trails. *)
let split_between ~follows pending =
  let rec last_blank index best = function
    | [] -> best
    | line :: rest -> last_blank (index + 1) (if is_blank line then Some index else best) rest
  in
  match follows, last_blank 0 None pending with
  | false, _ -> pending, []
  | true, None -> [], pending
  | true, Some at ->
    ( List.filteri (fun index _ -> index < at) pending
    , List.filteri (fun index _ -> index >= at) pending )
;;

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
  let settle ~follows pending read =
    let pending = List.rev pending in
    match read with
    | [] -> read, pending
    | (last : item) :: earlier ->
      let trail, lead = split_between ~follows pending in
      { last with trail } :: earlier, lead
  in
  let rec walk index pending read =
    let finish at_header =
      let read, after = settle ~follows:(Option.is_some at_header) pending read in
      { read = List.rev read; after; next = index; at_header }
    in
    if index >= stop
    then finish None
    else (
      match kinds.(index) with
      | Header header -> finish (Some header)
      | Key key ->
        let next = value_end (index + 1) in
        let read, lead = settle ~follows:true pending read in
        walk next [] ({ key; lead; value_lines = slice index next; trail = [] } :: read)
      | Comment | Blank | Data -> walk (index + 1) (lines.(index) :: pending) read)
  in
  walk index [] []
;;

let entry_kind name = function
  | E.Table_array path when List.equal String.equal path (panels_path name) -> Some Panels
  | E.Table_array path when List.equal String.equal path (judges_path name) -> Some Judges
  | E.Table_array _ | E.Table _ -> None
;;

(* A key the loader reads with a default: absent reads as [absent]. A value
   of another type is the loader's type error, so the entry has no identity. *)
let read_key toml key accessor ~absent =
  if Otoml.path_exists toml [ key ]
  then Otoml.find_result toml accessor [ key ]
  else Ok absent
;;

let entry_identity kind (items : item list) =
  let* toml = parse_lines (List.concat_map (fun (item : item) -> item.value_lines) items) in
  let* label = read_key toml "label" Otoml.get_string ~absent:"" in
  match kind with
  | Panels ->
    let* routes = read_key toml panel_key (Otoml.get_array Otoml.get_string) ~absent:[] in
    Ok { label; routes }
  | Judges ->
    let* model = read_key toml "model" Otoml.get_string ~absent:"" in
    Ok { label; routes = [ model ] }
;;

(* [None] when a header in the region opens something other than a panels or
   judges entry of this preset, or an entry's identity does not read. *)
let read_layout lines kinds region name =
  let first = read_items lines kinds ~stop:region.stop (region.start + 1) in
  let rec entries acc (reading : reading) =
    match reading.at_header with
    | None -> Some { body = first.read; entries = List.rev acc }
    | Some header ->
      (match entry_kind name header with
       | None -> None
       | Some kind ->
         let inner = read_items lines kinds ~stop:region.stop (reading.next + 1) in
         (match entry_identity kind inner.read with
          | Error _ -> None
          | Ok identity ->
            entries
              ({ kind
               ; head = reading.after
               ; header = lines.(reading.next)
               ; items = inner.read
               ; identity
               }
               :: acc)
              inner))
  in
  entries [] first
;;

(* Every key of the preset's table must come from the region, and panels and
   judges only from entries. A key written elsewhere, such as a dotted
   [presets.x.min_answered] under [\[fusion\]], or an inline [judges = \[...\]]
   in the body, would stay where it is beside what the writer writes. A flat
   [panel] beside entries is the two grammars at once, which the loader
   refuses. *)
let keys_in_region toml name (layout : layout) =
  let has_entry kind =
    List.exists (fun (entry : entry) -> same_kind entry.kind kind) layout.entries
  in
  let body_has key = List.exists (fun (item : item) -> String.equal item.key key) layout.body in
  match Otoml.find_result toml Otoml.get_table (preset_path name) with
  | Error _ -> false
  | Ok table ->
    (not (body_has panels_key))
    && (not (body_has judges_key))
    && not (body_has panel_key && has_entry Panels)
    && List.for_all
         (fun (key, _) ->
            body_has key
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
  match parse_lines item.value_lines with
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
         | None -> item_lines item
         | Some presence ->
           (match resolve presence ~present:true with
            | None -> []
            | Some field ->
              let unchanged =
                match item_field item with
                | Some read -> same_value field read
                | None -> false
              in
              item_lines
                { item with
                  value_lines =
                    (if unchanged then item.value_lines else field_lines ~key:item.key field)
                }))
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

let equal_identity a b = String.equal a.label b.label && List.equal String.equal a.routes b.routes

(* Pair each wanted entry with the old entry it continues: first the one with
   the same label and routes, then, among those left, the one with the same
   non-empty label, then the next old entry still unpaired. An identity that
   two old entries share, or a label that two wanted entries still share,
   pairs with neither in the first two passes. *)
let pair_entries (old : entry list) (wanted : (identity * 'a) list) =
  let old = Array.of_list old in
  let wanted = Array.of_list wanted in
  let claimed = Array.make (Array.length old) false in
  let paired = Array.make (Array.length wanted) None in
  let claim index matches =
    let candidates =
      List.filter
        (fun at -> (not claimed.(at)) && matches old.(at).identity)
        (List.init (Array.length old) Fun.id)
    in
    match candidates with
    | [ at ] ->
      claimed.(at) <- true;
      paired.(index) <- Some old.(at)
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
  (* What neither pass paired continues the old entries left, in order: an
     unlabelled group's identity is its routes, so editing its routes must
     still keep its lines. *)
  Array.iteri
    (fun index _ ->
       if Option.is_none paired.(index)
       then (
         match List.find_opt (fun at -> not claimed.(at)) (List.init (Array.length old) Fun.id) with
         | Some at ->
           claimed.(at) <- true;
           paired.(index) <- Some old.(at)
         | None -> ()))
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
let had_flat_panel (layout : layout) =
  List.exists (fun (item : item) -> String.equal item.key panel_key) layout.body
;;

let flat_group (layout : layout) (preset : Fusion_policy.preset) =
  let had_entries =
    List.exists (fun (entry : entry) -> same_kind entry.kind Panels) layout.entries
  in
  match preset.panels with
  | [ group ] when (not had_entries) && (had_flat_panel layout || String.equal group.label "") ->
    Some group
  | [] | [ _ ] | _ :: _ :: _ -> None
;;

(* The group keys, by name only: what a body sheds when its groups move into
   entries. *)
let group_keys_only : Fusion_policy.panel_group =
  { models = []
  ; label = ""
  ; system_prompt = ""
  ; web_tools = false
  ; max_output_tokens = None
  ; timeout_s = None
  }
;;

let render_region ~header_line (layout : layout) (preset : Fusion_policy.preset) =
  let flat = flat_group layout preset in
  (* A flat preset that grows into entries loses its body group keys: the
     loader refuses a flat [panel] beside entries. A preset that already had
     entries keeps whatever group keys its body carries; the loader does not
     read them. *)
  let body_fields =
    match flat with
    | Some group -> group_fields group @ judge_fields preset
    | None ->
      (if had_flat_panel layout
       then List.map (fun (key, _) -> key, When_set None) (group_fields group_keys_only)
       else [])
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
  (header_line :: render_items layout.body body_fields) @ place_entries ~slots ~panels ~judges
;;

(* ── edits ─────────────────────────────────────────────────────────────── *)

let splice lines ~start ~stop replacement =
  let before, rest = E.split_at start lines in
  let _, after = E.split_at (stop - start) rest in
  before @ replacement @ after
;;

let join (source : source) lines = E.join_lines lines ~trailing_newline:source.trailing_newline

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
let insert_block (source : source) ~at block =
  let count = Array.length source.lines in
  let separator = if at > 0 && not (is_blank source.lines.(at - 1)) then [ "" ] else [] in
  let trailer = if at < count && not (is_blank source.lines.(at)) then [ "" ] else [] in
  separator @ block @ trailer
;;

let upsert_preset content validated =
  let (preset : Fusion_policy.preset) = Fusion_policy.Validated_preset.preset validated in
  let* toml = parse content in
  let source = read_lines content in
  match find_region source.kinds preset.name with
  | Some region ->
    let* layout = addressable_layout toml source.lines source.kinds region preset.name in
    let rendered = render_region ~header_line:source.lines.(region.start) layout preset in
    Ok (join source (splice source.line_list ~start:region.start ~stop:region.stop rendered))
  | None ->
    if preset_declared toml preset.name
    then Error (Unaddressable_preset preset.name)
    else (
      let rendered =
        render_region ~header_line:(table_header (preset_path preset.name)) empty_layout preset
      in
      let at = insertion_index source.kinds in
      let block = insert_block source ~at rendered in
      Ok (join source (splice source.line_list ~start:at ~stop:at block)))
;;

let locate content name =
  let* toml = parse content in
  let source = read_lines content in
  match find_region source.kinds name with
  | Some region ->
    let* _layout = addressable_layout toml source.lines source.kinds region name in
    Ok (toml, source, region)
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
  let* _toml, source, region = locate content name in
  let kinds = source.kinds in
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
  Ok (join source (splice source.line_list ~start ~stop:region.stop []))
;;

(* The [\[fusion\]] table's own keys, written like a preset body. [fusion]
   written without that header (dotted keys at the root, an inline table)
   cannot take a key by lines. Without any [fusion] the table opens before the
   first [fusion] sub-table, or at the end of the file. *)
let write_fusion_table toml (source : source) fields =
  let kinds = source.kinds in
  let count = Array.length kinds in
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
    let reading = read_items source.lines kinds ~stop:count (header + 1) in
    let rendered = (source.lines.(header) :: render_items reading.read fields) @ reading.after in
    Ok (join source (splice source.line_list ~start:header ~stop:reading.next rendered))
  | None ->
    if Otoml.path_exists toml fusion_path
    then Error Unaddressable_settings
    else (
      let table = table_header fusion_path :: render_items [] fields in
      let at =
        match
          find_header 0 ~matches:(fun header -> has_prefix ~prefix:fusion_path (header_path header))
        with
        | Some first -> attached_comments_start kinds first
        | None -> count
      in
      Ok (join source (splice source.line_list ~start:at ~stop:at (insert_block source ~at table))))
;;

let rename_preset content ~from ~target =
  if String.equal from target
  then Result.map (fun _ -> content) (locate content from)
  else
    let* toml, source, region = locate content from in
    if preset_declared toml target
    then Error (Preset_exists target)
    else (
      let old_prefix = preset_path from in
      let renamed path =
        preset_path target @ List.filteri (fun index _ -> index >= List.length old_prefix) path
      in
      let keep_comment line header =
        match E.header_trailing_comment line with
        | None -> header
        | Some comment -> header ^ comment
      in
      let line_list =
        List.mapi
          (fun index line ->
             if index < region.start || index >= region.stop
             then line
             else (
               match source.kinds.(index) with
               | Header (E.Table path) when has_prefix ~prefix:old_prefix path ->
                 keep_comment line (table_header (renamed path))
               | Header (E.Table_array path) when has_prefix ~prefix:old_prefix path ->
                 keep_comment line (table_array_header (renamed path))
               | Header _ | Key _ | Comment | Blank | Data -> line))
          source.line_list
      in
      let renamed_content = join source line_list in
      match Otoml.find_result toml Otoml.get_string (fusion_path @ [ "default_preset" ]) with
      | Ok current when String.equal current from ->
        write_fusion_table toml (read_lines renamed_content)
          [ "default_preset", Always (Text target) ]
      | Ok _ | Error _ -> Ok renamed_content)
;;

let set_settings content (settings : settings) =
  let* toml = parse content in
  write_fusion_table toml (read_lines content) (settings_fields settings)
;;
