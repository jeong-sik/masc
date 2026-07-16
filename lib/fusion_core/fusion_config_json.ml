(* Fusion config -> JSON projection for the dashboard read endpoint.

   RFC-0306 §3.1. The dashboard fusion settings editor needs the full active
   [Fusion_policy.t] as structured JSON to populate its form (panel roster, meta
   judge, JoJ first-round judges, timeouts). No serializer existed: the config
   types derive only [show]/[eq], and the only consumer flattens errors to a
   string ([fusion_config_loader.ml]). This is a read-only projection; it does
   not round-trip back to TOML (the write path is line-based, RFC-0306 §3.2). *)

let opt_string : string option -> Yojson.Safe.t = function
  | None -> `Null
  | Some s -> `String s

let panel_group_to_yojson (g : Fusion_policy.panel_group) : Yojson.Safe.t =
  `Assoc
    [ ( "models"
      , `List (List.map (fun m -> `String m) g.Fusion_policy.models) )
    ; ("label", `String g.Fusion_policy.label)
    ; ("system_prompt", `String g.Fusion_policy.system_prompt)
    ; ("web_tools", `Bool g.Fusion_policy.web_tools)
    ; ("timeout_s", `Float g.Fusion_policy.timeout_s)
    ]

(* Judge fields are prefixed [j*] in the record; the JSON drops the prefix so the
   panel/judge shapes read symmetrically on the client. *)
let judge_spec_to_yojson (j : Fusion_policy.judge_spec) : Yojson.Safe.t =
  `Assoc
    [ ("model", `String j.Fusion_policy.jmodel)
    ; ("label", `String j.Fusion_policy.jlabel)
    ; ("system_prompt", `String j.Fusion_policy.jsystem_prompt)
    ; ("web_tools", `Bool j.Fusion_policy.jweb_tools)
    ; ("timeout_s", `Float j.Fusion_policy.jtimeout_s)
    ]

let preset_to_yojson (p : Fusion_policy.preset) : Yojson.Safe.t =
  `Assoc
    [ ("name", `String p.Fusion_policy.name)
    ; ("panels", `List (List.map panel_group_to_yojson p.Fusion_policy.panels))
    ; ("judge", `String p.Fusion_policy.judge)
    ; ("judge_system_prompt", `String p.Fusion_policy.judge_system_prompt)
    ; ("judge_timeout_s", `Float p.Fusion_policy.judge_timeout_s)
    ; ("meta_timeout_s", `Float p.Fusion_policy.meta_timeout_s)
    ; ("judges", `List (List.map judge_spec_to_yojson p.Fusion_policy.judges))
    ; ("fallback_judge_model", opt_string p.Fusion_policy.fallback_judge_model)
    ]

let to_yojson (c : Fusion_policy.t) : Yojson.Safe.t =
  `Assoc
    [ ("enabled", `Bool c.Fusion_policy.enabled)
    ; ("default_preset", `String c.Fusion_policy.default_preset)
    ; ( "presets"
      , `List
          (List.map
             (fun (vp : Fusion_policy.Validated_preset.t) ->
               preset_to_yojson (vp :> Fusion_policy.preset))
             c.Fusion_policy.presets) )
    ]
