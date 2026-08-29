type row =
  { model : string
  ; provider : string
  ; api_name : string option
  ; reasoning_effort : string option
  ; max_tokens : int option
  }

(* Section headers are [a.b] or [a."b with dots"]. The quoted form exists
   because model names carry dots (glm-5.2), which would otherwise split the
   path. Strip the quotes here so the two tables key on the same string. *)
let unquote s =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

let section_of_line line =
  let trimmed = String.trim line in
  let n = String.length trimmed in
  if n < 2 || trimmed.[0] <> '[' || trimmed.[n - 1] <> ']'
  then None
  else (
    let inner = String.sub trimmed 1 (n - 2) in
    (* A double-bracket [[x]] leaves a stray bracket after the strip. Those
       are array-of-table entries and never name a binding. *)
    if String.length inner > 0 && (inner.[0] = '[' || inner.[String.length inner - 1] = ']')
    then None
    else (
      match String.index_opt inner '.' with
      | None -> None
      | Some i ->
        let head = String.sub inner 0 i in
        let tail = String.sub inner (i + 1) (String.length inner - i - 1) in
        (* Only the first dot separates the table from the name: a quoted
           name may hold more. Reject a tail that opens a sub-table
           ([models.x.capabilities]) by checking for an unquoted dot. *)
        if (not (String.length tail > 0 && tail.[0] = '"')) && String.contains tail '.'
        then None
        else Some (head, unquote tail)))

let key_value line =
  match String.index_opt line '=' with
  | None -> None
  | Some i ->
    let k = String.trim (String.sub line 0 i) in
    let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
    if String.length k = 0 || String.length v = 0 then None else Some (k, unquote v)

let is_comment line =
  let t = String.trim line in
  String.length t > 0 && t.[0] = '#'

(* Two passes over the same lines rather than one pass with a pending state:
   [models.X] can appear after [ollama_cloud.X], and a single pass would have
   to buffer either way. *)
let collect lines ~table_is_models =
  let acc = Hashtbl.create 64 in
  let current = ref None in
  List.iter
    (fun line ->
      match section_of_line line with
      | Some (head, name) ->
        let matches =
          if table_is_models
          then String.equal head "models"
          else not (String.equal head "models")
        in
        if matches
        then (
          current := Some (head, name);
          (* Register on the header, not on the first key. A section with no
             keys still exists -- [ollama_cloud.minimax-m3] shipped as a bare
             header -- and waiting for a key would drop its binding from the
             table entirely. *)
          if not (Hashtbl.mem acc name) then Hashtbl.replace acc name (head, []))
        else current := None
      | None ->
        if not (is_comment line)
        then (
          match !current, key_value line with
          | Some (_, name), Some (k, v) ->
            let head, fields = try Hashtbl.find acc name with Not_found -> ("", []) in
            Hashtbl.replace acc name (head, (k, v) :: fields)
          | _ -> ()))
    lines;
  acc

let int_of_value v = int_of_string_opt (String.trim v)

let parse lines =
  let models = collect lines ~table_is_models:true in
  let bindings = collect lines ~table_is_models:false in
  (* A [PROVIDER.NAME] section is a model binding only when [models.NAME]
     declares the model too. Sections like [providers.ollama] and
     [voice.tts] share the two-part shape and would otherwise land in the
     table. Pairing on the model table is structural, so a provider added
     later needs no edit here -- a hardcoded name list would. *)
  let rows =
    Hashtbl.fold
      (fun name (provider, fields) acc ->
        match Hashtbl.find_opt models name with
        | None -> acc
        | Some (_, model_fields) ->
          { model = name
          ; provider
          ; api_name = List.assoc_opt "api-name" model_fields
          ; reasoning_effort = List.assoc_opt "reasoning-effort" model_fields
          ; max_tokens = Option.bind (List.assoc_opt "max-tokens" fields) int_of_value
          }
          :: acc)
      bindings
      []
  in
  List.sort
    (fun a b ->
      match String.compare a.provider b.provider with
      | 0 -> String.compare a.model b.model
      | c -> c)
    rows

(* ASCII, not an em dash: padding counts bytes, and a multi-byte dash makes
   every column after it hang one cell short of where the header sits. *)
let absent = "-"

let effort_text = function
  | Some e -> e
  | None -> absent

let tokens_text = function
  | Some n -> string_of_int n
  | None -> absent

let pad s n =
  let len = String.length s in
  if len >= n then s else s ^ String.make (n - len) ' '

(* Clip on the model column only. A clipped "1638" for 16384 is a different
   number and reads as fact; a clipped name still points at the right row. *)
let clip s n = if String.length s <= n then s else String.sub s 0 (max 0 (n - 1)) ^ "~"

let effort_width = 8
let tokens_width = 11
let gutter = 2

let render ~width rows =
  let provider_width =
    List.fold_left (fun acc r -> max acc (String.length r.provider)) (String.length "provider") rows
  in
  let fixed = provider_width + gutter + effort_width + gutter + tokens_width + gutter in
  let model_width = max 8 (width - fixed) in
  let header =
    pad "provider" provider_width
    ^ String.make gutter ' '
    ^ pad "model" model_width
    ^ String.make gutter ' '
    ^ pad "effort" effort_width
    ^ String.make gutter ' '
    ^ "max-tokens"
  in
  let line r =
    let name =
      match r.api_name with
      | Some api when not (String.equal api r.model) -> r.model ^ " (" ^ api ^ ")"
      | Some _ | None -> r.model
    in
    pad r.provider provider_width
    ^ String.make gutter ' '
    ^ pad (clip name model_width) model_width
    ^ String.make gutter ' '
    ^ pad (effort_text r.reasoning_effort) effort_width
    ^ String.make gutter ' '
    ^ tokens_text r.max_tokens
  in
  match rows with
  | [] -> [ "no model bindings in runtime.toml" ]
  | _ -> header :: List.map line rows
