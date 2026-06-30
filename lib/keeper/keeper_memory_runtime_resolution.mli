(** Runtime resolution shared by Memory OS LLM producers. *)

val runtime_id_for_librarian : runtime_id:string -> string
(** Runtime id after applying the optional librarian env override, then
    [runtime].librarian, then the caller's keeper runtime. *)

val provider_for_runtime
  :  runtime_id:string
  -> (Llm_provider.Provider_config.t, string) result
(** Resolve a runtime id to the provider config used at the OAS boundary.
    Missing runtime ids return [Error] instead of silently substituting the
    default runtime. *)
