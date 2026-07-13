type t =
  | Persona
  | Continuity
  | Dynamic_context
  | Temporal_summary
  | Claimed_task_nudge
  | Retry_nudge
  | Memory_os_recall
  | Connected_surface
  | Other of string

let equal a b =
  match a, b with
  | Persona, Persona
  | Continuity, Continuity
  | Dynamic_context, Dynamic_context
  | Temporal_summary, Temporal_summary
  | Claimed_task_nudge, Claimed_task_nudge
  | Retry_nudge, Retry_nudge
  | Memory_os_recall, Memory_os_recall
  | Connected_surface, Connected_surface -> true
  | Other a, Other b -> String.equal a b
  | ( ( Persona | Continuity | Dynamic_context | Temporal_summary
      | Claimed_task_nudge | Retry_nudge | Memory_os_recall
      | Connected_surface | Other _ )
    , _ ) -> false

let to_string = function
  | Persona -> "persona"
  | Continuity -> "continuity"
  | Dynamic_context -> "dynamic_context"
  | Temporal_summary -> "temporal_summary"
  | Claimed_task_nudge -> "claimed_task_nudge"
  | Retry_nudge -> "retry_nudge"
  | Memory_os_recall -> "memory_os_recall"
  | Connected_surface -> "connected_surface"
  | Other name -> name

let of_string = function
  | "persona" -> Persona
  | "continuity" -> Continuity
  | "dynamic_context" -> Dynamic_context
  | "temporal_summary" -> Temporal_summary
  | "claimed_task_nudge" -> Claimed_task_nudge
  | "retry_nudge" -> Retry_nudge
  | "memory_os_recall" -> Memory_os_recall
  | "connected_surface" -> Connected_surface
  | name -> Other name

let all_known =
  [ Persona
  ; Continuity
  ; Dynamic_context
  ; Temporal_summary
  ; Claimed_task_nudge
  ; Retry_nudge
  ; Memory_os_recall
  ; Connected_surface
  ]
