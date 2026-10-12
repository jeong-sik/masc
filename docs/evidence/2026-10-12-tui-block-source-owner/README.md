# Block and rail execution ownership

Base: `b5a753b14438835872a0fe088cc29685a228d1f6` (#42517).

The timeline context already retained typed ownership, but the renderer converted blocks and member rows back to raw request IDs before linking them and deciding open/closed execution runs. An autonomous or unobserved row sharing a direct block's textual ID could acquire that block's membership.

Share `chat_execution_member_keys` between context and renderer. Block membership, block set, open execution set and run ownership retain `chat_turn_key`. The final diagnostic label alone converts a typed source to text. Removed the now unread lb_request_id field. Preserve existing edge algorithm and broadcast siding semantics; no new row-order or screen test.

Executed the actual renderer block/member/request_of decision excerpt unchanged in a minimal typed OCaml harness: parent exit1 (autonomous row acquired direct block); current exit0 for cross-kind refusal, unobserved-row refusal, retained direct batch follower and exact autonomous membership. Logs/harness: `/tmp/masc-tui-block-source-owner-20261012/`. Interpreter warning26 concerns open_request_ids because the excerpt ends before the edge-run consumer; production consumes it. This is ownership-decision execution, not rendered rails or screenshot verification.

Syntax-only parsing passed for three changed OCaml files; diff whitespace passed. Registered state member-authority fixture is unexecuted. No full typecheck/build/CI/runtime/screenshots/formal approval/merge.

Remaining: block projection cache key is still a textual request ID but its physical sbm_log guard prevents cross-log reuse; collision-related cache thrashing is unmeasured. Search/anchor/other identity consumers, broadcast interleaving and complete provider/async/queue runtime/visible proof remain separate. Full goal is active.
