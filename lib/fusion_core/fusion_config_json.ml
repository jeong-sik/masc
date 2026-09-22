(* Fusion config -> JSON projection for the dashboard read endpoint.

   RFC-0306 §3.1. The dashboard fusion settings editor needs the full active
   product-relevant [Fusion_policy.t] fields as structured JSON to populate its
   form (panel roster, meta judge, JoJ first-round judges). The config types
   derive only [show]/[eq], so the shape is written by hand here, and the write
   endpoint decodes the same shape back with [preset_of_yojson]. *)

let opt_int : int option -> Yojson.Safe.t = function
  | None -> `Null
  | Some n -> `Int n

let opt_float : float option -> Yojson.Safe.t = function
  | None -> `Null
  | Some s -> `Float s

let panel_group_to_yojson (g : Fusion_policy.panel_group) : Yojson.Safe.t =
  `Assoc
    [ ( "models"
      , `List (List.map (fun m -> `String m) g.Fusion_policy.models) )
    ; ("label", `String g.Fusion_policy.label)
    ; ("system_prompt", `String g.Fusion_policy.system_prompt)
    ; ("web_tools", `Bool g.Fusion_policy.web_tools)
    ; ("max_output_tokens", opt_int g.Fusion_policy.max_output_tokens)
    ; ("timeout_s", opt_float g.Fusion_policy.timeout_s)
    ]

(* Judge fields are prefixed [j*] in the record; the JSON drops the prefix so the
   panel/judge shapes read symmetrically on the client. *)
let judge_spec_to_yojson (j : Fusion_policy.judge_spec) : Yojson.Safe.t =
  `Assoc
    [ ("model", `String j.Fusion_policy.jmodel)
    ; ("label", `String j.Fusion_policy.jlabel)
    ; ("system_prompt", `String j.Fusion_policy.jsystem_prompt)
    ; ("web_tools", `Bool j.Fusion_policy.jweb_tools)
    ; ("max_output_tokens", opt_int j.Fusion_policy.jmax_output_tokens)
    ; ("timeout_s", opt_float j.Fusion_policy.jtimeout_s)
    ]

let preset_to_yojson (p : Fusion_policy.preset) : Yojson.Safe.t =
  `Assoc
    [ ("name", `String p.Fusion_policy.name)
    ; ("panels", `List (List.map panel_group_to_yojson p.Fusion_policy.panels))
    ; ("judge", `String p.Fusion_policy.judge)
    ; ("judge_system_prompt", `String p.Fusion_policy.judge_system_prompt)
    ; ("judge_max_output_tokens", opt_int p.Fusion_policy.judge_max_output_tokens)
    ; ("judge_timeout_s", opt_float p.Fusion_policy.judge_timeout_s)
    ; ("judges", `List (List.map judge_spec_to_yojson p.Fusion_policy.judges))
    ; ("min_answered", `Int p.Fusion_policy.min_answered)
    ]

let to_yojson (c : Fusion_policy.t) : Yojson.Safe.t =
  `Assoc
    [ ("enabled", `Bool c.Fusion_policy.enabled)
    ; ("default_preset", `String c.Fusion_policy.default_preset)
    ; ("staged_judge_group_size", `Int c.Fusion_policy.staged_judge_group_size)
    ; ( "presets"
      , `List
          (List.map
             (fun (vp : Fusion_policy.Validated_preset.t) ->
               preset_to_yojson (vp :> Fusion_policy.preset))
             c.Fusion_policy.presets) )
    ]

(* ── decode ── *)

let ( let* ) = Result.bind

let fields ~what = function
  | `Assoc fields -> Ok fields
  | _ -> Error (what ^ " must be a JSON object")
;;

let exact ~what ~keys fields =
  match
    List.find_opt (fun (key, _) -> not (List.mem key keys)) fields,
    List.find_opt (fun key -> not (List.mem_assoc key fields)) keys
  with
  | Some (key, _), _ -> Error (Printf.sprintf "%s has an unknown key %S" what key)
  | None, Some key -> Error (Printf.sprintf "%s is missing %S" what key)
  | None, None -> Ok ()
;;

let field ~what key fields decode =
  match List.assoc_opt key fields with
  | Some json -> decode json |> Result.map_error (fun detail -> Printf.sprintf "%s.%s %s" what key detail)
  | None -> Error (Printf.sprintf "%s is missing %S" what key)
;;

let string = function
  | `String text -> Ok text
  | _ -> Error "must be a string"
;;

let bool = function
  | `Bool value -> Ok value
  | _ -> Error "must be a boolean"
;;

let int = function
  | `Int value -> Ok value
  | _ -> Error "must be an integer"
;;

let float = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "must be a number"
;;

let nullable decode = function
  | `Null -> Ok None
  | json -> Result.map Option.some (decode json)
;;

let list decode = function
  | `List items ->
    List.fold_right
      (fun item acc ->
         let* rest = acc in
         let* value = decode item in
         Ok (value :: rest))
      items (Ok [])
  | _ -> Error "must be an array"
;;

let group_keys = [ "models"; "label"; "system_prompt"; "web_tools"; "max_output_tokens"; "timeout_s" ]

let panel_group_of_yojson json : (Fusion_policy.panel_group, string) result =
  let what = "panel group" in
  let* fields = fields ~what json in
  let* () = exact ~what ~keys:group_keys fields in
  let* models = field ~what "models" fields (list string) in
  let* label = field ~what "label" fields string in
  let* system_prompt = field ~what "system_prompt" fields string in
  let* web_tools = field ~what "web_tools" fields bool in
  let* max_output_tokens = field ~what "max_output_tokens" fields (nullable int) in
  let* timeout_s = field ~what "timeout_s" fields (nullable float) in
  Ok { Fusion_policy.models; label; system_prompt; web_tools; max_output_tokens; timeout_s }
;;

let judge_keys = [ "model"; "label"; "system_prompt"; "web_tools"; "max_output_tokens"; "timeout_s" ]

let judge_spec_of_yojson json : (Fusion_policy.judge_spec, string) result =
  let what = "judge" in
  let* fields = fields ~what json in
  let* () = exact ~what ~keys:judge_keys fields in
  let* jmodel = field ~what "model" fields string in
  let* jlabel = field ~what "label" fields string in
  let* jsystem_prompt = field ~what "system_prompt" fields string in
  let* jweb_tools = field ~what "web_tools" fields bool in
  let* jmax_output_tokens = field ~what "max_output_tokens" fields (nullable int) in
  let* jtimeout_s = field ~what "timeout_s" fields (nullable float) in
  Ok
    { Fusion_policy.jmodel
    ; jlabel
    ; jsystem_prompt
    ; jweb_tools
    ; jmax_output_tokens
    ; jtimeout_s
    }
;;

let preset_keys =
  [ "name"
  ; "panels"
  ; "judge"
  ; "judge_system_prompt"
  ; "judge_max_output_tokens"
  ; "judge_timeout_s"
  ; "judges"
  ; "min_answered"
  ]
;;

let preset_of_yojson json : (Fusion_policy.preset, string) result =
  let what = "preset" in
  let* fields = fields ~what json in
  let* () = exact ~what ~keys:preset_keys fields in
  let* name = field ~what "name" fields string in
  let* panels = field ~what "panels" fields (list panel_group_of_yojson) in
  let* judge = field ~what "judge" fields string in
  let* judge_system_prompt = field ~what "judge_system_prompt" fields string in
  let* judge_max_output_tokens = field ~what "judge_max_output_tokens" fields (nullable int) in
  let* judge_timeout_s = field ~what "judge_timeout_s" fields (nullable float) in
  let* judges = field ~what "judges" fields (list judge_spec_of_yojson) in
  let* min_answered = field ~what "min_answered" fields int in
  Ok
    { Fusion_policy.name
    ; panels
    ; judge
    ; judge_system_prompt
    ; judge_max_output_tokens
    ; judge_timeout_s
    ; judges
    ; min_answered
    }
;;
