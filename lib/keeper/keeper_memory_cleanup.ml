module Current = Keeper_memory_os_current
module Limits = Keeper_memory_limits

type outcome =
  | Disabled
  | Within_limits
  | Already_reviewed
  | Reviewed of { remaining_excess : bool }
  | Unavailable of string

(* A successful no-change decision is still a decision. Reconsider when its
   actual input changes, rather than paying for the same snapshot every wake.
   A failed/cancelled pass is not remembered and can retry on the next wake. *)
let reviewed : ((string * string), string) Hashtbl.t = Hashtbl.create 16
let mutex = Stdlib.Mutex.create ()

let forget ~base_path ~keeper_name =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Stdlib.Mutex.protect mutex (fun () -> Hashtbl.remove reviewed (keepers_dir, keeper_name))
;;

let run_with ~execute ~base_path ~keeper_name =
  match Env_config.KeeperMemoryOs.librarian_config_state () with
  | Disabled | Invalid -> Disabled
  | Enabled ->
    let config = Workspace.default_config base_path in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let key = keepers_dir, keeper_name in
    let read () = Domain_pool_ref.submit_io_or_inline (fun () ->
      Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name) in
    match read () with
    | Error detail -> Unavailable detail
    | Ok None -> Within_limits
    | Ok (Some snapshot) ->
      let limits = Limits.current snapshot.facts in
      if not (Limits.exceeded limits) then Within_limits
      else
        match Domain_pool_ref.submit_io_or_inline (fun () ->
          Keeper_meta_store.read_effective_meta_presence_named config keeper_name) with
        | Error detail | Ok (_, Keeper_meta_store.Meta_not_current detail) -> Unavailable detail
        | Ok (_, Keeper_meta_store.Meta_absent) -> Unavailable "Keeper metadata is absent"
        | Ok (keeper_id, Keeper_meta_store.Meta_present meta) ->
            let input : Keeper_librarian.input =
              { keeper_id
              ; turn_ref = Ids.Turn_ref.make
                  ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                  ~absolute_turn:meta.runtime.usage.total_turns
              ; keeper_instructions = meta.instructions
              ; current = Some { facts = snapshot.facts }
              ; historical_task_contexts = []
              ; goal_context = Domain_pool_ref.submit_io_or_inline (fun () ->
                  Keeper_librarian_input_sources.goal_context_for_task
                    ~config meta.current_task_id)
              ; working_context = Keeper_librarian_context.empty
              ; messages = []
              ; tool_observations = []
              ; counterpart_observations = []
              } in
            let signature = Digestif.SHA256.(to_hex (digest_string
              (Yojson.Safe.to_string
                (`Assoc
                  [ "variables", `Assoc (List.map (fun (name, value) -> name, `String value)
                      (Keeper_librarian.prompt_variables input))
                  ; "template", `String (Prompt_registry.get_prompt Prompt_names.librarian)
                  ; "context_rule", `String
                      (Prompt_registry.get_prompt Prompt_names.librarian_working_contexts_rule)
                  ])))) in
            let seen = Stdlib.Mutex.protect mutex (fun () ->
              Hashtbl.find_opt reviewed key = Some signature) in
            if seen then Already_reviewed
            else
            if not (execute ~keepers_dir ~keeper_name ~expected_revision:snapshot.revision input)
            then Unavailable "Librarian memory cleanup did not commit"
            else (
              (* Remember only the input actually reviewed. A concurrent write
                 or partial consolidation remains eligible on the next wake. *)
              Stdlib.Mutex.protect mutex (fun () -> Hashtbl.replace reviewed key signature);
              match read () with
              | Error detail -> Unavailable detail
              | Ok None -> Unavailable "Memory snapshot disappeared after cleanup"
              | Ok (Some after) ->
                Reviewed { remaining_excess = Limits.exceeded (Limits.current after.facts) })
;;

let run ~base_path ~keeper_name =
  let execute ~keepers_dir ~keeper_name ~expected_revision input =
    let committed = ref false in
    Keeper_librarian_runtime.run_best_effort
      ~write_scope:Memory_maintenance
      ~on_memory_committed:(fun () -> committed := true)
      ~base_path ~keepers_dir ~keeper_id:keeper_name
      ~expected_revision:(Some expected_revision) input;
    !committed
  in
  run_with ~execute ~base_path ~keeper_name
;;

module For_testing = struct
  let run_with = run_with
end
