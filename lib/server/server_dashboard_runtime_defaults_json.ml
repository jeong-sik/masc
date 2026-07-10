(* Dashboard /runtime-defaults endpoint JSON builder.

   Serves the structured, ALREADY-RESOLVED runtime defaults and model routing
   that the runtime actually uses — the singletons populated by
   [Runtime.init_default] at startup (runtime.toml SSOT). This does NOT re-parse
   runtime.toml; the frontend consumes the resolved structure directly instead
   of the raw TOML source_text exposed by [/api/v1/runtime/config/raw].

   No fabricated defaults: when the runtime config is uninitialized the
   singletons hold [None]/[[]] and surface as null/empty arrays. The resolving
   accessors that raise on an unset default (e.g. [get_default_runtime_id])
   are intentionally avoided — the option-returning [get_default_runtime] is the
   only default source used here. *)

(* [Runtime.t] record fields ([provider], [model], [binding]) and the nested
   [Runtime_schema] record labels ([display_name], [api_name], [max_context],
   [is_default]) need to be in scope for field access. *)
open Runtime_schema

type runtime_entry =
  { id : string
  ; provider : string
  ; model : string
  ; max_context : int
  ; is_default : bool
  }

type resolved =
  { default_runtime_id : string option
  ; default_model : string option
  ; default_max_context : int option
  ; runtimes : runtime_entry list
  ; keeper_assignments : (string * string) list
  ; librarian_runtime_id : string option
  ; structured_judge_runtime_id : string option
  ; hitl_summary_runtime_id : string option
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  ; config_path : string option
  }

let string_opt_json = function
  | Some s -> `String s
  | None -> `Null
;;

let int_opt_json = function
  | Some i -> `Int i
  | None -> `Null
;;

let runtime_entry_json (e : runtime_entry) : Yojson.Safe.t =
  `Assoc
    [ "id", `String e.id
    ; "provider", `String e.provider
    ; "model", `String e.model
    ; "max_context", `Int e.max_context
    ; "is_default", `Bool e.is_default
    ]
;;

let keeper_assignment_json (keeper, runtime_id) : Yojson.Safe.t =
  `Assoc [ "keeper", `String keeper; "runtime_id", `String runtime_id ]
;;

let build ~generated_at_iso (r : resolved) : Yojson.Safe.t =
  `Assoc
    [ "generated_at_iso", `String generated_at_iso
    ; "dashboard_surface", `String "/api/v1/dashboard/runtime-defaults"
    ; "source", `String "runtime_config"
    ; "config_path", string_opt_json r.config_path
    ; "default_runtime_id", string_opt_json r.default_runtime_id
    ; "default_model", string_opt_json r.default_model
    ; "default_max_context", int_opt_json r.default_max_context
    ; "runtimes", `List (List.map runtime_entry_json r.runtimes)
    ; ( "model_routing"
      , `Assoc
          [ ( "keeper_assignments"
            , `List (List.map keeper_assignment_json r.keeper_assignments) )
          ; "librarian_runtime_id", string_opt_json r.librarian_runtime_id
          ; ( "structured_judge_runtime_id"
            , string_opt_json r.structured_judge_runtime_id )
          ; "hitl_summary_runtime_id", string_opt_json r.hitl_summary_runtime_id
          ; "cross_verifier_runtime_id", string_opt_json r.cross_verifier_runtime_id
          ; "media_failover", `List (List.map (fun s -> `String s) r.media_failover)
          ] )
    ]
;;

let resolved_of_runtime () : resolved =
  let default = Runtime.get_default_runtime () in
  let entry (rt : Runtime.t) : runtime_entry =
    { id = rt.id
    ; provider = rt.provider.display_name
    ; model = rt.model.api_name
    ; max_context = rt.model.max_context
    ; is_default = rt.binding.is_default
    }
  in
  { default_runtime_id = Option.map (fun (rt : Runtime.t) -> rt.id) default
  ; default_model = Option.map (fun (rt : Runtime.t) -> rt.model.api_name) default
  ; default_max_context =
      Option.map (fun (rt : Runtime.t) -> rt.model.max_context) default
  ; runtimes = List.map entry (Runtime.get_runtimes ())
  ; keeper_assignments = Runtime.keeper_assignments ()
  ; librarian_runtime_id = Runtime.librarian_runtime_id ()
  ; structured_judge_runtime_id = Runtime.structured_judge_runtime_id ()
  ; hitl_summary_runtime_id = Runtime.hitl_summary_runtime_id ()
  ; cross_verifier_runtime_id = Runtime.cross_verifier_runtime_id ()
  ; media_failover = Runtime.media_failover ()
  ; config_path = Runtime.config_path ()
  }
;;

let current ~generated_at_iso () : Yojson.Safe.t =
  build ~generated_at_iso (resolved_of_runtime ())
;;
