val supported_payload_kinds : string list

val consumer : Schedule_runner.consumer
(** Production scheduled-automation consumer adapter.

    The schedule core remains opaque; this adapter is the MASC server layer that
    interprets explicitly supported payload envelopes. *)
