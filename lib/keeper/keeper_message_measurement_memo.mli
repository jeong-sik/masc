(** Keeper_message_measurement_memo — the sizes a Keeper's requests measure
    with an encoder that reads the message alone, kept from one walk of the
    Keeper's history to the next (RFC
    finished-turn-result-plans-are-computed-once).

    Every provider request of a Keeper measures its durable history: the
    window counts the messages it carries, and
    {!Keeper_model_input_demotion.plan} measures every finished message with a
    tool result of 2,048 bytes or more, before and after its marker. A run
    decodes that history again from its checkpoint, and a memo kept for one
    provider attempt was thrown away with the attempt, so every attempt
    encoded the same finished messages again. A message that has ended does
    not change, and an encoder that reads only the message gives it one size.

    A table here belongs to one Keeper and one {!encoder}, for the life of the
    process. A walk is one pass of the Keeper's history: a provider attempt,
    or an official-client turn. Each walk measures with a measurer of its own,
    so a measurer's buffer is never shared between walks. *)

type encoder
(** One encoding whose length depends on the message alone, with the most
    bytes a table of it keeps for one Keeper. Every value {!encoder} returns
    has its own tables, so two encodings never answer for each other. The
    module that owns an encoding makes its encoder once. *)

val per_keeper_retained_bytes : int
(** 64 MiB, the bound of the production encoders. The largest Keeper history
    on 2026-11-27 held 28.6 MB of messages with a tool result of 2,048 bytes
    or more (RFC finished-turn-result-plans-are-computed-once §1.4). *)

val encoder :
  max_retained_bytes:int -> (unit -> Agent_core.Types.message -> int) -> encoder
(** [encoder ~max_retained_bytes make] names the encoding [make ()] measures.
    [make] is called once per walk; the measurer it returns may keep state,
    such as a buffer, for that walk alone.

    A table counts each entry by the bytes it measured, which is never less
    than the text its key holds: an encoder escapes, it does not compress.
    When a new entry would pass [max_retained_bytes], the table first drops
    the entries that neither this walk nor the walk before asked for. If it is
    still full, the message is measured and not kept. A walk visits the
    history in the same order every time, so evicting the least recently used
    entry instead would miss every lookup once the history outgrew the
    table. *)

val measurer : keeper_name:string -> encoder -> Agent_core.Types.message -> int
(** [measurer ~keeper_name encoder] opens a walk of [keeper_name]'s history:
    the function it returns answers from the Keeper's table for [encoder]
    when the table holds a message equal to the one asked
    ({!Agent_core.Types.Message_value}), and measures with this walk's own
    measurer otherwise. Call it once per walk and use the result from one
    fiber at a time.

    A hit takes the asked message as the table's key, so the copy an earlier
    run decoded is no longer held, and the rest of the run compares the
    message with itself. The table is locked around each lookup and update;
    the measurement runs outside the lock.

    The answer is the bytes the encoder measured for an equal message. Equal
    raw JSON payloads that differ only in [0.0] and [-0.0] share an entry
    while encoding one byte apart, the tolerance the attempt memo already
    accepted (keeper_turn_driver_try_provider.ml). *)
