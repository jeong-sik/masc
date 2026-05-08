(** Async guardrail validator types.

    Stub for MM-2 CDAL runtime migration. Full implementation will
    move here from agent_sdk when RFC-OAS-011 leaf migration begins.

    @since 0.102.0 *)

open Types

type input_validator =
  { name : string
  ; validate : message list -> (unit, string) result
  }

type output_validator =
  { name : string
  ; validate : api_response -> (unit, string) result
  }
