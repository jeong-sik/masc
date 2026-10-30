# X/Twitter-style microblog pages

This reference covers public timelines, search result pages, profiles, and
post threads that expose message articles in the current document. It does not
assume that a particular framework, custom element, or CSS class remains
stable.

Confirm the account, query, or thread from the title, heading, visible query
label, and observed URL. Prefer the main timeline region and its article
items. For each visible post retain the displayed author or account label,
time, text, media alternative text when present, and the post permalink. Keep
reply, repost, like, view, and bookmark counts tied to their visible labels;
do not turn an unlabeled icon into a count or intent.

Separate promoted posts, navigation summaries, suggested accounts, trend
panels, and stale snippets from the requested timeline. Infinite scroll and
virtualized timelines are partial observations. After scrolling, use a fresh
scene and retain the new document identity; do not reuse old article node IDs.

If the page requires login, shows a consent or rate-limit wall, or redirects
away from the requested public page, preserve that observation and report that
the requested feed was not read. Do not try to bypass the wall or substitute a
private API.
