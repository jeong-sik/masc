(** Pure prompt and output contract for the working-context Librarian pass,
    plus shared host-authored tool observation types read by v2 Librarian turn
    materialization. *)

type tool_observation_outcome =
  | Succeeded
  | Failed
  | Unknown

type tool_observation =
  { tool_name : string
  ; outcome : tool_observation_outcome
  }
(** Host-authored current-turn tool evidence. Tool payloads stay excluded from
    the Librarian prompt; this says only which tool completed and its typed
    execution outcome. [Unknown] remains explicit rather than being treated as
    evidence of either success or failure. *)

type goal_context =
  | No_task
  | Task_goals of
      { task_id : string
      ; criteria : ((string * Goal_phase.t * Goal_store.criterion) list, string) result
      }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; goal_context : goal_context
  ; keeper_id : Keeper_identity.Keeper_id.t
    (** The Keeper whose pending inputs this pass organizes: the name the
        calling lane already holds, minted through
        {!Keeper_identity.Keeper_id.of_string}, so it is case-folded. *)
  ; keeper_instructions : string
    (** The same instructions the keeper's own system prompt carries; [""]
        renders as an explicit [no keeper instructions] marker. *)
  ; working_context : Keeper_librarian_context.input
  }

val wire_field_working_contexts : string

val goal_context_to_json : goal_context -> Yojson.Safe.t

(** Variables of the pending-input organization pass: the working context,
    the Keeper's identity, instructions and goal. There is no conversation to
    judge and no current Memory: organizing pending sources neither judges
    nor carries Memory. *)
val working_context_prompt_variables : input -> (string * string) list

type parse_error =
  | Top_level_not_object
  | Working_context_invalid of string
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields

val parse_error_to_string : parse_error -> string

(** The pending-input organization answer: an object with exactly
    [working_contexts], checked against [input.working_context]. Any other
    field is refused. *)
val working_contexts_of_json_result
  :  input
  -> Yojson.Safe.t
  -> (Keeper_librarian_context.pocket list, parse_error) result
