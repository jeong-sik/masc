(* The ledger is these modules included in order, and each uses only the ones
   above it: the activation types, the errors, the ledger value, its JSON
   form, the decoders, the event rows, the replay of rows, the load of a
   store, the append of an event, and the observations. The interface of
   the whole is keeper_skill_activation_ledger.mli. *)
include Keeper_skill_activation_types
include Keeper_skill_activation_ledger_errors
include Keeper_skill_activation_ledger_model
include Keeper_skill_activation_ledger_encode
include Keeper_skill_activation_ledger_decode_parts
include Keeper_skill_activation_ledger_decode_activation
include Keeper_skill_activation_ledger_decode_ledger
include Keeper_skill_activation_ledger_events
include Keeper_skill_activation_ledger_replay
include Keeper_skill_activation_ledger_load
include Keeper_skill_activation_ledger_commit
include Keeper_skill_activation_ledger_observe

