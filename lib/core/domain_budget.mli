(** How many domains each executor pool of the server gets (RFC-0474 L1).

    OCaml 5 collects minor heaps with a stop-the-world barrier that every
    domain joins, so one descheduled or sleeping domain delays every
    collection. The OCaml manual recommends no more domains than cores, and
    Eio's [Executor_pool] asks for at most [Domain.recommended_domain_count],
    one fewer when the original domain does CPU work. The server's original
    domain serves HTTP and runs Keeper loops, so the limit here is
    [recommended - 1] for the whole process.

    The process has domains no pool owns ([fixed]): the main domain, the
    {!Systhread_host} domain, the Keeper snapshot codec and, when enabled, the
    serving domain. What is left goes to the two pools: Agent Core's execution
    codec runtime gets {!execution_codec_domains}, the shared masc pool gets the
    rest. *)

type plan = private
  { limit : int  (** [recommended - 1], at least 1 *)
  ; fixed : int  (** domains outside the two pools *)
  ; shared_pool : int  (** masc [Domain_pool] workers *)
  ; execution_codec : int  (** Agent Core [Execution_runtime] workers *)
  }

type error =
  | Override_exceeds_limit of
      { override : int
      ; limit : int
      ; fixed : int
      ; execution_codec : int
      }
      (** [MASC_EXECUTOR_DOMAIN_COUNT] asked for more shared pool workers than
          the default would take: the limit after the fixed domains and the
          codec runtime, or 1 on a host too small for that. *)

val execution_codec_domains : int
(** Agent Core execution codec workers when the host has room: 2. *)

val plan : recommended:int -> fixed:int -> override:int option -> (plan, error) result
(** [override] is the shared pool size the operator set; [None] takes the
    rest of the limit. Each pool keeps at least one worker, so a host with
    fewer than [fixed + 2] usable domains gets a plan whose {!total} exceeds
    [limit]; {!within_limit} tells the caller to say so. *)

val total : plan -> int
val within_limit : plan -> bool
val error_to_string : error -> string
