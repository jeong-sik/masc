# Credential-owned Keeper composer drafts

Base: `2da51677a2668a8bf00ca7dc509d54e1df896407` (#42415).

## Direct findings

An actual mounted uncontrolled ChatComposer retained its old authored text after token replacement. The DOM fixture failed at the textarea still containing the prior owner's draft. After adding credential-keyed session mounting, a second fixture directly dispatched Enter before the auth rerender committed and reproduced submission of the old text. Both failures were observed before their corresponding repair.

The old local input queue in keeper-chat-store had no product callers: all exported queue symbols were searched across dashboard excluding their definitions/tests; only draft read/write remain in the real composer. TypeScript also passed after removing the unused queue exports. The backend operation queue and its editor remain the active authority and are not changed here. Deleted local-queue tests are not evidence of improved feature coverage.

## Repair

Persisted drafts are indexed by the existing credential epoch and Keeper. Session callbacks explicitly use the captured epoch, so an old write or clear cannot affect a new draft. Old authored text stays in its owned partition; the current credential cannot implicitly read it. The existing reactive token revision keys the internal composer session, separating its buffers. Send and slash execution verify that captured ownership is still current before invoking effects, including the rerender gap.

247 focused tests passed: draft store, chat primitives, keeper-shared and Copilot. TypeScript noEmit and diff-check passed. Tests retain per-Keeper persistence/send behavior and cover new-owner remount, old cleanup/new draft separation and rejection of old immediate Enter.

## Limits

This is in-process store and DOM evidence, not installed UI screenshots or named-provider runtime. Controlled draft props remain owned by their hosts and are not certified isolated. Global cached transcripts, nonpersisted unsent input recovery, old-epoch recovery UI, and full async attachment/voice diagnostic isolation remain separate work. No formal approval, CI, merge or deployment evidence is claimed. The full chat goal remains active.
