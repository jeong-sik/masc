(** Cycle-free template binding and person-runtime materialization used by
    both {!Runtime} (for on-demand person side-table lookup) and
    {!Runtime_account_runtime}. Depends only on schema/instance/validation
    modules, never {!Runtime}. *)

type binding =
  | Model of string
  | Runtime of string

type error =
  | Template_not_declared of string
  | Model_not_bound of
      { template : string
      ; model : string
      }
  | Runtime_not_bound of
      { template : string
      ; runtime_id : string
      }
  | Key_missing
  | Key_unreadable of Runtime_api_key_file.unreadable
  | Not_materialized of string

val error_to_string : error -> string
val error_code : error -> string

val template_binding
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> binding
  -> (Runtime_schema.provider * Runtime_schema.binding, error) result

val binding_of
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> binding:binding
  -> (Runtime_schema.binding, error) result

val http_provider_takes_key : Runtime_schema.provider -> bool

val materialize_person_binding
  :  Runtime_schema.config
  -> provider:Runtime_schema.provider
  -> binding:Runtime_schema.binding
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
  -> account_home:string option
  -> (Runtime_instance.t, error) result

val of_person_template
  :  Runtime_schema.config
  -> template:string
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
  -> account_home:string option
  -> binding:binding
  -> (Runtime_instance.t, error) result
