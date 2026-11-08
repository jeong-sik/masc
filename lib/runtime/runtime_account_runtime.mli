(** The runtime of one model on an account home that no provider of
    runtime.toml declares: a person's own subscription in the multi-account
    preview (plan D1-6a). It is the workspace's provider [template] with its id
    and account home replaced, and the template's binding of [model], in a
    configuration that holds them alone. Nothing is written and nothing is
    published: the runtime exists for the call that measures it. *)

type error =
  | Template_not_declared of string  (** No provider of the configuration has this id. *)
  | Model_not_bound of
      { template : string
      ; model : string
      }  (** The template has no binding of this model. *)
  | Not_materialized of string
      (** The configuration of the one runtime does not load; the diagnostic
          of {!Runtime.runtimes_of_config}. *)

val error_to_string : error -> string

val of_template
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> account_home:string
  -> model:string
  -> (Runtime_instance.t, error) result
