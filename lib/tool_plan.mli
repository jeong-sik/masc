
(** Plan Tool Handlers

    Extracted from mcp_server_eio.ml for testability, which [dispatch]
    provides: test_tool_plan_coverage drives all eight tools through it by
    name and never named a handler. The handlers themselves were exported
    too, and nothing outside this module ever called one.

    8 tools: plan_init, plan_update, note_add, deliver, plan_get,
             plan_set_task, plan_get_task, plan_clear_task
*)

(** Tool handler context *)
type context = {
  config: Workspace.config;
}

(** {1 Dispatcher} *)

(** Dispatch plan tool by name. Returns None if not a plan tool. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option

(* Plan tool schemas are declared in config/tools/masc_plan_*.toml and
   surfaced through Tool_schemas_misc.schemas in the Config chain. *)
