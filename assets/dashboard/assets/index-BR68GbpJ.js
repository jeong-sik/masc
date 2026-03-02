(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Ee,L,Ns,Rs,ut,Zn,Ls,Ds,Ps,In,ln,cn,Jt={},Es=[],Ya=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Ie=Array.isArray;function nt(t,e){for(var n in e)t[n]=e[n];return t}function jn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Is(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Ee.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return fe(t,r,s,a,null)}function fe(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Ns,__i:-1,__u:0};return a==null&&L.vnode!=null&&L.vnode(i),i}function ee(t){return t.children}function Pt(t,e){this.props=t,this.context=e}function xt(t,e){if(e==null)return t.__?xt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?xt(t):null}function js(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return js(t)}}function ts(t){(!t.__d&&(t.__d=!0)&&ut.push(t)&&!he.__r++||Zn!=L.debounceRendering)&&((Zn=L.debounceRendering)||Ls)(he)}function he(){for(var t,e,n,s,a,i,r,c=1;ut.length;)ut.length>c&&ut.sort(Ds),t=ut.shift(),c=ut.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=nt({},s)).__v=s.__v+1,L.vnode&&L.vnode(n),On(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??xt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,zs(i,n,r),s.__e=s.__=null,n.__e!=a&&js(n)));he.__r=0}function Os(t,e,n,s,a,i,r,c,d,u,p){var l,v,m,$,b,k,S,T=s&&s.__k||Es,z=e.length;for(d=Qa(n,e,T,d,z),l=0;l<z;l++)(m=n.__k[l])!=null&&(v=m.__i==-1?Jt:T[m.__i]||Jt,m.__i=l,k=On(t,m,v,a,i,r,c,d,u,p),$=m.__e,m.ref&&v.ref!=m.ref&&(v.ref&&Mn(v.ref,null,m),p.push(m.ref,m.__c||$,m)),b==null&&$!=null&&(b=$),(S=!!(4&m.__u))||v.__k===m.__k?d=Ms(m,d,t,S):typeof m.type=="function"&&k!==void 0?d=k:$&&(d=$.nextSibling),m.__u&=-7);return n.__e=b,d}function Qa(t,e,n,s,a){var i,r,c,d,u,p=n.length,l=p,v=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=fe(null,r,null,null,null):Ie(r)?r=t.__k[i]=fe(ee,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=fe(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+v,r.__=t,r.__b=t.__b+1,c=null,(u=r.__i=Xa(r,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(a>p?v--:a<p&&v++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?v--:u==d+1?v++:(u>d?v--:v++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==s&&(s=xt(c)),Us(c,c));return s}function Ms(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=Ms(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=xt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Xa(t,e,n,s){var a,i,r,c=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&c==null||p&&c==u.key&&d==u.type)return n;if(s>(p?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return r}return-1}function es(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Ya.test(e)?n:n+"px"}function oe(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||es(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||es(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ps,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=In,t.addEventListener(e,i?cn:ln,i)):t.removeEventListener(e,i?cn:ln,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ns(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=In++;else if(e.t<n.u)return;return n(L.event?L.event(e):e)}}}function On(t,e,n,s,a,i,r,c,d,u){var p,l,v,m,$,b,k,S,T,z,K,D,q,lt,ct,G,et,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[c=e.__e=n.__e]),(p=L.__b)&&p(e);t:if(typeof R=="function")try{if(S=e.props,T="prototype"in R&&R.prototype.render,z=(p=R.contextType)&&s[p.__c],K=p?z?z.props.value:p.__:s,n.__c?k=(l=e.__c=n.__c).__=l.__E:(T?e.__c=l=new R(S,K):(e.__c=l=new Pt(S,K),l.constructor=R,l.render=ti),z&&z.sub(l),l.state||(l.state={}),l.__n=s,v=l.__d=!0,l.__h=[],l._sb=[]),T&&l.__s==null&&(l.__s=l.state),T&&R.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=nt({},l.__s)),nt(l.__s,R.getDerivedStateFromProps(S,l.__s))),m=l.props,$=l.state,l.__v=e,v)T&&R.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),T&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(T&&R.getDerivedStateFromProps==null&&S!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(S,K),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(S,l.__s,K)===!1){for(e.__v!=n.__v&&(l.props=S,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(I){I&&(I.__=e)}),D=0;D<l._sb.length;D++)l.__h.push(l._sb[D]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(S,l.__s,K),T&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,$,b)})}if(l.context=K,l.props=S,l.__P=t,l.__e=!1,q=L.__r,lt=0,T){for(l.state=l.__s,l.__d=!1,q&&q(e),p=l.render(l.props,l.state,l.context),ct=0;ct<l._sb.length;ct++)l.__h.push(l._sb[ct]);l._sb=[]}else do l.__d=!1,q&&q(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++lt<25);l.state=l.__s,l.getChildContext!=null&&(s=nt(nt({},s),l.getChildContext())),T&&!v&&l.getSnapshotBeforeUpdate!=null&&(b=l.getSnapshotBeforeUpdate(m,$)),G=p,p!=null&&p.type===ee&&p.key==null&&(G=Fs(p.props.children)),c=Os(t,Ie(G)?G:[G],e,n,s,a,i,r,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),k&&(l.__E=l.__=null)}catch(I){if(e.__v=null,d||i!=null)if(I.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(et=i.length;et--;)jn(i[et]);un(e)}else e.__e=n.__e,e.__k=n.__k,I.then||un(e);L.__e(I,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=Za(n.__e,e,n,s,a,i,r,d,u);return(p=L.diffed)&&p(e),128&e.__u?void 0:c}function un(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(un)}function zs(t,e,n){for(var s=0;s<n.length;s++)Mn(n[s],n[++s],n[++s]);L.__c&&L.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){L.__e(i,a.__v)}})}function Fs(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Ie(t)?t.map(Fs):nt({},t)}function Za(t,e,n,s,a,i,r,c,d){var u,p,l,v,m,$,b,k=n.props||Jt,S=e.props,T=e.type;if(T=="svg"?a="http://www.w3.org/2000/svg":T=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((m=i[u])&&"setAttribute"in m==!!T&&(T?m.localName==T:m.nodeType==3)){t=m,i[u]=null;break}}if(t==null){if(T==null)return document.createTextNode(S);t=document.createElementNS(a,T,S.is&&S),c&&(L.__m&&L.__m(e,i),c=!1),i=null}if(T==null)k===S||c&&t.data==S||(t.data=S);else{if(i=i&&Ee.call(t.childNodes),!c&&i!=null)for(k={},u=0;u<t.attributes.length;u++)k[(m=t.attributes[u]).name]=m.value;for(u in k)if(m=k[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=m;else if(!(u in S)){if(u=="value"&&"defaultValue"in S||u=="checked"&&"defaultChecked"in S)continue;oe(t,u,null,m,a)}}for(u in S)m=S[u],u=="children"?v=m:u=="dangerouslySetInnerHTML"?p=m:u=="value"?$=m:u=="checked"?b=m:c&&typeof m!="function"||k[u]===m||oe(t,u,m,k[u],a);if(p)c||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),Os(e.type=="template"?t.content:t,Ie(v)?v:[v],e,n,s,T=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&xt(n,0),c,d),i!=null)for(u=i.length;u--;)jn(i[u]);c||(u="value",T=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[u]||T=="progress"&&!$||T=="option"&&$!=k[u])&&oe(t,u,$,k[u],a),u="checked",b!=null&&b!=t[u]&&oe(t,u,b,k[u],a))}return t}function Mn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){L.__e(a,n)}}function Us(t,e,n){var s,a;if(L.unmount&&L.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Mn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){L.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&Us(s[a],e,n||typeof t.type!="function");n||jn(t.__e),t.__c=t.__=t.__e=void 0}function ti(t,e,n){return this.constructor(t,n)}function ei(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),L.__&&L.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],On(e,t=e.__k=Is(ee,null,[t]),a||Jt,Jt,e.namespaceURI,a?null:e.firstChild?Ee.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),zs(i,t,r)}Ee=Es.slice,L={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(c){t=c}throw t}},Ns=0,Rs=function(t){return t!=null&&t.constructor===void 0},Pt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=nt({},this.state),typeof t=="function"&&(t=t(nt({},n),this.props)),t&&nt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ts(this))},Pt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ts(this))},Pt.prototype.render=ee,ut=[],Ls=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ds=function(t,e){return t.__v.__b-e.__v.__b},he.__r=0,Ps=/(PointerCapture)$|Capture$/i,In=0,ln=ns(!1),cn=ns(!0);var Hs=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=c:r===4?s[1]=Object.assign(s[1]||{},c):r===5?(s[1]=s[1]||{})[e[++i]]=c:r===6?s[1][e[++i]]+=c+"":r?(a=t.apply(c,Hs(t,c,n,["",null])),s.push(a),c[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(c)}return s},ss=new Map;function ni(t){var e=ss.get(this);return e||(e=new Map,ss.set(this,e)),(e=Hs(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",c="",d=[0],u=function(v){i===1&&(v||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,v,r):i===3&&(v||r)?(d.push(3,v,r),i=2):i===2&&r==="..."&&v?d.push(4,v,0):i===2&&r&&!v?d.push(5,0,!0,r):i>=5&&((r||!v&&i===5)&&(d.push(i,0,r,a),i=6),v&&(d.push(i,v,0,a),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&u(),u(p));for(var l=0;l<n[p].length;l++)s=n[p][l],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:c?s===c?c="":r+=s:s==='"'||s==="'"?c=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[p][l+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=ni.bind(Is),Yt,P,He,as,dn=0,Bs=[],E=L,is=E.__b,os=E.__r,rs=E.diffed,ls=E.__c,cs=E.unmount,us=E.__;function zn(t,e){E.__h&&E.__h(P,t,dn||e),dn=0;var n=P.__H||(P.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function re(t){return dn=1,si(Gs,t)}function si(t,e,n){var s=zn(Yt++,2);if(s.t=t,!s.__c&&(s.__=[Gs(void 0,e),function(c){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,c);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=P,!P.__f)){var a=function(c,d,u){if(!s.__c.__H)return!0;var p=s.__c.__H.__.filter(function(v){return!!v.__c});if(p.every(function(v){return!v.__N}))return!i||i.call(this,c,d,u);var l=s.__c.props!==c;return p.forEach(function(v){if(v.__N){var m=v.__[0];v.__=v.__N,v.__N=void 0,m!==v.__[0]&&(l=!0)}}),i&&i.call(this,c,d,u)||l};P.__f=!0;var i=P.shouldComponentUpdate,r=P.componentWillUpdate;P.componentWillUpdate=function(c,d,u){if(this.__e){var p=i;i=void 0,a(c,d,u),i=p}r&&r.call(this,c,d,u)},P.shouldComponentUpdate=a}return s.__N||s.__}function vt(t,e){var n=zn(Yt++,3);!E.__s&&qs(n.__H,e)&&(n.__=t,n.u=e,P.__H.__h.push(n))}function Ks(t,e){var n=zn(Yt++,7);return qs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function ai(){for(var t;t=Bs.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(me),t.__H.__h.forEach(pn),t.__H.__h=[]}catch(e){t.__H.__h=[],E.__e(e,t.__v)}}E.__b=function(t){P=null,is&&is(t)},E.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),us&&us(t,e)},E.__r=function(t){os&&os(t),Yt=0;var e=(P=t.__c).__H;e&&(He===P?(e.__h=[],P.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(me),e.__h.forEach(pn),e.__h=[],Yt=0)),He=P},E.diffed=function(t){rs&&rs(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Bs.push(e)!==1&&as===E.requestAnimationFrame||((as=E.requestAnimationFrame)||ii)(ai)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),He=P=null},E.__c=function(t,e){e.some(function(n){try{n.__h.forEach(me),n.__h=n.__h.filter(function(s){return!s.__||pn(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],E.__e(s,n.__v)}}),ls&&ls(t,e)},E.unmount=function(t){cs&&cs(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{me(s)}catch(a){e=a}}),n.__H=void 0,e&&E.__e(e,n.__v))};var ds=typeof requestAnimationFrame=="function";function ii(t){var e,n=function(){clearTimeout(s),ds&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);ds&&(e=requestAnimationFrame(n))}function me(t){var e=P,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),P=e}function pn(t){var e=P;t.__c=t.__(),P=e}function qs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Gs(t,e){return typeof e=="function"?e(t):e}var oi=Symbol.for("preact-signals");function je(){if(st>1)st--;else{for(var t,e=!1;Et!==void 0;){var n=Et;for(Et=void 0,vn++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Js(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(vn=0,st--,e)throw t}}function ri(t){if(st>0)return t();st++;try{return t()}finally{je()}}var N=void 0;function Ws(t){var e=N;N=void 0;try{return t()}finally{N=e}}var Et=void 0,st=0,vn=0,ye=0;function Vs(t){if(N!==void 0){var e=t.n;if(e===void 0||e.t!==N)return e={i:0,S:t,p:N.s,n:void 0,t:N,e:void 0,x:void 0,r:e},N.s!==void 0&&(N.s.n=e),N.s=e,t.n=e,32&N.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=N.s,e.n=void 0,N.s.n=e,N.s=e),e}}function j(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype.brand=oi;j.prototype.h=function(){return!0};j.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ws(function(){var s;(s=e.W)==null||s.call(e)}))};j.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ws(function(){var a;(a=e.Z)==null||a.call(e)}))}};j.prototype.subscribe=function(t){var e=this;return ne(function(){var n=e.value,s=N;N=void 0;try{t(n)}finally{N=s}},{name:"sub"})};j.prototype.valueOf=function(){return this.value};j.prototype.toString=function(){return this.value+""};j.prototype.toJSON=function(){return this.value};j.prototype.peek=function(){var t=N;N=void 0;try{return this.value}finally{N=t}};Object.defineProperty(j.prototype,"value",{get:function(){var t=Vs(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(vn>100)throw new Error("Cycle detected");this.v=t,this.i++,ye++,st++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{je()}}}});function _(t,e){return new j(t,e)}function Js(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ys(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Qs(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ft(t,e){j.call(this,void 0),this.x=t,this.s=void 0,this.g=ye-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ft.prototype=new j;ft.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ye))return!0;if(this.g=ye,this.f|=1,this.i>0&&!Js(this))return this.f&=-2,!0;var t=N;try{Ys(this),N=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return N=t,Qs(this),this.f&=-2,!0};ft.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}j.prototype.S.call(this,t)};ft.prototype.U=function(t){if(this.t!==void 0&&(j.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ft.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ft.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Vs(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ot(t,e){return new ft(t,e)}function Xs(t){var e=t.u;if(t.u=void 0,typeof e=="function"){st++;var n=N;N=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Fn(t),s}finally{N=n,je()}}}function Fn(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Xs(t)}function li(t){if(N!==this)throw new Error("Out-of-order effect");Qs(this),N=t,this.f&=-2,8&this.f&&Fn(this),je()}function St(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}St.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};St.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Xs(this),Ys(this),st++;var t=N;return N=this,li.bind(this,t)};St.prototype.N=function(){2&this.f||(this.f|=2,this.o=Et,Et=this)};St.prototype.d=function(){this.f|=8,1&this.f||Fn(this)};St.prototype.dispose=function(){this.d()};function ne(t,e){var n=new St(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Zs,le,ci=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,ta=[];ne(function(){Zs=this.N})();function Ct(t,e){L[t]=e.bind(null,L[t]||function(){})}function be(t){if(le){var e=le;le=void 0,e()}le=t&&t.S()}function ea(t){var e=this,n=t.data,s=di(n);s.value=n;var a=Ks(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=ot(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),p=ot(function(){return!Array.isArray(u.value)&&!Rs(u.value)}),l=ne(function(){if(this.N=na,p.value){var m=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=m)}}),v=e.__$u.d;return e.__$u.d=function(){l(),v.call(this)},[p,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}ea.displayName="ReactiveTextNode";Object.defineProperties(j.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:ea},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ct("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof j&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});Ct("__r",function(t,e){if(t(e),e.type!==ee){be();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return ne(function(){r=this},{name:i}),r.c=a,r})(function(){var a;ci&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),be(n)}});Ct("__e",function(t,e,n,s){be(),t(e,n,s)});Ct("diffed",function(t,e){be();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in s)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],p=s[d];u===void 0?(u=ui(n,d,p),i[d]=u):u.o(p,a)}for(var l in s)a[l]=s[l]}}t(e)});function ui(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(c,d){i.value=c,r=c.peek()},d:ne(function(){this.N=na;var c=i.value.value;r!==c?(r=void 0,a?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}Ct("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});Ct("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});Pt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function di(t,e){return Ks(function(){return _(t,e)},[])}var pi=function(t){queueMicrotask(function(){queueMicrotask(t)})};function vi(){ri(function(){for(var t;t=ta.shift();)Zs.call(t)})}function na(){ta.push(this)===1&&(L.requestAnimationFrame||pi)(vi)}const fi=["overview","execution","board","activity","agents","tasks","goals","journal","trpg","council"],sa={tab:"overview",params:{},postId:null};function ps(t){return!!t&&fi.includes(t)}function fn(t){try{return decodeURIComponent(t)}catch{return t}}function mn(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function mi(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function aa(t,e){const n=t[0],s=e.tab,a=ps(n)?n:ps(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=fn(t[2]):t[0]==="post"&&t[1]&&(i=fn(t[1]))),{tab:a,params:e,postId:i}}function xe(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return sa;const n=fn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=mn(a),r=mi(s);return aa(r,i)}function _i(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...sa,params:mn(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=mn(e.replace(/^\?/,""));return aa(s,a)}function ia(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=_(xe(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=xe(window.location.hash)});function Oe(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ia(n)}function gi(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function $i(){if(window.location.hash&&window.location.hash!=="#"){Z.value=xe(window.location.hash);return}const t=_i(window.location.pathname,window.location.search);if(t){Z.value=t;const e=ia(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=xe(window.location.hash)}const hi=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Decisions",icon:"🏛️"},{id:"board",label:"Discussions",icon:"💬"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"activity",label:"Activity",icon:"📊"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function yi(){const t=Z.value.tab;return o`
    <div class="main-tab-bar">
      ${hi.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Oe(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const vs="masc_dashboard_sse_session_id",bi=1e3,xi=15e3,kt=_(!1),Un=_(0),oa=_(null),ke=_([]);function ki(){let t=sessionStorage.getItem(vs);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(vs,t)),t}const wi=200;function W(t,e){const n={agent:t,text:e,timestamp:Date.now()};ke.value=[n,...ke.value].slice(0,wi)}let X=null,yt=null,_n=0;function ra(){yt&&(clearTimeout(yt),yt=null)}function Si(){if(yt)return;_n++;const t=Math.min(_n,5),e=Math.min(xi,bi*Math.pow(2,t));yt=setTimeout(()=>{yt=null,la()},e)}function la(){ra(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",ki());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);X=i,i.onopen=()=>{X===i&&(_n=0,kt.value=!0)},i.onerror=()=>{X===i&&(kt.value=!1,i.close(),X=null,Si())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Un.value++,oa.value=c,Ci(c)}catch{}}}function Ci(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":W(n,"Joined");break;case"agent_left":W(n,"Left");break;case"broadcast":W(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":W(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":W(n,"New post");break;case"board_comment":W(n,"New comment");break;case"keeper_heartbeat":W(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":W(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":W(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":W(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:W(n,e)}}function Ai(){ra(),X&&(X.close(),X=null),kt.value=!1}function ca(){return new URLSearchParams(window.location.search)}function ua(){const t=ca(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function da(){return{...ua(),"Content-Type":"application/json"}}const Ti=15e3,pa=3e4,Ni=6e4;async function Hn(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function Ri(){var e,n;const t=ca();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function rt(t){const e=await Hn(t,{headers:ua()},Ti);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function se(t,e){const n=await Hn(t,{method:"POST",headers:da(),body:JSON.stringify(e)},pa);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function Li(t,e,n,s=pa){const a=await Hn(t,{method:"POST",headers:{...da(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function Di(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Pi(t){var e,n,s,a,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function U(t,e){const n=await Li("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ni),s=Di(n);return Pi(s)}function Ei(t="compact"){return rt(`/api/v1/dashboard?mode=${t}`)}function wt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ii(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function va(t){if(!C(t))return null;const e=f(t.id,"").trim(),n=f(t.author,"").trim(),s=f(t.content,"").trim();if(!e||!n)return null;const a=A(t.score,0),i=A(t.votes_up,0),r=A(t.votes_down,0),c=A(t.votes,a||i-r),d=A(t.comment_count,A(t.reply_count,0)),u=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(C($)){const k=f($.name,"").trim();if(k)return k}return f(t.flair_name,"").trim()||void 0})(),p=f(t.created_at_iso,"").trim()||wt(t.created_at),l=f(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?wt(t.updated_at):p),m=f(t.title,"").trim()||Ii(s);return{id:e,author:n,title:m,content:s,tags:[],votes:c,vote_balance:a,comment_count:d,created_at:p,updated_at:l,flair:u,hearth_count:A(t.hearth_count,0)}}function ji(t){if(!C(t))return null;const e=f(t.id,"").trim(),n=f(t.post_id,"").trim(),s=f(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:f(t.content,""),created_at:wt(t.created_at)}}async function Oi(t){const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),s=await rt(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(s.posts)?s.posts.map(va).filter(i=>i!==null):[]}}async function Mi(t){const e=await rt(`/api/v1/board/${t}?format=flat`),n=C(e.post)?e.post:e,s=va(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(ji).filter(r=>r!==null);return{...s,comments:i}}function fa(t,e){return se("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Ri()})}function zi(t,e,n){return se("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fi(t){const e=f(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function O(...t){for(const e of t){const n=f(e,"");if(n.trim())return n.trim()}return""}function fs(t){const e=Fi(O(t.outcome,t.result,t.result_code));if(!e)return;const n=O(t.reason,t.reason_code,t.description,t.detail),s=O(t.summary,t.summary_ko,t.summary_en,t.note),a=O(t.details,t.details_text,t.text,t.note),i=O(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=O(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=O(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(v=>{if(typeof v=="string")return v.trim();if(C(v)){const m=f(v.summary,"").trim();if(m)return m;const $=f(v.text,"").trim();if($)return $;const b=f(v.type,"").trim();return b||f(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),u=(()=>{const l=A(t.turn,Number.NaN);if(Number.isFinite(l))return l;const v=A(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const m=A(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const $=A(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),p=O(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:u,phase:p||void 0}}function Ui(t,e){const n=C(t.state)?t.state:{};if(f(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>C(r)?f(r.type,"")==="session.outcome":!1),i=C(n.session_outcome)?n.session_outcome:{};if(C(i)&&Object.keys(i).length>0){const r=fs(i);if(r)return r}if(C(a))return fs(C(a.payload)?a.payload:{})}function C(t){return typeof t=="object"&&t!==null}function f(t,e=""){return typeof t=="string"?t:e}function A(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Hi(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function gn(t,e=!1){return typeof t=="boolean"?t:e}function Rt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(C(e)){const n=f(e.name,"").trim(),s=f(e.id,"").trim(),a=f(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Bi(t){const e={};if(!C(t)&&!Array.isArray(t))return e;if(C(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=f(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!C(n))continue;const s=O(n.to,n.target,n.actor_id,n.name,n.id),a=O(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Ki(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function H(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function qi(t,e){if(t!=="dice.rolled")return;const n=A(e.raw_d20,0),s=A(e.total,0),a=A(e.bonus,0),i=f(e.action,"roll"),r=A(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Gi(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Wi(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Vi(t,e,n,s){const a=n||e||f(s.actor_id,"")||f(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=f(s.proposed_action,f(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=f(s.reply,f(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return f(s.reply,f(s.content,f(s.text,"Narration")));case"dice.rolled":{const i=f(s.action,"roll"),r=A(s.total,0),c=A(s.dc,0),d=f(s.label,""),u=a||"actor",p=c>0?` vs DC ${c}`:"",l=d?` (${d})`:"";return`${u} ${i}: ${r}${p}${l}`}case"turn.started":return`Turn ${A(s.turn,1)} started`;case"phase.changed":return`Phase: ${f(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${f(s.name,a||"unknown")}`;case"actor.claimed":return`${f(s.keeper_name,f(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${f(s.keeper_name,f(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${A(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${A(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||f(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||f(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${f(s.reason_code,"unknown")}`;case"memory.signal":{const i=C(s.entity_refs)?s.entity_refs:{},r=f(i.requested_tier,""),c=f(i.effective_tier,""),d=gn(i.guardrail_applied,!1),u=f(s.summary_en,f(s.summary_ko,"Memory signal"));if(!r&&!c)return u;const p=r&&c?`${r}->${c}`:c||r;return`${u} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(f(s.event_type,"")==="canon.check"){const r=f(s.status,"unknown"),c=f(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return f(s.description,f(s.summary,"World event"))}case"combat.attack":return f(s.summary,f(s.result,"Attack resolved"));case"combat.defense":return f(s.summary,f(s.result,"Defense resolved"));case"session.outcome":return f(s.summary,f(s.outcome,"Session ended"));default:{const i=Gi(s);return i?`${t}: ${i}`:t}}}function Ji(t,e){const n=C(t)?t:{},s=f(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=f(n.actor_name,"").trim()||e[a]||f(C(n.payload)?n.payload.actor_name:"",""),r=C(n.payload)?n.payload:{},c=f(n.ts,f(n.timestamp,new Date().toISOString())),d=f(n.phase,f(r.phase,"")),u=f(n.category,"");return{type:s,actor:i||a||f(r.actor_name,""),actor_id:a||f(r.actor_id,""),actor_name:i,seq:n.seq,room_id:f(n.room_id,""),phase:d||void 0,category:u||Wi(s),visibility:f(n.visibility,f(r.visibility,"public")),event_id:f(n.event_id,""),content:Vi(s,a,i,r),dice_roll:qi(s,r),timestamp:c}}function Yi(t,e,n){var G,et;const s=f(t.room_id,"")||n||"default",a=C(t.state)?t.state:{},i=C(a.party)?a.party:{},r=C(a.actor_control)?a.actor_control:{},c=C(a.join_gate)?a.join_gate:{},d=C(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([R,I])=>{const g=C(I)?I:{},ie=H(g,"max_hp",void 0,10),Yn=H(g,"hp",void 0,ie),Ma=H(g,"max_mp",void 0,0),za=H(g,"mp",void 0,0),Fa=H(g,"level",void 0,1),Ua=H(g,"xp",void 0,0),Ha=gn(g.alive,Yn>0),Qn=r[R],Xn=typeof Qn=="string"?Qn:void 0,Ba=Ki(g.role,R,Xn),Ka=Hi(g.generation),qa=O(g.joined_at,g.joinedAt,g.started_at,g.startedAt),Ga=O(g.claimed_at,g.claimedAt,g.assigned_at,g.assignedAt,g.assigned_time),Wa=O(g.last_seen,g.lastSeen,g.last_seen_at,g.lastSeenAt,g.last_active,g.lastActive),Va=O(g.scene,g.current_scene,g.currentScene,g.world_scene,g.scene_name,g.sceneName),Ja=O(g.location,g.current_location,g.currentLocation,g.position,g.zone,g.area);return{id:R,name:f(g.name,R),role:Ba,keeper:Xn,archetype:f(g.archetype,""),persona:f(g.persona,""),traits:Rt(g.traits),skills:Rt(g.skills),status:Ha?"active":"dead",generation:Ka,joined_at:qa||void 0,claimed_at:Ga||void 0,last_seen:Wa||void 0,scene:Va||void 0,location:Ja||void 0,inventory:Rt(g.inventory),notes:Rt(g.notes),relationships:Bi(g.relationships),stats:{hp:Yn,max_hp:ie,mp:za,max_mp:Ma,level:Fa,xp:Ua,strength:H(g,"strength","str",10),dexterity:H(g,"dexterity","dex",10),constitution:H(g,"constitution","con",10),intelligence:H(g,"intelligence","int",10),wisdom:H(g,"wisdom","wis",10),charisma:H(g,"charisma","cha",10)}}}),p=u.filter(R=>R.status!=="dead"),l=Ui(t,e),v={phase_open:gn(c.phase_open,!0),min_points:A(c.min_points,3),window:f(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},m=Object.entries(d).map(([R,I])=>{const g=C(I)?I:{};return{actor_id:R,score:A(g.score,0),last_reason:f(g.last_reason,"")||null,reasons:Rt(g.reasons)}}),$=u.reduce((R,I)=>(R[I.id]=I.name,R),{}),b=e.map(R=>Ji(R,$)),k=A(a.turn,1),S=f(a.phase,"round"),T=f(a.map,""),z=C(a.world)?a.world:{},K=T||f(z.ascii_map,f(z.map,"")),D=b.filter((R,I)=>{const g=e[I];if(!C(g))return!1;const ie=C(g.payload)?g.payload:{};return A(ie.turn,-1)===k}),q=(D.length>0?D:b).slice(-12),lt=f(a.status,"active");return{session:{id:s,room:s,status:lt==="ended"?"ended":lt==="paused"?"paused":"active",round:k,actors:p,created_at:((G=b[0])==null?void 0:G.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:S,events:q,timestamp:((et=b[b.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:K||void 0,join_gate:v,contribution_ledger:m,outcome:l,party:p,story_log:b,history:[]}}async function Qi(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await rt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Xi(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([rt(`/api/v1/trpg/state${e}`),Qi(t)]);return Yi(n,s,t)}function Zi(t){return se("/api/v1/trpg/rounds/run",{room_id:t})}function to(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function eo(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),se("/api/v1/trpg/dice/roll",e)}function no(t,e){const n=to();return se("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function so(t,e,n){const s=await U("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function ao(t){const e=await U("trpg.mid_join.request",t);return JSON.parse(e)}async function ma(t,e){await U("masc_broadcast",{agent_name:t,message:e})}async function io(t,e,n=1){await U("masc_add_task",{title:t,description:e,priority:n})}async function oo(t){return U("masc_join",{agent_name:t})}async function _a(t){await U("masc_leave",{agent_name:t})}async function ro(t){await U("masc_heartbeat",{agent_name:t})}async function lo(t=40){return(await U("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function co(t,e=20){return U("masc_task_history",{task_id:t,limit:e})}async function uo(){const t=await rt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!C(e))return null;const n=f(e.id,"").trim(),s=f(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:f(e.status,"open"),argument_count:A(e.argument_count,0),created_at:wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]}async function po(){const t=await rt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!C(e))return null;const n=f(e.id,"").trim(),s=f(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:f(e.initiator,"system"),votes:A(e.votes,0),quorum:A(e.quorum,0),state:f(e.state,"open"),created_at:wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]}async function vo(t){const e=await U("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function fo(t){const e=encodeURIComponent(t),n=await rt(`/api/v1/council/debates/${e}/summary`);if(!C(n))return null;const s=f(n.id,"").trim();return s?{id:s,topic:f(n.topic,""),status:f(n.status,"open"),support_count:A(n.support_count,0),oppose_count:A(n.oppose_count,0),neutral_count:A(n.neutral_count,0),total_arguments:A(n.total_arguments,0),created_at:wt(n.created_at_iso??n.created_at),summary_text:f(n.summary_text,"")}:null}async function mo(){try{const t=await U("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const At=_([]),ae=_([]),ga=_([]),Tt=_([]),Bn=_(null),Dt=_(null),$n=_(new Map),$a=_([]),hn=_("hot"),ha=_(null),at=_(""),Me=_([]),It=_(!1),yn=_(!1),bn=_(!1),xn=_(!1),ya=ot(()=>At.value.filter(t=>t.status==="active"||t.status==="idle")),Kn=ot(()=>{const t=ae.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function _o(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const go=ot(()=>{const t=new Map;for(const e of Tt.value)t.set(e.name,_o(e));return t}),$o=12e4,ho=ot(()=>{const t=Date.now(),e=new Set,n=$n.value;for(const s of Tt.value){const a=n.get(s.name);a!=null&&t-a>$o&&e.add(s.name)}return e}),we={},yo=5e3;function kn(){delete we.compact,delete we.full}function J(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function jt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ba(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function bo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function xo(t){if(!J(t))return null;const e=h(t.name);return e?{name:e,status:ba(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:jt(t.traits),interests:jt(t.interests),activityLevel:w(t.activityLevel)??w(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function ko(t){if(!J(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:bo(t.status),priority:w(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function wo(t){if(!J(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",s=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:w(t.seq),from:e,content:n,timestamp:s,type:h(t.type)}}function So(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=w(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:w(e.context_ratio)??0,context_tokens:w(e.context_tokens)??0,context_max:w(e.context_max)??0,latency_ms:w(e.latency_ms)??0,generation:w(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:w(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:w(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?w(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Co(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,i=J(n.metrics_window)?n.metrics_window:void 0,r=h(n.name);if(!r)return null;const c=w(n.context_ratio)??w(a==null?void 0:a.context_ratio),d=h(n.status)??h(s==null?void 0:s.status)??"offline",u=ba(d),p=h(n.model)??h(n.active_model)??h(n.primary_model),l=jt(n.skill_secondary),v=a?{source:h(a.source),context_ratio:w(a.context_ratio),context_tokens:w(a.context_tokens),context_max:w(a.context_max),message_count:w(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:h(s.name),status:h(s.status),current_task:h(s.current_task)??null,last_seen:h(s.last_seen)}:void 0,$=So(n.metrics_series);return{name:r,emoji:h(n.emoji),koreanName:h(n.koreanName)??h(n.korean_name),agent_name:h(n.agent_name),trace_id:h(n.trace_id),model:p,primary_model:h(n.primary_model),active_model:h(n.active_model),next_model_hint:h(n.next_model_hint)??null,status:u,last_heartbeat:h(n.last_heartbeat)??h(s==null?void 0:s.last_seen),generation:w(n.generation),turn_count:w(n.turn_count)??w(n.total_turns),context_ratio:c,context_tokens:w(n.context_tokens)??w(a==null?void 0:a.context_tokens),context_max:w(n.context_max)??w(a==null?void 0:a.context_max),context_source:h(n.context_source)??h(a==null?void 0:a.source),context:v,traits:jt(n.traits),interests:jt(n.interests),primaryValue:h(n.primaryValue)??h(n.primary_value),activityLevel:w(n.activityLevel)??w(n.activity_level),memory_recent_note:h(n.memory_recent_note)??null,conversation_tail_count:w(n.conversation_tail_count),k2k_count:w(n.k2k_count),handoff_count_total:w(n.handoff_count_total)??w(n.trace_history_count),compaction_count:w(n.compaction_count),last_compaction_saved_tokens:w(n.last_compaction_saved_tokens),skill_primary:h(n.skill_primary)??null,skill_secondary:l,skill_reason:h(n.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function ze(t="full"){var s,a,i;const e=Date.now(),n=we[t];if(!(n&&e-n.time<yo)){yn.value=!0;try{const r=await Ei(t);we[t]={data:r,time:e},At.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(xo).filter(c=>c!==null),ae.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(ko).filter(c=>c!==null),ga.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(wo).filter(c=>c!==null),Tt.value=Co(r.keepers),Bn.value=J(r.status)?r.status:null,Dt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{yn.value=!1}}}async function mt(){bn.value=!0;try{const t=await Oi(hn.value);$a.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{bn.value=!1}}async function it(){var t;xn.value=!0;try{const e=at.value||((t=Bn.value)==null?void 0:t.room)||"default";at.value||(at.value=e);const n=await Xi(e);ha.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{xn.value=!1}}async function wn(){It.value=!0;try{const t=await mo();Me.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{It.value=!1}}let Be=null,Ke=null;function Ao(){return oa.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map($n.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),$n.value=n}kn(),Be||(Be=setTimeout(()=>{ze(),Be=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Ke||(Ke=setTimeout(()=>{mt(),Ke=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&kn()}})}let Ot=null;function To(){Ot||(Ot=setInterval(()=>{kn(),ze()},1e4))}function No(){Ot&&(clearInterval(Ot),Ot=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function tt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Ro(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function M({timestamp:t}){const e=Ro(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const qn=_(null);function xa(t){qn.value=t}function ms(){qn.value=null}const $t=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Lo(t){if(!t)return 0;const e=$t.findIndex(n=>n.level===t);return e>=0?e:0}function Do({keeper:t}){const e=Lo(t.autonomy_level),n=$t[e]??$t[0];if(!n)return null;const s=(e+1)/$t.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${$t.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${$t.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${M} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function _e(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Po({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${_e(t.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function Eo({keeper:t}){var p,l;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,m=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((v,m)=>{const $=a+m/(i-1)*(n-2*a),b=s-a-(v.context_ratio??0)*(s-2*a);return{x:$,y:b,p:v}}),c=r.map(({x:v,y:m})=>`${v.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:m})=>o`
          <circle cx="${v.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const qe=_("");function Io({keeper:t}){var a,i,r,c;const e=qe.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${qe.value}
        onInput=${d=>{qe.value=d.target.value}}
      />
      ${s.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function jo({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${t.hp}/${t.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${e}%; height:100%; background:${e>50?"#4ade80":e>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${t.mp}/${t.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Oo({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Mo({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function _s({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ge(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function zo({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ge(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ge(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ge(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Fo({keeperName:t}){const[e,n]=re("Loading internal monologue..."),[s,a]=re(""),[i,r]=re([]),[c,d]=re(!1),u=async()=>{try{const l=await U("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};vt(()=>{u()},[t]);const p=async()=>{if(!s.trim())return;d(!0);const l=s;a(""),r(v=>[...v,{role:"You",text:l}]);try{const v=await U("masc_keeper_msg",{name:t,message:l});r(m=>[...m,{role:t,text:typeof v=="string"?v:JSON.stringify(v)}]),u()}catch(v){r(m=>[...m,{role:"System",text:"Error: "+String(v)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(l=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${l.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${l.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${l.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${l.role}</strong>
                <span style="white-space: pre-wrap;">${l.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${l=>a(l.currentTarget.value)} 
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&p()}
              placeholder="Ping the agent..."
              disabled=${c}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${p} 
              disabled=${c||!s.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${c?.5:1};"
            >
              ${c?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function Uo(){var e,n,s;const t=qn.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ms()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${tt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ms()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Po} keeper=${t} />

        ${""}
        <${Eo} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${Io} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${_s} traits=${t.traits??[]} label="Traits" />
            <${_s} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${M} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${y} title="Autonomy">
                <${Do} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${jo} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${Oo} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${Mo} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${zo} keeper=${t} />
          <//>

          <${y} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${t.context_source??((e=t.context)==null?void 0:e.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${t.context_tokens??((n=t.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${t.context_max??((s=t.context)==null?void 0:s.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Fo} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Ho=0;const dt=_([]);function x(t,e="success",n=4e3){const s=++Ho;dt.value=[...dt.value,{id:s,message:t,type:e}],setTimeout(()=>{dt.value=dt.value.filter(a=>a.id!==s)},n)}function Bo(t){dt.value=dt.value.filter(e=>e.id!==t)}function Ko(){const t=dt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Bo(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const qo="masc_dashboard_agent_name",Nt=_(null),Se=_(!1),Qt=_(""),Ce=_([]),Xt=_([]),bt=_(""),Mt=_(!1);function ka(t){Nt.value=t,Gn()}function gs(){Nt.value=null,Qt.value="",Ce.value=[],Xt.value=[],bt.value=""}function Go(){const t=Nt.value;return t?At.value.find(e=>e.name===t)??null:null}function wa(t){return t?ae.value.filter(e=>e.assignee===t):[]}async function Gn(){const t=Nt.value;if(t){Se.value=!0,Qt.value="",Ce.value=[],Xt.value=[];try{const e=await lo(80);Ce.value=e.filter(a=>a.includes(t)).slice(0,20);const n=wa(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await co(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Xt.value=s}catch(e){Qt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Se.value=!1}}}async function $s(){var s;const t=Nt.value,e=bt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(qo))==null?void 0:s.trim())||"dashboard";Mt.value=!0;try{await ma(n,`@${t} ${e}`),bt.value="",x(`Mention sent to ${t}`,"success"),Gn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";x(i,"error")}finally{Mt.value=!1}}function Wo({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${tt} status=${t.status} />
    </div>
  `}function Vo({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Jo(){var a,i,r,c;const t=Nt.value;if(!t)return null;const e=Go(),n=wa(t),s=Ce.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&gs()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${tt} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${M} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Gn()}} disabled=${Se.value}>
              ${Se.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${gs}>Close</button>
          </div>
        </div>

        ${Qt.value?o`<div class="council-error">${Qt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Wo} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${Xt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Xt.value.map(d=>o`<${Vo} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${bt.value}
              onInput=${d=>{bt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&$s()}}
              disabled=${Mt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{$s()}}
              disabled=${Mt.value||bt.value.trim()===""}
            >
              ${Mt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function _t({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Yo({agent:t}){return o`
    <div class="agent" onClick=${()=>ka(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${tt} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Qo(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Xo(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function hs(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Zo({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=go.value.get(t.name),a=ho.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>xa(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${tt} status=${t.status} />
          ${s?o`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${hs(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${hs(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Qo(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?o`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?o`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?o`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?o`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?o`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${M} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?o`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(i=>o`<span class="keeper-trait-chip">${i}</span>`)}
            ${t.traits.length>3?o`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?o`
          <div class="keeper-note-preview">${Xo(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function ys(){var r,c,d,u,p;const t=Bn.value,e=At.value,n=Tt.value,s=Kn.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(c=t==null?void 0:t.monitoring)==null?void 0:c.council;return o`
    <div class="stats-grid">
      <${_t} label="Agents" value=${e.length} />
      <${_t} label="Active" value=${ya.value.length} color="#4ade80" />
      <${_t} label="Keepers" value=${n.length} color="#22d3ee" />
      <${_t} label="Tasks" value=${ae.value.length} />
      <${_t} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${_t} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${xs(a==null?void 0:a.alert_level)}`}>
                ${bs(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ce(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${ce(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${xs(i==null?void 0:i.alert_level)}`}>
                ${bs(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ce(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${ce(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(l=>o`<${Yo} key=${l.name} agent=${l} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(l=>o`<${Zo} key=${l.name} keeper=${l} />`)}
        </div>
      <//>
    </div>

    ${Dt.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Dt.value.running?"Running":"Stopped"}</span>
            ${Dt.value.goal?o`<span>Goal: ${Dt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${y} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${tr(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(p=t.data_quality)!=null&&p.last_sync_at?o`<span>Data Sync: <${M} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function tr(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ce(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function bs(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function xs(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Sn=_([]),Cn=_([]),zt=_(""),Ae=_(!1),Ft=_(!1),Zt=_(""),Te=_(null),V=_(null),An=_(!1);async function Tn(){Ae.value=!0,Zt.value="";try{const[t,e]=await Promise.all([uo(),po()]);Sn.value=t,Cn.value=e}catch(t){Zt.value=t instanceof Error?t.message:"Failed to load council data"}finally{Ae.value=!1}}async function ks(){const t=zt.value.trim();if(t){Ft.value=!0;try{const e=await vo(t);zt.value="",x(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Tn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";x(n,"error")}finally{Ft.value=!1}}}async function er(t){Te.value=t,An.value=!0,V.value=null;try{V.value=await fo(t)}catch(e){Zt.value=e instanceof Error?e.message:"Failed to load debate status",V.value=null}finally{An.value=!1}}function nr({debate:t}){const e=Te.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>er(t.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Args: ${t.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function sr({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function ar(){return vt(()=>{Tn()},[]),o`
    <div>
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${zt.value}
            onInput=${t=>{zt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ks()}}
            disabled=${Ft.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ks}
            disabled=${Ft.value||zt.value.trim()===""}
          >
            ${Ft.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Tn} disabled=${Ae.value}>
            ${Ae.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Zt.value?o`<div class="council-error">${Zt.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${Sn.value.length===0?o`<div class="empty-state">No debates yet</div>`:Sn.value.map(t=>o`<${nr} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Cn.value.length===0?o`<div class="empty-state">No active sessions</div>`:Cn.value.map(t=>o`<${sr} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Te.value?`Debate Detail (${Te.value})`:"Debate Detail"} class="section">
        ${An.value?o`<div class="loading-indicator">Loading debate detail...</div>`:V.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${V.value.status}</span>
                  <span>Total arguments: ${V.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${V.value.support_count}</span>
                  <span>Oppose: ${V.value.oppose_count}</span>
                  <span>Neutral: ${V.value.neutral_count}</span>
                </div>
                ${V.value.summary_text?o`<pre class="council-detail">${V.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function ir({text:t}){if(!t)return null;const e=or(t);return o`<div class="markdown-content">${e}</div>`}function or(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${We(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${We(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${We(i.join(`
`))}</p>`)}return n}function We(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const rr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Nn=_([]),Ut=_(!1),Rn=_(null),Ht=_(""),lr=_("dashboard-user"),Bt=_(!1);async function Sa(t){Rn.value=t,Ut.value=!0;try{const e=await Mi(t);if(Rn.value!==t)return;Nn.value=e.comments??[]}catch{}finally{Ut.value=!1}}async function ws(t){const e=Ht.value.trim();if(e){Bt.value=!0;try{await zi(t,lr.value,e),Ht.value="",x("Comment posted","success"),await Sa(t),mt()}catch{x("Failed to post comment","error")}finally{Bt.value=!1}}}function cr(){const t=hn.value;return o`
    <div class="board-controls">
      ${rr.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{hn.value=e.id,mt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Ca({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function ur({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await fa(t.id,n),mt()}catch{x("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>gi(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ca} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${M} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function dr({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${M} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function pr({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ht.value}
        onInput=${e=>{Ht.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ws(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Bt.value}
      />
      <button
        onClick=${()=>ws(t)}
        disabled=${Bt.value||Ht.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Bt.value?"...":"Post"}
      </button>
    </div>
  `}function vr({post:t}){Rn.value!==t.id&&!Ut.value&&Sa(t.id);const e=async n=>{try{await fa(t.id,n),mt()}catch{x("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Oe("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${Ca} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${ir} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${M} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${Ut.value?"...":Nn.value.length})">
        ${Ut.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${dr} comments=${Nn.value} />`}
        <${pr} postId=${t.id} />
      <//>
    </div>
  `}function fr(){const t=$a.value,e=bn.value,n=Z.value.postId;if(n){const s=t.find(a=>a.id===n);return s?o`<${vr} post=${s} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Oe("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${cr} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(s=>o`<${ur} key=${s.id} post=${s} />`)}
          </div>`}
  `}function mr(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function _r(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Ss(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function gr({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function $r(){const t=ga.value.map(mr),e=ke.value.map(_r),n=[...t,...e].sort((s,a)=>Ss(a.timestamp)-Ss(s.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>o`<${gr} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function Aa({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const hr={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function yr(t){return hr[t]}function gt({metric:t}){const e=yr(t);return o`
    <span
      class="metric-tip"
      tabindex="0"
      role="button"
      aria-label="${e.label} 설명"
      title="${e.description} (source: ${e.sourcePath})"
    >
      i
      <span class="metric-tip-pop" role="tooltip">
        <strong>${e.label}</strong>
        <span>${e.description}</span>
        ${e.formula?o`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?o`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function br({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>ka(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Aa} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function xr(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function kr(t){var a,i,r;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(r=t.memory_recent_note)==null?void 0:r.trim();return s||"—"}function wr(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function Sr(t){var s;const e=t.drift_count_total??0,n=xr((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function Cr({keeper:t}){var a;const e=kr(t),n=wr(t),s=Sr(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>xa(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Aa} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${gt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${M} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${gt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${gt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${gt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${gt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${gt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${s}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(a=t.agent)!=null&&a.current_task?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Task</span>
              <span class="keeper-value">${t.agent.current_task}</span>
            </div>
          `:null}
          ${t.will?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Will (의지)</span>
              <span class="keeper-value">${t.will}</span>
            </div>
          `:null}
          ${t.needs?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Needs (니즈)</span>
              <span class="keeper-value">${t.needs}</span>
            </div>
          `:null}
          ${t.desires?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Desires (욕구)</span>
              <span class="keeper-value">${t.desires}</span>
            </div>
          `:null}
          ${t.memory_recent_note?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Memory Note</span>
              <span class="keeper-value memory-note">"${t.memory_recent_note}"</span>
            </div>
          `:null}
        </div>
      </div>
    </div>
  `}function Ar(){const t=At.value,e=Tt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Cr} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${br} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ve({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${M} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Tr(){const{todo:t,inProgress:e,done:n}=Kn.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Ve} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Ve} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Ve} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function Nr(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function Je({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${Nr(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${M} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function Rr(){const t=Kn.value,e=t.inProgress,n=t.todo,s=t.done,a=ya.value,i=n.filter(c=>(c.priority??3)<=2),r=n.filter(c=>!c.assignee);return o`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">In Progress</div>
        <div class="stat-value" style="color:#fbbf24">${e.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Ready Queue</div>
        <div class="stat-value">${n.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Urgent Ready</div>
        <div class="stat-value" style="color:#fb7185">${i.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Done (Visible)</div>
        <div class="stat-value" style="color:#4ade80">${s.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${y} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(c=>o`<${Je} key=${c.id} task=${c} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(c=>o`<${Je} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(c=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${c.name}</div>
                    <div class="council-sub">
                      ${c.current_task?o`<span>${c.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${tt} status=${c.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(c=>o`<${Je} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>
  `}function Lr({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function Dr(){const t=ke.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Lr} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Ne=_("all"),Re=_("all"),Ta=ot(()=>{let t=Me.value;return Ne.value!=="all"&&(t=t.filter(e=>e.horizon===Ne.value)),Re.value!=="all"&&(t=t.filter(e=>e.status===Re.value)),t}),Pr=ot(()=>{const t={short:[],mid:[],long:[]};for(const e of Ta.value){const n=t[e.horizon];n&&n.push(e)}return t});function Er(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Wn(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ge(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Ir({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ge(t.horizon)}">
            ${Wn(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Er(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${M} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${tt} status=${t.status} />
        <div class="goal-updated">
          <${M} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ye({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${y} title="${Wn(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${Ir} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function jr(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ne.value===t?"active":""}"
            onClick=${()=>{Ne.value=t}}
          >
            ${t==="all"?"All":Wn(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Re.value===t?"active":""}"
            onClick=${()=>{Re.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Or(){const t=Me.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Mr(){vt(()=>{wn()},[]);const t=Pr.value;return o`
    <div>
      <${y} title="Goals Overview" class="section">
        <${Or} />
        <${jr} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${wn} disabled=${It.value}>
            ${It.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${It.value&&Me.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ta.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${Ye} horizon="short" items=${t.short??[]} />
            <${Ye} horizon="mid" items=${t.mid??[]} />
            <${Ye} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const Lt=_(""),Qe=_("ability_check"),Xe=_("10"),Ze=_("12"),ue=_(""),de=_("idle"),pe=_(""),ve=_("keeper-late"),tn=_("player"),en=_(""),B=_("idle"),nn=_(null),Ln=_(null),Na=_("overview"),sn=_("all"),an=_("all"),on=_("all"),zr=12e4,Fe=_(null),Cs=_(Date.now());function Fr(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ur(t,e){return e>0?Math.round(t/e*100):0}const Hr={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Br={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function rn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Kr(t){const e=t.trim().toLowerCase();return Hr[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function qr(t){const e=t.trim().toLowerCase();return Br[e]??"상황에 따라 선택되는 전술 액션입니다."}function pt(t){return typeof t=="object"&&t!==null}function F(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Q(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function te(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function Dn(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Gr(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Wr(t){Na.value=t}function Ra(t){const e=Fe.value;return e==null||e<=t}function Vr(t){const e=Fe.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Le(){Fe.value=null}function La(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Jr(t,e){La(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Fe.value=Date.now()+zr,x("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function $e(t){return Ra(t)?(x("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Pn(t,e,n){return La([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Yr({hp:t,max:e}){const n=Ur(t,e),s=Fr(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Qr({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Xr({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Da({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${tt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Xr} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Yr} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Qr} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${rn(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(c=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${rn(c)}</span>
                  <span class="trpg-annot-desc">${Kr(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(c=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${rn(c)}</span>
                  <span class="trpg-annot-desc">${qr(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Zr({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Pa({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Gr(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Dn(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${M} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function tl({events:t}){const e="__none__",n=sn.value,s=an.value,a=on.value,i=Array.from(new Set(t.map(Dn).map(l=>l.trim()).filter(l=>l!==""))).sort((l,v)=>l.localeCompare(v)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,v)=>l.localeCompare(v)),c=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,v)=>l.localeCompare(v)),u=t.some(l=>(l.phase??"").trim()===""),p=t.filter(l=>{if(n!=="all"&&Dn(l)!==n)return!1;const v=(l.type??"").trim(),m=(l.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if(m!=="")return!1}else if(a!=="all"&&m!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{sn.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${l=>{an.value=l.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${l=>{on.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{sn.value="all",an.value="all",on.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${Pa} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function el({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Ea({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function nl({state:t,nowMs:e}){var u;const n=at.value||((u=t.session)==null?void 0:u.room)||"",s=de.value,a=t.party??[];if(!a.find(p=>p.id===Lt.value)&&a.length>0){const p=a[0];p&&(Lt.value=p.id)}const r=async()=>{var l,v;if(!n){x("Room ID가 비어 있습니다.","error");return}if(!$e(e))return;const p=((l=t.current_round)==null?void 0:l.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Pn("라운드 실행",n,p)){de.value="running";try{const m=await Zi(n);Ln.value=m,de.value="ok";const $=pt(m.summary)?m.summary:null,b=$?te($,"advanced",!1):!1,k=$?F($,"progress_reason",""):"";x(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,b?"success":"warning"),it()}catch(m){Ln.value=null,de.value="error";const $=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";x($,"error")}finally{Le()}}},c=async()=>{var l,v;if(!n||!$e(e))return;const p=((l=t.current_round)==null?void 0:l.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Pn("턴 강제 진행",n,p))try{await no(n),x("턴을 다음 단계로 이동했습니다.","success"),it()}catch{x("턴 이동에 실패했습니다.","error")}finally{Le()}},d=async()=>{if(!n||!$e(e))return;const p=Lt.value.trim();if(!p){x("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(Xe.value,10),v=Number.parseInt(Ze.value,10);if(Number.isNaN(l)||Number.isNaN(v)){x("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(ue.value,10),$=ue.value.trim()===""||Number.isNaN(m)?void 0:m;try{await eo({roomId:n,actorId:p,action:Qe.value.trim()||"ability_check",statValue:l,dc:v,rawD20:$}),x("주사위 판정을 기록했습니다.","success"),it()}catch{x("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{at.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Lt.value}
            onChange=${p=>{Lt.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(p=>o`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Qe.value}
              onInput=${p=>{Qe.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Xe.value}
              onInput=${p=>{Xe.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ze.value}
              onInput=${p=>{Ze.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ue.value}
              onInput=${p=>{ue.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function sl({state:t,nowMs:e}){var d;const n=at.value||((d=t.session)==null?void 0:d.room)||"",s=t.join_gate,a=nn.value,i=pt(a)?a:null,r=async()=>{const u=pe.value.trim(),p=ve.value.trim();if(!n||!u){x("Room/Actor가 필요합니다.","warning");return}B.value="checking";try{const l=await so(n,u,p||void 0);nn.value=l,B.value="ok",x("참가 가능 여부를 갱신했습니다.","success")}catch(l){B.value="error";const v=l instanceof Error?l.message:"참가 가능 여부 확인에 실패했습니다.";x(v,"error")}},c=async()=>{var m,$;const u=pe.value.trim(),p=ve.value.trim(),l=en.value.trim();if(!n||!u||!p){x("Room/Actor/Keeper가 필요합니다.","warning");return}if(!$e(e))return;const v=((m=t.current_round)==null?void 0:m.phase)??(($=t.session)==null?void 0:$.status)??"unknown";if(Pn("Mid-Join 승인 요청",n,v)){B.value="requesting";try{const b=await ao({room_id:n,actor_id:u,keeper_name:p,role:tn.value,...l?{name:l}:{}});nn.value=b;const k=pt(b)?te(b,"granted",!1):!1,S=pt(b)?F(b,"reason_code",""):"";k?x("Mid-Join이 승인되었습니다.","success"):x(`Mid-Join이 거절되었습니다${S?`: ${S}`:""}`,"warning"),B.value=k?"ok":"error",it()}catch(b){B.value="error";const k=b instanceof Error?b.message:"Mid-Join 요청에 실패했습니다.";x(k,"error")}finally{Le()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            id="trpg-join-actor-input"
            name="trpg-join-actor-input"
            type="text"
            value=${pe.value}
            onInput=${u=>{pe.value=u.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${ve.value}
            onInput=${u=>{ve.value=u.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${tn.value}
            onChange=${u=>{tn.value=u.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${en.value}
            onInput=${u=>{en.value=u.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${r} disabled=${B.value==="checking"||B.value==="requesting"}>
              ${B.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${B.value==="checking"||B.value==="requesting"}>
              ${B.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${te(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Q(i,"effective_score",0)}/${Q(i,"required_points",0)}</span>
            ${F(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${F(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Ia({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ja({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Oa(){const t=Ln.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=pt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(pt).slice(-8),i=t.canon_check,r=pt(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],u=n?te(n,"advanced",!1):!1,p=n?F(n,"progress_reason",""):"",l=n?F(n,"progress_detail",""):"",v=n?Q(n,"player_successes",0):0,m=n?Q(n,"player_required_successes",0):0,$=n?te(n,"dm_success",!1):!1,b=n?Q(n,"timeouts",0):0,k=n?Q(n,"unavailable",0):0,S=n?Q(n,"reprompts",0):0,T=n?Q(n,"npc_attacks",0):0,z=n?Q(n,"keeper_timeout_sec",0):0,K=n?Q(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${v}/${m}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${K}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const q=F(D,"status","unknown"),lt=F(D,"actor_id","-"),ct=F(D,"role","-"),G=F(D,"reason",""),et=F(D,"action_type",""),R=F(D,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${lt} (${ct})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${et?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${G}</div>`:null}
                  ${R?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${R.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${F(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function al({state:t,nowMs:e}){var r,c,d;const n=at.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Ra(e),i=Vr(e);return o`
    <${y} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Jr(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Le(),x("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function il({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Wr(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function ol({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${y} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Pa} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${Zr} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${ja} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${Ia} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Da} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Ea} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function rl({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${tl} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${Oa} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${ja} state=${t} />
        <//>
      </div>
    </div>
  `}function ll({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${al} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${nl} state=${t} nowMs=${e} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${sl} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${Oa} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${Ia} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Da} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Ea} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function cl(){var c,d,u,p,l;const t=ha.value,e=xn.value;if(vt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{Cs.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>it()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Na.value,r=Cs.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${at.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((u=t.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>it()}>새로고침</button>
      </div>

      <${el} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((l=t.current_round)==null?void 0:l.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      <${il} active=${i} />

      ${i==="overview"?o`<${ol} state=${t} />`:i==="timeline"?o`<${rl} state=${t} />`:o`<${ll} state=${t} nowMs=${r} />`}
    </div>
  `}const Vn="masc_dashboard_agent_name";function ul(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Vn);return e??n??"dashboard"}const Y=_(ul()),Kt=_(""),qt=_(""),De=_(""),Gt=_(!1),ht=_(!1),Wt=_(!1),Vt=_(!1),Pe=_(!1),Ue=_(!1);function Jn(t){const e=t.trim();Y.value=e,e&&localStorage.setItem(Vn,e)}function dl(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function En(){const t=Y.value.trim();if(t){Wt.value=!0;try{const e=await oo(t),n=dl(e);n&&Jn(n),Ue.value=!0,x(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";x(n,"error")}finally{Wt.value=!1}}}async function pl(){const t=Y.value.trim();if(t){Vt.value=!0;try{await _a(t),Ue.value=!1,x(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";x(n,"error")}finally{Vt.value=!1}}}async function vl(){const t=Y.value.trim();if(t)try{await _a(t)}catch{}localStorage.removeItem(Vn),Jn("dashboard"),Ue.value=!1,await En()}async function fl(){const t=Y.value.trim();if(t){Pe.value=!0;try{await ro(t),x("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";x(n,"error")}finally{Pe.value=!1}}}async function As(){const t=Y.value.trim(),e=Kt.value.trim();if(!(!t||!e)){Gt.value=!0;try{await ma(t,e),Kt.value="",x("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";x(s,"error")}finally{Gt.value=!1}}}async function ml(){const t=qt.value.trim(),e=De.value.trim()||"Created from dashboard";if(t){ht.value=!0;try{await io(t,e,1),qt.value="",De.value="",x("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";x(s,"error")}finally{ht.value=!1}}}function _l(){return vt(()=>{En()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Y.value}
        onInput=${t=>Jn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Kt.value}
          onInput=${t=>{Kt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&As()}}
          disabled=${Gt.value}
        />
        <button
          class="control-btn"
          onClick=${As}
          disabled=${Gt.value||Kt.value.trim()===""||Y.value.trim()===""}
        >
          ${Gt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{En()}}
          disabled=${Wt.value||Y.value.trim()===""}
        >
          ${Wt.value?"Joining...":Ue.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{pl()}}
          disabled=${Vt.value||Y.value.trim()===""}
        >
          ${Vt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{vl()}}
          disabled=${Wt.value||Vt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{fl()}}
          disabled=${Pe.value||Y.value.trim()===""}
        >
          ${Pe.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${qt.value}
        onInput=${t=>{qt.value=t.target.value}}
        disabled=${ht.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${De.value}
        onInput=${t=>{De.value=t.target.value}}
        disabled=${ht.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${ml}
        disabled=${ht.value||qt.value.trim()===""}
      >
        ${ht.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function gl(){const t=kt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Un.value} events</span>
    </div>
  `}const $l=[{id:"overview",label:"Overview"},{id:"council",label:"Decisions"},{id:"board",label:"Discussions"},{id:"execution",label:"Execution"},{id:"activity",label:"Activity"},{id:"goals",label:"Goals"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function hl(){const t=Z.value.tab,e=kt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${$l.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Oe(n.id)}
            >
              ${n.label}
            </button>
          `)}
        </div>
        <div class="rail-links">
          <a class="rail-link" href="/dashboard/lodge">Legacy Lodge</a>
          <a class="rail-link" href="/dashboard/credits">Legacy Credits</a>
        </div>
      </section>

      <section class="rail-card">
        <h3>Live Snapshot</h3>
        <div class="rail-stats">
          <div class="rail-stat-row">
            <span>Connection</span>
            <strong>${e?"Online":"Offline"}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Agents</span>
            <strong>${At.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Tt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${ae.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Un.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ze(),t==="board"&&mt(),t==="trpg"&&it()}}
        >
          Refresh Now
        </button>
      </section>

      <${_l} />
    </aside>
  `}function yl(){switch(Z.value.tab){case"overview":return o`<${ys} />`;case"council":return o`<${ar} />`;case"board":return o`<${fr} />`;case"execution":return o`<${Rr} />`;case"activity":return o`<${$r} />`;case"agents":return o`<${Ar} />`;case"tasks":return o`<${Tr} />`;case"goals":return o`<${Mr} />`;case"journal":return o`<${Dr} />`;case"trpg":return o`<${cl} />`;default:return o`<${ys} />`}}function bl(){return vt(()=>{$i(),la(),ze();const t=Ao();return To(),()=>{Ai(),t(),No()}},[]),vt(()=>{const t=Z.value.tab;t==="board"&&mt(),t==="trpg"&&it(),t==="goals"&&wn()},[Z.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Decision and execution operations console</p>
        </div>
        <div class="header-right">
          <${gl} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${yi} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${yn.value&&!kt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${yl} />`}
        </main>
        <${hl} />
      </div>

      <${Uo} />
      <${Jo} />
      <${Ko} />
    </div>
  `}const Ts=document.getElementById("app");Ts&&ei(o`<${bl} />`,Ts);
