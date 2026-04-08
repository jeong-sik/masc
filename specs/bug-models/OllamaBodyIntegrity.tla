---- MODULE OllamaBodyIntegrity ----
\* Bug Model: HTTP request body integrity for Ollama.
\*
\* Models complete.ml -> http_client.ml -> Ollama.
\* Yojson.Safe.to_string produces balanced JSON.
\* Cohttp_eio transmits the body.
\* Ollama's yyjson parser validates the received body.
\*
\* Bug hypothesis: body is truncated during transmission
\* (partial write, connection reset, buffer overflow),
\* causing yyjson to see "{...incomplete" without closing "}".

EXTENDS Naturals

VARIABLES
    serialize_state,    \* "pending" | "serialized"
    body_balanced,      \* Boolean: JSON has matching braces
    body_length,        \* 0 = empty, 1 = small, 2 = large
    transmit_state,     \* "pending" | "sending" | "sent" | "truncated"
    receive_state,      \* "pending" | "received" | "parse_error"
    received_balanced   \* Boolean: what Ollama actually sees

vars == <<serialize_state, body_balanced, body_length, transmit_state, receive_state, received_balanced>>

Init ==
    /\ serialize_state = "pending"
    /\ body_balanced = FALSE
    /\ body_length = 0
    /\ transmit_state = "pending"
    /\ receive_state = "pending"
    /\ received_balanced = FALSE

\* ── Serialization (Yojson.Safe.to_string) ──────────────

\* Yojson always produces balanced JSON
Serialize ==
    /\ serialize_state = "pending"
    /\ serialize_state' = "serialized"
    /\ body_balanced' = TRUE          \* Yojson guarantee
    /\ body_length' \in {1, 2}        \* Small or large body
    /\ UNCHANGED <<transmit_state, receive_state, received_balanced>>

\* ── Transmission (Cohttp_eio) ──────────────────────────

\* Normal: body sent completely
TransmitComplete ==
    /\ serialize_state = "serialized"
    /\ transmit_state = "pending"
    /\ transmit_state' = "sent"
    /\ received_balanced' = body_balanced  \* Faithful transmission
    /\ UNCHANGED <<serialize_state, body_balanced, body_length, receive_state>>

\* ── Reception (Ollama yyjson) ──────────────────────────

ReceiveAndParse ==
    /\ transmit_state = "sent"
    /\ receive_state = "pending"
    /\ receive_state' = IF received_balanced THEN "received" ELSE "parse_error"
    /\ UNCHANGED <<serialize_state, body_balanced, body_length, transmit_state, received_balanced>>

\* ── Clean Next ─────────────────────────────────────────

Next ==
    \/ Serialize
    \/ TransmitComplete
    \/ ReceiveAndParse

Spec == Init /\ [][Next]_vars

\* ── Safety ─────────────────────────────────────────────

\* If body was balanced at serialization, Ollama must not get parse_error.
BalancedNeverFails ==
    (body_balanced /\ receive_state = "parse_error") => FALSE

\* Equivalently: parse_error implies body was not balanced on receipt.
ParseErrorImpliesUnbalanced ==
    receive_state = "parse_error" => ~received_balanced

\* ── Bug Model: transmission truncation ─────────────────

\* Bug: large body gets truncated during transmission.
\* The body starts with '{' but the closing '}' is cut off.
BuggyTransmitTruncate ==
    /\ serialize_state = "serialized"
    /\ transmit_state = "pending"
    /\ body_length = 2                \* Only large bodies truncate
    /\ transmit_state' = "sent"
    /\ received_balanced' = FALSE     \* Bug: truncated, missing '}'
    /\ UNCHANGED <<serialize_state, body_balanced, body_length, receive_state>>

NextBuggy ==
    \/ Serialize
    \/ BuggyTransmitTruncate
    \/ TransmitComplete
    \/ ReceiveAndParse

SpecBuggy == Init /\ [][NextBuggy]_vars

====
