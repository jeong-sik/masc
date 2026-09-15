# Reddit-style pages

This reference covers public subreddit listings, post pages, and the comments
visible in the current document. It is a semantic guide, not a selector map;
Reddit can change its custom elements and server-rendered markup.

Confirm the subreddit or post from the title, heading, and observed URL. In a
listing, select the main feed and its post article regions. In a post page,
select the post article first, then the named comments section or nested
comment articles. A post title link, visible author, time, body, and observed
permalink are evidence. Preserve the displayed sort or filter label when it
changes what is visible.

Keep the sidebar, community navigation, promoted content, recommendation
cards, moderation banners, and cached preview text separate from post and
comment evidence. A comment tree that is collapsed, virtualized, or marked
with a load-more control is partial. Report the visible depth and whether the
scene was truncated.

When a listing link is followed, verify that the destination heading and
article content identify the requested post before extracting it. A matching
URL alone is not enough; a login or consent page is an unverified destination.
