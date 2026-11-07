open Result.Syntax

module Action = Browser_lane.Action

(* Cookie writes go through the Page's CDP session
   (RFC-browser-ego-cdp-capabilities §3.3 write_storage) and change the
   operator's ego profile: the operator's own tabs and every task space on
   that profile see them, and they stay after the ego SDK process ends (L11
   evidence b1). The cookie is host-only for the tab's top document: setCookie
   takes the page's address, never a domain. Both steps read the cookies the
   page sees with getCookies before and after, so the answer is what the
   browser holds and never a value.

   A delete names each cookie by its name, domain and path as getCookies
   listed it: deleteCookies with a url and no path also deletes cookies of
   another path that the page does not see (L11 evidence a5), and one with a
   name alone is refused. A CDP call that threw may or may not have taken
   effect, unless a read afterwards shows nothing changed. *)
let script = {js|async function(page, args, reason) {
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
}|js}

let nullable f = function Some value -> f value | None -> `Null

let set_args ~label ~tab ({name; value; path; secure; http_only; same_site; max_age_sec} : Action.cookie) =
  `Assoc ["kind",`String "set";"label",`String label;"tabId",`Int tab;"name",`String name;"value",`String value;"path",`String path;
          "secure",`Bool secure;"httpOnly",`Bool http_only;
          "sameSite",nullable (fun site -> `String (Action.same_site_to_wire site)) same_site;
          "maxAgeSec",nullable (fun age -> `Int age) max_age_sec]

let delete_args ~label ~tab ~name = `Assoc ["kind",`String "delete";"label",`String label;"tabId",`Int tab;"name",`String name]

let profile_note = "the operator's own tabs and every task space on the ego profile see this change, \
  and it stays after the ego SDK process ends"

let set_note = "the cookie is in the operator's ego profile: " ^ profile_note
  ^ "; read_storage (BrowserRead mode=cookies) lists it and delete_cookie removes it"

let delete_note = "the cookies are gone from the operator's ego profile: " ^ profile_note

let unknown_set ~tab ~name = Printf.sprintf "set_cookie may have written cookie %s for tab %d's host: \
  read_storage (BrowserRead mode=cookies) lists it and delete_cookie removes it" name tab

let unknown_delete ~tab ~name = Printf.sprintf "delete_cookie may have deleted some of the cookies named %s that tab %d sees: \
  read_storage (BrowserRead mode=cookies) lists what is left" name tab

let shape what = Error ("ego answered " ^ what ^ " in another shape")
let set_cookie_shape = "a set cookie"
let deleted_shape = "a deleted cookie"
let same_site_shape = "a cookie's SameSite"
let fields_are expected fields =
  let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
  && List.sort String.compare keys = List.sort String.compare expected

(* The browser's own cookie is read back for the name and path asked, on the
   page's host, so a domain cookie or one of another path is refused. *)
let set_receipt ~tab ~(cookie : Action.cookie) = function
  | `Assoc fields ->
    let optional = List.filter (fun key -> List.mem_assoc key fields) ["sameSite";"expiry"] in
    if not (fields_are (["name";"domain";"path";"secure";"httpOnly";"session";"replaced"] @ optional) fields)
    then shape set_cookie_shape
    else
      let get key = List.assoc key fields in
      let* same_site = match List.assoc_opt "sameSite" fields with
        | None -> Ok None
        | Some (`String wire) -> (match Action.same_site_of_wire wire with
            | Some site -> Ok (Some site) | None -> shape same_site_shape)
        | Some _ -> shape same_site_shape in
      (match get "name", get "domain", get "path", get "secure", get "httpOnly", get "session",
             List.assoc_opt "expiry" fields, get "replaced" with
       | `String name, `String domain, `String path, `Bool secure, `Bool http_only, `Bool session, expiry, `Bool replaced
         when name = cookie.name && path = cookie.path && domain <> "" && domain.[0] <> '.' ->
         let* lifetime = match session, expiry with
           | true, None -> Ok []
           | false, Some (`Int expiry) when expiry >= 0 -> Ok ["expiry",`Int expiry]
           | _ -> shape "a cookie's expiry" in
         Ok (`Assoc (["action",`String "set_cookie";"tabId",`Int tab;"name",`String name;"domain",`String domain;
                      "path",`String path;"secure",`Bool secure;"httpOnly",`Bool http_only]
                     @ Option.to_list (Option.map (fun site -> "sameSite",`String (Action.same_site_to_wire site)) same_site)
                     @ ["sessionCookie",`Bool session] @ lifetime
                     @ ["replaced",`Bool replaced;"valueWithheld",`Bool true;"lifetime",`String "ego_profile";
                        "refsInvalidated",`Bool true;"note",`String set_note]))
       | _ -> shape set_cookie_shape)
  | _ -> shape set_cookie_shape

let delete_receipt ~tab ~name = function
  | `Assoc ["deleted",`List rows] ->
    let* deleted = List.fold_right (fun row collected ->
        let* collected = collected in
        match row with
        | `Assoc fields when fields_are ["domain";"path"] fields ->
          (match List.assoc "domain" fields, List.assoc "path" fields with
           | `String domain, `String path when domain <> "" && path <> "" && path.[0] = '/' ->
             Ok (`Assoc ["domain",`String domain;"path",`String path] :: collected)
           | _ -> shape deleted_shape)
        | _ -> shape deleted_shape) rows (Ok []) in
    Ok (`Assoc ["action",`String "delete_cookie";"tabId",`Int tab;"name",`String name;"deleted",`List deleted;
                "refsInvalidated",`Bool true;"note",`String delete_note])
  | _ -> shape "a cookie delete"
