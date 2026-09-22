module Form = Masc_tui_schema_form
module Decode = Masc.Tui_decode

type request =
  { keeper : string
  ; preset : string
  ; topology : Fusion_types.fusion_topology
  ; prompt : string
  ; web_tools : bool
  }

(* Who said no to the last submit: the schema, before a request went out,
   or the server, in its own words. Drawn under different labels so a
   server's sentence is never read as a typing mistake. *)
type notice =
  | Input_refused of string
  | Server_refused of string

type t =
  { form : Form.t
  ; notice : notice option
  ; waiting : request option
        (* The submit whose answer has not arrived. *)
  }

type event =
  | Editing of t
  | Submitted of t * request
  | Closed

let ( let* ) = Result.bind

(* The field names are the endpoint's body keys, so the submitted value is
   the body once the topology is read back into its sum. *)
let keeper_key = "keeper"
let preset_key = "preset"
let topology_key = "topology"
let prompt_key = "prompt"
let web_tools_key = "web_tools"

let enum_of names = `List (List.map (fun name -> `String name) names)

(* The subset the schema form edits: enums are Left/Right choices, the
   boolean too, and the prompt is the one typed field. [minLength] keeps an
   empty prompt from reaching the server, which would refuse it anyway. *)
let schema ~keepers ~presets =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; ( "required"
      , enum_of [ keeper_key; preset_key; topology_key; prompt_key; web_tools_key ] )
    ; ( "properties"
      , `Assoc
          [ ( keeper_key
            , `Assoc
                [ "type", `String "string"
                ; "title", `String "Keeper"
                ; "description", `String "the Keeper that owns the run"
                ; "enum", enum_of keepers
                ] )
          ; ( preset_key
            , `Assoc
                [ "type", `String "string"
                ; "title", `String "preset"
                ; "description", `String "a [fusion.presets] entry of runtime.toml"
                ; "enum", enum_of presets
                ] )
          ; ( topology_key
            , `Assoc
                [ "type", `String "string"
                ; "title", `String "topology"
                ; "description", `String "how the panel feeds the judge"
                ; "enum", enum_of Fusion_types.all_fusion_topology_strings
                ] )
          ; ( prompt_key
            , `Assoc
                [ "type", `String "string"
                ; "title", `String "prompt"
                ; "description", `String "the question the panel answers"
                ; "minLength", `Int 1
                ] )
          ; ( web_tools_key
            , `Assoc
                [ "type", `String "boolean"
                ; "title", `String "web tools"
                ; "description", `String "let the panel search and read the web"
                ] )
          ] )
    ]

let first_or_default ~default names =
  match default with
  | Some name when List.mem name names -> Some name
  | Some _ | None -> List.nth_opt names 0

let open_form ~keepers ~keeper ~(options : Decode.fusion_launch_options) =
  let* () =
    if options.flo_enabled then Ok ()
    else Error "Fusion is disabled in runtime.toml; enable [fusion] before launching a run"
  in
  let* preset =
    match first_or_default ~default:(Some options.flo_default_preset) options.flo_presets with
    | Some preset -> Ok preset
    | None -> Error "runtime.toml declares no [fusion.presets]; a run needs one"
  in
  let* keeper =
    match first_or_default ~default:keeper keepers with
    | Some keeper -> Ok keeper
    | None -> Error "No Keeper is in the roster to own a Fusion run"
  in
  let initial =
    `Assoc
      [ keeper_key, `String keeper
      ; preset_key, `String preset
      ; topology_key, `String (Fusion_types.fusion_topology_to_string Fusion_types.Simple)
      ; web_tools_key, `Bool false
      ]
  in
  let* form = Form.create ~schema:(schema ~keepers ~presets:options.flo_presets) ~initial in
  Ok { form; notice = None; waiting = None }

let submitting launch = Option.is_some launch.waiting

let string_member key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Ok value
      | Some _ | None -> Error (Printf.sprintf "the form's %s is not a string" key))
  | _ -> Error "the form's value is not an object"

let bool_member key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Bool value) -> Ok value
      | Some _ | None -> Error (Printf.sprintf "the form's %s is not a boolean" key))
  | _ -> Error "the form's value is not an object"

(* The schema already held each field to its enum; reading the topology back
   into the sum is what lets the request carry a variant and not a string.
   The server trims the prompt and refuses a blank one, so a prompt of spaces
   is refused here, before a request goes out. *)
let request_of_value value =
  let* keeper = string_member keeper_key value in
  let* preset = string_member preset_key value in
  let* topology_wire = string_member topology_key value in
  let* topology =
    match Fusion_types.fusion_topology_of_string topology_wire with
    | Some topology -> Ok topology
    | None -> Error (Printf.sprintf "unknown topology %S" topology_wire)
  in
  let* prompt = string_member prompt_key value in
  let* prompt =
    match String.trim prompt with
    | "" -> Error "the prompt is blank"
    | trimmed -> Ok trimmed
  in
  let* web_tools = bool_member web_tools_key value in
  Ok { keeper; preset; topology; prompt; web_tools }

let edit ~key launch =
  (* A submit in flight takes nothing but the key that leaves. Every other
     key would act on values the operator can no longer change, and [Esc] has
     to stay available: the answer can fail to arrive at all -- a cancelled
     fiber never delivers one -- and without this the surface would hold every
     key, [q] included, for the rest of the process. Leaving does not unsend
     the request, so the caller says the run may have started. *)
  if submitting launch then (if String.equal key "esc" then Closed else Editing launch)
  else
    match Form.handle ~key launch.form with
    | Error detail -> Editing { launch with notice = Some (Input_refused detail) }
    | Ok Form.Cancel -> Closed
    | Ok (Form.Updated form) -> Editing { launch with form; notice = None }
    | Ok (Form.Submit value) -> (
        match request_of_value value with
        | Error detail -> Editing { launch with notice = Some (Input_refused detail) }
        | Ok request -> Submitted ({ launch with notice = None; waiting = Some request }, request))

let paste ~text launch =
  if submitting launch then launch
  else { launch with form = Form.insert_text ~text launch.form }

let refused ~detail launch = { launch with notice = Some (Server_refused detail); waiting = None }

let request_body request =
  `Assoc
    [ prompt_key, `String request.prompt
    ; preset_key, `String request.preset
    ; topology_key, `String (Fusion_types.fusion_topology_to_string request.topology)
    ; web_tools_key, `Bool request.web_tools
    ]

let lines launch =
  (match launch.notice with
   | None -> []
   | Some (Input_refused detail) -> [ "Input error: " ^ detail ]
   | Some (Server_refused detail) -> [ "Refused: " ^ detail ])
  @ (match launch.waiting with
     | Some request -> [ "Starting the run for " ^ request.keeper ^ "..." ]
     | None -> [])
  @ Form.lines launch.form

let hints = "Tab:field  Left/Right:choice  Ctrl-U:unset  Ctrl-S:review  Esc:cancel"
