async function stopNativeLoading(task, args) {
  // Loading can prevent every Page observation. Only the Space inventory and
  // native managed Page identity are used before the recovery command.
  const matches = (await task.tabs()).filter(row => row.label === args.label);
  if (matches.length !== 1)
    return {ok:false,before:true,error:'the managed Page is absent or ambiguous; inspect the same Space'};
  const tab = matches[0];
  if (typeof tab.targetId !== 'string' || tab.targetId.trim() === ''
      || (tab.openedBy !== 'agent' && tab.openedBy !== 'unknown'))
    return {ok:false,before:true,error:'the managed Page is no longer present; inspect the same Space'};
  const page = tab.page;
  if (!page || page.spaceId !== task.spaceId || page.label !== tab.label
      || page.targetId !== tab.targetId || page.openedBy !== tab.openedBy)
    return {ok:false,before:true,error:'native managed Page identity changed before recovery'};
  await page.cdp('Page.stopLoading');
  return {ok:true,value:{spaceId:task.spaceId,label:tab.label,targetId:tab.targetId,
    openedBy:tab.openedBy,method:'Page.stopLoading',returned:true}};
}