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

(** What the account runs on (RFC
    a-persons-api-key-is-their-own-provider-account 3.4). *)
type account =
  | Login  (** The login a client keeps in the home of the account. *)
  | Key of { key_file : string }
      (** The API key in this file
          ({!Runtime_account_home_layout.key_file}). *)

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
  | Key_missing
      (** The key file of a key account is not there
          ({!Runtime_api_key_file.read}). No client starts. *)
  | Key_unreadable of Runtime_api_key_file.unreadable
      (** The key file of a key account is there and gives no key. No client
          starts. *)
  | Not_materialized of string
      (** The configuration of the one runtime does not load; the diagnostic
          of {!Runtime.runtimes_of_config}. *)

val error_to_string : error -> string

(** The name of the error in an answer, one per constructor:
    [template_not_declared], [model_not_bound], [runtime_not_bound],
    [key_missing], [key_unreadable], [not_materialized]. The two of a key
    file are {!Runtime_api_key_file.read_error_code}. *)
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

(** The runtime of [binding] of [template] on the account [provider_id].

    The provider of the runtime takes its credential from [account] and never
    from the template: none for a [Login], the key file for a [Key]. So an
    account of a person runs on no credential the workspace declared for the
    template.

    The key file of a [Key] is read before the runtime is made, so a file
    that is missing or gives no key is [Key_missing] or [Key_unreadable] and
    not a sentence of a diagnostic. The adapter reads it again when it makes
    the runtime. *)
val of_template
  :  Runtime_schema.config
  -> template:string
  -> provider_id:string
  -> account_home:string
  -> account:account
  -> binding:binding
  -> (Runtime_instance.t, error) result

(** Build a person's runtime from [template] with a credential-free person
    seal ({!Runtime_account_access.seal_person}) for Claude Code / Codex or a
    declared home ({!Runtime_account_access.declare_muse_home}) for Muse serve,
    reading no key file, home configuration, or process environment at
    table-build time (RFC §3.4). Unrelated providers and bindings in the
    configuration are ignored. *)
val of_person_template
  :  Runtime_schema.config
  -> template:string
  -> provider_account_id:Authz_types.Provider_account_id.t
  -> integration_id:Authz_types.Integration_id.t
  -> account_home:string
  -> binding:binding
  -> (Runtime_instance.t, error) result
