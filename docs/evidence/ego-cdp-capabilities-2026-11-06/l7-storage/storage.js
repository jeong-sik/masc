async function(page, args, reason) {
  let seen;
  try {
    seen = await page.evaluate(async limits => {
      const cut = text => String(text).slice(0, limits.nameChars);
      const failure = error => ({error: cut(error && error.name || error)});
      const area = name => {
        try {
          const store = window[name];
          const count = store.length;
          const keys = [];
          for (let index = 0; index < Math.min(count, limits.names); index++) keys.push(cut(store.key(index)));
          return {count, keys, truncated: count > limits.names};
        } catch (error) { return failure(error); }
      };
      const databases = async () => {
        try {
          if (typeof indexedDB === "undefined" || typeof indexedDB.databases !== "function") return {unsupported: true};
          let timer;
          const listed = await Promise.race([indexedDB.databases(),
            new Promise(resolve => { timer = setTimeout(() => resolve(null), limits.indexedDbWaitMs); })]);
          clearTimeout(timer);
          if (listed === null) return {error: "timeout"};
          return {count: listed.length, names: listed.slice(0, limits.names).map(database => cut(database.name)),
            truncated: listed.length > limits.names};
        } catch (error) { return failure(error); }
      };
      return {url: location.href, origin: location.origin, localStorage: area("localStorage"),
        sessionStorage: area("sessionStorage"), indexedDb: await databases()};
    }, args.limits);
  } catch (error) {
    return {ok: false, error: "the page's storage names were not read: " + reason(error)};
  }
  if (seen === null || typeof seen !== "object" || typeof seen.url !== "string")
    return {ok: false, error: "the page answered its storage names without its URL"};
  let listed;
  try {
    listed = await page.cdp("Network.getCookies", {urls: [seen.url]});
  } catch (error) {
    return {ok: false, error: "Network.getCookies failed: " + reason(error)};
  }
  if (listed === null || typeof listed !== "object" || !Array.isArray(listed.cookies))
    return {ok: false, error: "Network.getCookies answered without a cookie list"};
  const cookies = listed.cookies.map(cookie => ({
    name: cookie.name, domain: cookie.domain, path: cookie.path, secure: cookie.secure, httpOnly: cookie.httpOnly,
    ...(cookie.sameSite === undefined ? {} : {sameSite: cookie.sameSite}),
    ...(cookie.session === false ? {expiry: Math.floor(cookie.expires)} : {})}));
  return {ok: true, value: {cookies: cookies.slice(0, args.limits.cookies), total: cookies.length,
    storage: {origin: seen.origin, localStorage: seen.localStorage, sessionStorage: seen.sessionStorage,
      indexedDb: seen.indexedDb}}};
}
