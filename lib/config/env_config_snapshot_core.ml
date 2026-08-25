(** Pure entry/provenance projection for {!Env_config_snapshot}. *)

let mask_sensitive _value = "[REDACTED]"

let is_sensitive_name name =
  let lower = String.lowercase_ascii name in
  List.exists
    (fun pat ->
      let rec contains_at i =
        if i + String.length pat > String.length lower
        then false
        else if String.sub lower i (String.length pat) = pat
        then true
        else contains_at (i + 1)
      in
      contains_at 0)
    [ "token"; "password"; "secret"; "key"; "credential"; "neo4j_url"; "supabase" ]

type spec =
  { env_name : string
  ; description : string
  ; default_display : string
  ; sensitive : bool
  }

type effective_source =
  | Default
  | Environment

type observation =
  | Raw_environment of string option
  | Applied_value of
      { value : string
      ; source : effective_source
      }

type source_provenance =
  { kind : string
  ; detail : string
  ; derived_from : string list
  ; env_name : string
  ; raw_source : string
  ; raw_env_present : bool
  ; raw_env_blank : bool
  ; default_display : string
  ; sensitive : bool
  ; value_redacted : bool
  }

let make_spec ?(sensitive = false) ~default env_name description =
  let sensitive = sensitive || is_sensitive_name env_name in
  { env_name; description; default_display = default; sensitive }

let default_provenance (spec : spec) =
  match spec.default_display with
  | "(derived)" ->
      { kind = "derived"
      ; detail = "computed by runtime config helpers from related settings"
      ; derived_from = []
      ; env_name = spec.env_name
      ; raw_source = "derived_runtime"
      ; raw_env_present = false
      ; raw_env_blank = false
      ; default_display = spec.default_display
      ; sensitive = spec.sensitive
      ; value_redacted = false
      }
  | "(cwd)" ->
      { kind = "runtime"
      ; detail = "resolved from the process working directory or base path"
      ; derived_from = []
      ; env_name = spec.env_name
      ; raw_source = "runtime"
      ; raw_env_present = false
      ; raw_env_blank = false
      ; default_display = spec.default_display
      ; sensitive = spec.sensitive
      ; value_redacted = false
      }
  | _ ->
      { kind = "default"
      ; detail = "compiled default value"
      ; derived_from = []
      ; env_name = spec.env_name
      ; raw_source = "compiled_default"
      ; raw_env_present = false
      ; raw_env_blank = false
      ; default_display = spec.default_display
      ; sensitive = spec.sensitive
      ; value_redacted = false
      }

let source_provenance (spec : spec) ~raw_env raw =
  let raw_env_present = Option.is_some raw_env in
  let raw_env_blank =
    match raw_env with
    | Some value -> String.trim value = ""
    | None -> false
  in
  match raw with
  | Some _ ->
      { kind = "env"
      ; detail = "environment variable " ^ spec.env_name
      ; derived_from = []
      ; env_name = spec.env_name
      ; raw_source = "environment"
      ; raw_env_present
      ; raw_env_blank
      ; default_display = spec.default_display
      ; sensitive = spec.sensitive
      ; value_redacted = spec.sensitive
      }
  | None ->
      let provenance = default_provenance spec in
      { provenance with raw_env_present; raw_env_blank }

let applied_provenance (spec : spec) source =
  let raw_env_present = match source with Default -> false | Environment -> true in
  { kind = (match source with Default -> "default" | Environment -> "env")
  ; detail = "typed value resolved by the runtime owner"
  ; derived_from = []
  ; env_name = spec.env_name
  ; raw_source = "applied_runtime"
  ; raw_env_present
  ; raw_env_blank = false
  ; default_display = spec.default_display
  ; sensitive = spec.sensitive
  ; value_redacted = spec.sensitive
  }

let provenance_to_json p =
  `Assoc
    ([ "kind", `String p.kind
     ; "detail", `String p.detail
     ; "env", `String p.env_name
     ; "raw_source", `String p.raw_source
     ; "raw_env_present", `Bool p.raw_env_present
     ; "raw_env_blank", `Bool p.raw_env_blank
     ; "default", `String p.default_display
     ; "sensitive", `Bool p.sensitive
     ; "value_redacted", `Bool p.value_redacted
     ]
     @
     if p.derived_from = []
     then []
     else [ "derived_from", `List (List.map (fun v -> `String v) p.derived_from) ])

let to_json (spec : spec) observation =
  let provenance, display_value =
    match observation with
    | Applied_value { value; source } ->
      let value = if spec.sensitive then mask_sensitive value else value in
      applied_provenance spec source, Some value
    | Raw_environment raw_env ->
      let raw = String_util.option_trim raw_env in
      let provenance = source_provenance spec ~raw_env raw in
      let display_value =
        match raw with
        | None -> None
        | Some v when spec.sensitive -> Some (mask_sensitive v)
        | Some v -> Some v
      in
      provenance, display_value
  in
  `Assoc
    [ "env", `String spec.env_name
    ; "description", `String spec.description
    ; "value", Json_util.string_opt_to_json display_value
    ; "default", `String spec.default_display
    ; "source", `String provenance.kind
    ; "source_detail", `String provenance.detail
    ; "provenance", provenance_to_json provenance
    ; "sensitive", `Bool spec.sensitive
    ]
