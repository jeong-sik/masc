(** Observation scoped to one serialized Curator owner drain iteration.
    No counters are read by scheduling, admission or retry policy. *)
type domain = Classification | Briefing | Outside_domain
type phase = Discovery | Observer | Successor | Primary
val with_pass : base_path:string -> (unit -> 'a) -> 'a
(** Bind fresh counters to this fiber and its synchronous descendants. Emit
    one histogram sample, including zero, for each domain/phase at return,
    exception or cancellation. Pass IDs appear in the summary log only. *)
val with_domain : domain -> (unit -> 'a) -> 'a
val with_phase : phase -> (unit -> 'a) -> 'a
val restore : run:((unit -> ('a, 'e) result) -> ('a, 'e) result) ->
  (unit -> ('a, 'e) result) -> ('a, 'e) result
(** Count one actual complete Capture.restore invocation, when its callback
    actually enters the supplied executor. The pass binding is captured before
    crossing the system-thread boundary; a cancelled submission that never
    enters the callback counts nothing. Result errors, exceptions and cancellations count
    as failed calls. Outside a pass this just invokes the supplied function.
    Ancestry decoding within that call is not an additional invocation. *)
