// lib/browser_ego_cookie_write.ml script, unchanged.
const write = (async function(page, args, reason) {
  let href, address;
  try { href = await page.evaluate(() => location.href); address = new URL(href); }
  catch (error) { return {ok: false, before: true, error: "the tab's address was not read: " + reason(error)}; }
  if (address.protocol !== 'http:' && address.protocol !== 'https:')
    return {ok: false, before: true, error: "cookies are written for a page at an http or https address; this tab is at a " + address.protocol + " address"};
  const list = async url => {
    const listed = await page.cdp('Network.getCookies', {urls: [url]});
    if (listed === null || typeof listed !== 'object' || !Array.isArray(listed.cookies))
      throw new Error('Network.getCookies answered without a cookie list');
    return listed.cookies;
  };
  const where = cookies => cookies.map(cookie => cookie.domain + cookie.path).join(', ');
  if (args.kind === 'set') {
    const scoped = address.origin + args.path;
    const ours = cookie => cookie.name === args.name && cookie.domain === address.hostname && cookie.path === args.path;
    let replaced;
    try { replaced = (await list(scoped)).some(ours); }
    catch (error) { return {ok: false, before: true, error: "the tab's cookies were not read: " + reason(error)}; }
    const cookie = {name: args.name, value: args.value, url: href, path: args.path, secure: args.secure, httpOnly: args.httpOnly,
      ...(args.sameSite === null ? {} : {sameSite: args.sameSite}),
      ...(args.maxAgeSec === null ? {} : {expires: Date.now() / 1000 + args.maxAgeSec})};
    let set;
    try { set = await page.cdp('Network.setCookie', cookie); }
    catch (error) {
      const failed = 'Network.setCookie failed: ' + reason(error);
      if (!replaced) {
        try { if (!(await list(scoped)).some(ours)) return {ok: false, before: true, error: failed}; } catch (_) {}
      }
      return {ok: false, error: failed};
    }
    if (set === null || typeof set !== 'object' || typeof set.success !== 'boolean')
      return {ok: false, error: 'Network.setCookie answered without success'};
    if (!set.success)
      return {ok: false, before: true, error: "the browser refused the cookie (Network.setCookie answered success false), as it does for SameSite=None without Secure; nothing was written"};
    let held;
    try { held = (await list(scoped)).find(ours); }
    catch (error) { return {ok: false, error: 'the cookie was set but not read back: ' + reason(error)}; }
    if (held === undefined) return {ok: false, error: "Network.setCookie answered success but the tab's cookies do not list the cookie"};
    return {ok: true, value: {name: held.name, domain: held.domain, path: held.path, secure: held.secure, httpOnly: held.httpOnly,
      ...(held.sameSite === undefined ? {} : {sameSite: held.sameSite}),
      session: held.session, ...(held.session ? {} : {expiry: Math.floor(held.expires)}), replaced}};
  }
  const named = async () => (await list(href)).filter(cookie => cookie.name === args.name);
  let found;
  try { found = await named(); }
  catch (error) { return {ok: false, before: true, error: "the tab's cookies were not read: " + reason(error)}; }
  const deleted = [];
  for (const cookie of found) {
    try { await page.cdp('Network.deleteCookies', {name: cookie.name, domain: cookie.domain, path: cookie.path}); }
    catch (error) {
      return {ok: false, error: 'Network.deleteCookies failed: ' + reason(error)
        + (deleted.length === 0 ? '' : '; deleted before it: ' + where(deleted))};
    }
    deleted.push({domain: cookie.domain, path: cookie.path});
  }
  let left;
  try { left = await named(); }
  catch (error) { return {ok: false, error: 'the cookies were deleted but not read back: ' + reason(error)}; }
  if (left.length > 0) return {ok: false, error: 'the tab still sees ' + left.length + ' cookie(s) of that name: ' + where(left)};
  return {ok: true, value: {deleted}};
});
