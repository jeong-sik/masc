(** The runtime of one binding on an account home that no provider of
    runtime.toml declares: a person's own subscription in the multi-account
    preview (plan D1-6a). It is the workspace's provider [template] with its id
    and account home replaced, and one binding of the template, in a
    configuration that holds them alone. Nothing is written and nothing is
    published: the runtime exists for the call that uses it. *)

(** Which binding of the template. *)
type binding =
  | Model of string
      (** The binding of this model: a verification, which then records the
          Runtime id the binding makes on the account. *)
  | Runtime of string
      (** The binding whose Runtime id on the account is this id: the Runtime
          a record of the authorization log names (plan D2-8). The id is
          compared whole with the id each binding makes, never cut apart. *)

type error =
  | Template_not_declared of string  (** No provider of the configuration has this id. *)
  | Model_not_bound of
      { template : string
      ; model : string
      }  (** The template has no binding of this model. *)
  | Runtime_not_bound of
      { template : string
      ; runtime_id : string
      }  (** No binding of the template makes this Runtime id on the account. *)
  | Not_materialized of string
      (** The configuration of the one runtime does not load; the diagnostic
          of {!Runtime.runtimes_of_config}. *)

val error_to_string : error -> string

(** The name of the error in an answer, one per constructor:
    [template_not_declared], [model_not_bound], [runtime_not_bound],
    [not_materialized]. *)
val error_code : error -> string

(** The binding of the template that [binding] chooses, moved onto the account
    [provider_id]: the binding {!of_template} makes the runtime of, found
    without making it. Its [model_id] is the key of the model's
    [models.<id>] table; the runtime calls the model's [api_name]. *)
val binding_of
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> binding:binding
  -> (Runtime_schema.binding, error) result

val of_template
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> account_home:string
  -> binding:binding
  -> (Runtime_instance.t, error) result
