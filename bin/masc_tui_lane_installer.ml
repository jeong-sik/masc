module Form = Masc_tui_schema_form
module Document = Masc_tui_lane_declaration
let ( let* ) = Result.bind
let field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some value -> Ok value | None -> Error ("missing " ^ name))
  | _ -> Error "expected object"
let text name json = let* value = field name json in match value with
  | `String text when String.trim text<>"" -> Ok text | _ -> Error ("expected nonblank " ^ name)
let string_schema = `Assoc ["type",`String "string";"minLength",`Int 1]
let object_schema properties = `Assoc ["type",`String "object";"properties",`Assoc properties;
  "required",`List (List.map (fun (key,_) -> `String key) properties);"additionalProperties",`Bool false]
type preview = {path:string;title:string;revision:string;image:string;image_state:string}
type t = Path of Form.t | Pending of int * string * Form.t | Binding of preview * Form.t
type event = Updated of t | Preview of string | Draft of Document.session | Cancel
let create () =
  Result.map (fun form -> Path form)
    (Form.create ~schema:(object_schema ["manifest_path",string_schema]) ~initial:(`Assoc []))
let accept_preview json =
  let* path = text "manifest_path" json in
  let* package = field "package" json in
  let* title = text "title" package in let* revision = text "revision" package in
  let* image = text "image" package in
  let* image_result = field "image" json in
  let* state = text "state" image_result in
  let* image_state = match state with
    | "available" -> let* digest = text "digest" image_result in Ok ("Available: " ^ digest)
    | "unverified" -> let* detail = text "detail" image_result in Ok ("Image unverified: " ^ detail)
    | _ -> Error "unknown image inspection state" in
  let* binding_schema = field "binding_schema" package in
  let* () = if binding_schema=`Null then Error "Package has no binding schema; use n for an advanced TOML declaration." else Ok () in
  let* form = Form.create ~schema:(object_schema ["installation_id",string_schema;"run_id",string_schema;"binding",binding_schema])
      ~initial:(`Assoc []) in
  Ok (Binding ({path;title;revision;image;image_state},form))
let begin_preview ~request_id ~path = function
  | Path form ->
      let* json = Form.value form in let* selected = text "manifest_path" json in
      if selected<>path then Error "preview path does not match the current input"
      else Ok (Pending (request_id,path,form))
  | Pending _ | Binding _ -> Error "manifest input is not ready for preview"
let receive_preview ~request_id ~path response = function
  | Pending (expected_id,expected_path,form) when expected_id=request_id && expected_path=path ->
      Some (match Result.bind response accept_preview with
        | Ok next -> next,None | Error detail -> Path form,Some detail)
  | Path _ | Pending _ | Binding _ -> None
let rec toml = function
  | `String value -> Ok (Otoml.TomlString value)
  | `Int value -> Ok (Otoml.TomlInteger value)
  | `Bool value -> Ok (Otoml.TomlBoolean value)
  | `Float value when Float.is_finite value -> Ok (Otoml.TomlFloat value)
  | `List values -> let* values = traverse values in Ok (Otoml.TomlArray values)
  | `Assoc fields ->
      let rec loop = function [] -> Ok [] | (key,value)::rest ->
        let* value = toml value in let* rest = loop rest in Ok ((key,value)::rest) in
      let* fields = loop fields in Ok (Otoml.TomlInlineTable fields)
  | _ -> Error "Input cannot be represented in a TOML declaration"
and traverse = function [] -> Ok [] | value::rest ->
  let* value = toml value in let* rest = traverse rest in Ok (value::rest)
let draft preview json =
  let* id = text "installation_id" json in let* run_id = text "run_id" json in
  let* session = Document.create (id ^ ".toml") in
  let* binding = field "binding" json in let* binding = toml binding in
  let source = Otoml.TomlTable ["id",Otoml.TomlString id;"run_id",Otoml.TomlString run_id;
      "manifest_path",Otoml.TomlString preview.path;"binding",binding] in
  Ok {session with text=Otoml.Printer.to_string source;
      message=Some "Local draft only. Review TOML, then s saves and requests application; inspect actual state afterwards."}
let handle ~key state =
  let form = match state with Path form | Pending (_,_,form) | Binding (_,form) -> form in
  let* event = Form.handle ~key form in
  match event,state with
  | Form.Cancel,_ -> Ok Cancel
  | _,Pending _ -> Ok (Updated state)
  | Form.Updated form,Path _ -> Ok (Updated (Path form))
  | Form.Updated form,Binding (preview,_) -> Ok (Updated (Binding (preview,form)))
  | Form.Submit json,Path _ -> Result.map (fun path -> Preview path) (text "manifest_path" json)
  | Form.Submit json,Binding (preview,_) -> Result.map (fun session -> Draft session) (draft preview json)
let paste ~text = function
  | Pending _ as state -> state
  | Path form -> Path (Form.insert_text ~text form)
  | Binding (preview,form) -> Binding (preview,Form.insert_text ~text form)
let lines = function
  | Pending (_,path,_) -> ["Reading package and image state · Esc:cancel";"Manifest: " ^ path]
  | Path form -> "Install Add-on: manifest path on the connected server" :: Form.lines form
  | Binding (preview,form) ->
      ["Install " ^ preview.title ^ " · revision " ^ preview.revision;
       "Manifest: " ^ preview.path;"Image: " ^ preview.image;preview.image_state;
       "Preview does not start a worker. Enter after review creates a local TOML draft."] @ Form.lines form
