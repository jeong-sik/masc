var Co=Object.defineProperty;var No=(t,e,n)=>e in t?Co(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ot=(t,e,n)=>No(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Dn,I,ei,ni,Ct,ma,si,ai,ii,Ys,_s,gs,Ce={},oi=[],To=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Pn=Array.isArray;function pt(t,e){for(var n in e)t[n]=e[n];return t}function Xs(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ri(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Dn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return nn(t,r,s,a,null)}function nn(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ei,__i:-1,__u:0};return a==null&&I.vnode!=null&&I.vnode(i),i}function Ee(t){return t.children}function oe(t,e){this.props=t,this.context=e}function Vt(t,e){if(e==null)return t.__?Vt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Vt(t):null}function li(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return li(t)}}function fa(t){(!t.__d&&(t.__d=!0)&&Ct.push(t)&&!dn.__r++||ma!=I.debounceRendering)&&((ma=I.debounceRendering)||si)(dn)}function dn(){for(var t,e,n,s,a,i,r,l=1;Ct.length;)Ct.length>l&&Ct.sort(ai),t=Ct.shift(),l=Ct.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=pt({},s)).__v=s.__v+1,I.vnode&&I.vnode(n),Qs(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??Vt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,di(i,n,r),s.__e=s.__=null,n.__e!=a&&li(n)));dn.__r=0}function ci(t,e,n,s,a,i,r,l,d,u,v){var c,p,m,g,$,k,T,N=s&&s.__k||oi,O=e.length;for(d=Ro(n,e,N,d,O),c=0;c<O;c++)(m=n.__k[c])!=null&&(p=m.__i==-1?Ce:N[m.__i]||Ce,m.__i=c,k=Qs(t,m,p,a,i,r,l,d,u,v),g=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&Zs(p.ref,null,m),v.push(m.ref,m.__c||g,m)),$==null&&g!=null&&($=g),(T=!!(4&m.__u))||p.__k===m.__k?d=ui(m,d,t,T):typeof m.type=="function"&&k!==void 0?d=k:g&&(d=g.nextSibling),m.__u&=-7);return n.__e=$,d}function Ro(t,e,n,s,a){var i,r,l,d,u,v=n.length,c=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=nn(null,r,null,null,null):Pn(r)?r=t.__k[i]=nn(Ee,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=nn(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=Lo(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=Vt(l)),vi(l,l));return s}function ui(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=ui(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=Vt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Lo(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&l==null||v&&l==u.key&&d==u.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function _a(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||To.test(e)?n:n+"px"}function Ke(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||_a(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||_a(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(ii,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Ys,t.addEventListener(e,i?gs:_s,i)):t.removeEventListener(e,i?gs:_s,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ga(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ys++;else if(e.t<n.u)return;return n(I.event?I.event(e):e)}}}function Qs(t,e,n,s,a,i,r,l,d,u){var v,c,p,m,g,$,k,T,N,O,H,D,X,St,At,Q,dt,L=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=I.__b)&&v(e);t:if(typeof L=="function")try{if(T=e.props,N="prototype"in L&&L.prototype.render,O=(v=L.contextType)&&s[v.__c],H=v?O?O.props.value:v.__:s,n.__c?k=(c=e.__c=n.__c).__=c.__E:(N?e.__c=c=new L(T,H):(e.__c=c=new oe(T,H),c.constructor=L,c.render=Do),O&&O.sub(c),c.state||(c.state={}),c.__n=s,p=c.__d=!0,c.__h=[],c._sb=[]),N&&c.__s==null&&(c.__s=c.state),N&&L.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=pt({},c.__s)),pt(c.__s,L.getDerivedStateFromProps(T,c.__s))),m=c.props,g=c.state,c.__v=e,p)N&&L.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),N&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(N&&L.getDerivedStateFromProps==null&&T!==m&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(T,H),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(T,c.__s,H)===!1){for(e.__v!=n.__v&&(c.props=T,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),D=0;D<c._sb.length;D++)c.__h.push(c._sb[D]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(T,c.__s,H),N&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(m,g,$)})}if(c.context=H,c.props=T,c.__P=t,c.__e=!1,X=I.__r,St=0,N){for(c.state=c.__s,c.__d=!1,X&&X(e),v=c.render(c.props,c.state,c.context),At=0;At<c._sb.length;At++)c.__h.push(c._sb[At]);c._sb=[]}else do c.__d=!1,X&&X(e),v=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++St<25);c.state=c.__s,c.getChildContext!=null&&(s=pt(pt({},s),c.getChildContext())),N&&!p&&c.getSnapshotBeforeUpdate!=null&&($=c.getSnapshotBeforeUpdate(m,g)),Q=v,v!=null&&v.type===Ee&&v.key==null&&(Q=pi(v.props.children)),l=ci(t,Pn(Q)?Q:[Q],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),k&&(c.__E=c.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(dt=i.length;dt--;)Xs(i[dt]);$s(e)}else e.__e=n.__e,e.__k=n.__k,z.then||$s(e);I.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Io(n.__e,e,n,s,a,i,r,d,u);return(v=I.diffed)&&v(e),128&e.__u?void 0:l}function $s(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach($s)}function di(t,e,n){for(var s=0;s<n.length;s++)Zs(n[s],n[++s],n[++s]);I.__c&&I.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){I.__e(i,a.__v)}})}function pi(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Pn(t)?t.map(pi):pt({},t)}function Io(t,e,n,s,a,i,r,l,d){var u,v,c,p,m,g,$,k=n.props||Ce,T=e.props,N=e.type;if(N=="svg"?a="http://www.w3.org/2000/svg":N=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((m=i[u])&&"setAttribute"in m==!!N&&(N?m.localName==N:m.nodeType==3)){t=m,i[u]=null;break}}if(t==null){if(N==null)return document.createTextNode(T);t=document.createElementNS(a,N,T.is&&T),l&&(I.__m&&I.__m(e,i),l=!1),i=null}if(N==null)k===T||l&&t.data==T||(t.data=T);else{if(i=i&&Dn.call(t.childNodes),!l&&i!=null)for(k={},u=0;u<t.attributes.length;u++)k[(m=t.attributes[u]).name]=m.value;for(u in k)if(m=k[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=m;else if(!(u in T)){if(u=="value"&&"defaultValue"in T||u=="checked"&&"defaultChecked"in T)continue;Ke(t,u,null,m,a)}}for(u in T)m=T[u],u=="children"?p=m:u=="dangerouslySetInnerHTML"?v=m:u=="value"?g=m:u=="checked"?$=m:l&&typeof m!="function"||k[u]===m||Ke(t,u,m,k[u],a);if(v)l||c&&(v.__html==c.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(c&&(t.innerHTML=""),ci(e.type=="template"?t.content:t,Pn(p)?p:[p],e,n,s,N=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&Vt(n,0),l,d),i!=null)for(u=i.length;u--;)Xs(i[u]);l||(u="value",N=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[u]||N=="progress"&&!g||N=="option"&&g!=k[u])&&Ke(t,u,g,k[u],a),u="checked",$!=null&&$!=t[u]&&Ke(t,u,$,k[u],a))}return t}function Zs(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){I.__e(a,n)}}function vi(t,e,n){var s,a;if(I.unmount&&I.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Zs(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){I.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&vi(s[a],e,n||typeof t.type!="function");n||Xs(t.__e),t.__c=t.__=t.__e=void 0}function Do(t,e,n){return this.constructor(t,n)}function Po(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),I.__&&I.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Qs(e,t=e.__k=ri(Ee,null,[t]),a||Ce,Ce,e.namespaceURI,a?null:e.firstChild?Dn.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),di(i,t,r)}Dn=oi.slice,I={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},ei=0,ni=function(t){return t!=null&&t.constructor===void 0},oe.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=pt({},this.state),typeof t=="function"&&(t=t(pt({},n),this.props)),t&&pt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),fa(this))},oe.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),fa(this))},oe.prototype.render=Ee,Ct=[],si=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,ai=function(t,e){return t.__v.__b-e.__v.__b},dn.__r=0,ii=/(PointerCapture)$|Capture$/i,Ys=0,_s=ga(!1),gs=ga(!0);var mi=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,mi(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},$a=new Map;function Mo(t){var e=$a.get(this);return e||(e=new Map,$a.set(this,e)),(e=mi(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&u(),u(v));for(var c=0;c<n[v].length;c++)s=n[v][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Mo.bind(ri),Ne,j,Hn,ha,hs=0,fi=[],F=I,ya=F.__b,ba=F.__r,xa=F.diffed,ka=F.__c,wa=F.unmount,Sa=F.__;function ta(t,e){F.__h&&F.__h(j,t,hs||e),hs=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Be(t){return hs=1,Eo($i,t)}function Eo(t,e,n){var s=ta(Ne++,2);if(s.t=t,!s.__c&&(s.__=[$i(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,l);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=j,!j.__f)){var a=function(l,d,u){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,u);var c=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(c=!0)}}),i&&i.call(this,l,d,u)||c};j.__f=!0;var i=j.shouldComponentUpdate,r=j.componentWillUpdate;j.componentWillUpdate=function(l,d,u){if(this.__e){var v=i;i=void 0,a(l,d,u),i=v}r&&r.call(this,l,d,u)},j.shouldComponentUpdate=a}return s.__N||s.__}function xt(t,e){var n=ta(Ne++,3);!F.__s&&gi(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function _i(t,e){var n=ta(Ne++,7);return gi(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Oo(){for(var t;t=fi.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(sn),t.__H.__h.forEach(ys),t.__H.__h=[]}catch(e){t.__H.__h=[],F.__e(e,t.__v)}}F.__b=function(t){j=null,ya&&ya(t)},F.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Sa&&Sa(t,e)},F.__r=function(t){ba&&ba(t),Ne=0;var e=(j=t.__c).__H;e&&(Hn===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(sn),e.__h.forEach(ys),e.__h=[],Ne=0)),Hn=j},F.diffed=function(t){xa&&xa(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(fi.push(e)!==1&&ha===F.requestAnimationFrame||((ha=F.requestAnimationFrame)||jo)(Oo)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Hn=j=null},F.__c=function(t,e){e.some(function(n){try{n.__h.forEach(sn),n.__h=n.__h.filter(function(s){return!s.__||ys(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],F.__e(s,n.__v)}}),ka&&ka(t,e)},F.unmount=function(t){wa&&wa(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{sn(s)}catch(a){e=a}}),n.__H=void 0,e&&F.__e(e,n.__v))};var Aa=typeof requestAnimationFrame=="function";function jo(t){var e,n=function(){clearTimeout(s),Aa&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Aa&&(e=requestAnimationFrame(n))}function sn(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function ys(t){var e=j;t.__c=t.__(),j=e}function gi(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function $i(t,e){return typeof e=="function"?e(t):e}var Fo=Symbol.for("preact-signals");function Mn(){if(yt>1)yt--;else{for(var t,e=!1;re!==void 0;){var n=re;for(re=void 0,bs++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&bi(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(bs=0,yt--,e)throw t}}function zo(t){if(yt>0)return t();yt++;try{return t()}finally{Mn()}}var R=void 0;function hi(t){var e=R;R=void 0;try{return t()}finally{R=e}}var re=void 0,yt=0,bs=0,pn=0;function yi(t){if(R!==void 0){var e=t.n;if(e===void 0||e.t!==R)return e={i:0,S:t,p:R.s,n:void 0,t:R,e:void 0,x:void 0,r:e},R.s!==void 0&&(R.s.n=e),R.s=e,t.n=e,32&R.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=R.s,e.n=void 0,R.s.n=e,R.s=e),e}}function U(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}U.prototype.brand=Fo;U.prototype.h=function(){return!0};U.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:hi(function(){var s;(s=e.W)==null||s.call(e)}))};U.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&hi(function(){var a;(a=e.Z)==null||a.call(e)}))}};U.prototype.subscribe=function(t){var e=this;return Oe(function(){var n=e.value,s=R;R=void 0;try{t(n)}finally{R=s}},{name:"sub"})};U.prototype.valueOf=function(){return this.value};U.prototype.toString=function(){return this.value+""};U.prototype.toJSON=function(){return this.value};U.prototype.peek=function(){var t=R;R=void 0;try{return this.value}finally{R=t}};Object.defineProperty(U.prototype,"value",{get:function(){var t=yi(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(bs>100)throw new Error("Cycle detected");this.v=t,this.i++,pn++,yt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Mn()}}}});function f(t,e){return new U(t,e)}function bi(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function xi(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function ki(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function It(t,e){U.call(this,void 0),this.x=t,this.s=void 0,this.g=pn-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}It.prototype=new U;It.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===pn))return!0;if(this.g=pn,this.f|=1,this.i>0&&!bi(this))return this.f&=-2,!0;var t=R;try{xi(this),R=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return R=t,ki(this),this.f&=-2,!0};It.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}U.prototype.S.call(this,t)};It.prototype.U=function(t){if(this.t!==void 0&&(U.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};It.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(It.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=yi(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function W(t,e){return new It(t,e)}function wi(t){var e=t.u;if(t.u=void 0,typeof e=="function"){yt++;var n=R;R=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,ea(t),s}finally{R=n,Mn()}}}function ea(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,wi(t)}function Uo(t){if(R!==this)throw new Error("Out-of-order effect");ki(this),R=t,this.f&=-2,8&this.f&&ea(this),Mn()}function Zt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Zt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Zt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,wi(this),xi(this),yt++;var t=R;return R=this,Uo.bind(this,t)};Zt.prototype.N=function(){2&this.f||(this.f|=2,this.o=re,re=this)};Zt.prototype.d=function(){this.f|=8,1&this.f||ea(this)};Zt.prototype.dispose=function(){this.d()};function Oe(t,e){var n=new Zt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Si,qe,Ho=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ai=[];Oe(function(){Si=this.N})();function te(t,e){I[t]=e.bind(null,I[t]||function(){})}function vn(t){if(qe){var e=qe;qe=void 0,e()}qe=t&&t.S()}function Ci(t){var e=this,n=t.data,s=Bo(n);s.value=n;var a=_i(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=W(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),v=W(function(){return!Array.isArray(u.value)&&!ni(u.value)}),c=Oe(function(){if(this.N=Ni,v.value){var m=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[v,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Ci.displayName="ReactiveTextNode";Object.defineProperties(U.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ci},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});te("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof U&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});te("__r",function(t,e){if(t(e),e.type!==Ee){vn();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Oe(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Ho&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),vn(n)}});te("__e",function(t,e,n,s){vn(),t(e,n,s)});te("diffed",function(t,e){vn();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],v=s[d];u===void 0?(u=Ko(n,d,v),i[d]=u):u.o(v,a)}for(var c in s)a[c]=s[c]}}t(e)});function Ko(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:Oe(function(){this.N=Ni;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}te("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});te("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});oe.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Bo(t,e){return _i(function(){return f(t,e)},[])}var qo=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Go(){zo(function(){for(var t;t=Ai.shift();)Si.call(t)})}function Ni(){Ai.push(this)===1&&(I.requestAnimationFrame||qo)(Go)}const Wo=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],Ti={tab:"overview",params:{},postId:null},Jo={journal:"activity",mdal:"goals"};function Ca(t){return!!t&&Wo.includes(t)}function Na(t){if(t)return Jo[t]??t}function xs(t){try{return decodeURIComponent(t)}catch{return t}}function ks(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Vo(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ri(t,e){const n=Na(t[0]),s=Na(e.tab),a=Ca(n)?n:Ca(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=xs(t[2]):t[0]==="post"&&t[1]&&(i=xs(t[1]))),{tab:a,params:e,postId:i}}function mn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ti;const n=xs(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=ks(a),r=Vo(s);return Ri(r,i)}function Yo(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ti,params:ks(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=ks(e.replace(/^\?/,""));return Ri(s,a)}function Li(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const at=f(mn(window.location.hash));window.addEventListener("hashchange",()=>{at.value=mn(window.location.hash)});function En(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Li(n)}function Xo(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Qo(){if(window.location.hash&&window.location.hash!=="#"){at.value=mn(window.location.hash);return}const t=Yo(window.location.pathname,window.location.search);if(t){at.value=t;const e=Li(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",at.value=mn(window.location.hash)}const ws=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Zo(){const t=at.value.tab;return o`
    <div class="main-tab-bar">
      ${ws.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>En(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Ta="masc_dashboard_sse_session_id",tr=1e3,er=15e3,kt=f(!1),On=f(0),Ii=f(null),Yt=f([]);function nr(){let t=sessionStorage.getItem(Ta);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ta,t)),t}const sr=200;function Z(t,e,n="system"){const s={agent:t,text:e,timestamp:Date.now(),kind:n};Yt.value=[s,...Yt.value].slice(0,sr)}function Ra(t,e){const n=(e??"").replace(/\s+/g," ").trim();if(!n)return`New ${t.toLowerCase()}`;const s=n.length>88?`${n.slice(0,85)}...`:n;return`${t}: ${s}`}let lt=null,Gt=null,Ss=0;function Di(){Gt&&(clearTimeout(Gt),Gt=null)}function ar(){if(Gt)return;Ss++;const t=Math.min(Ss,5),e=Math.min(er,tr*Math.pow(2,t));Gt=setTimeout(()=>{Gt=null,Pi()},e)}function Pi(){Di(),lt&&(lt.close(),lt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",nr());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);lt=i,i.onopen=()=>{lt===i&&(Ss=0,kt.value=!0)},i.onerror=()=>{lt===i&&(kt.value=!1,i.close(),lt=null,ar())},i.onmessage=r=>{try{const l=JSON.parse(r.data);On.value++,Ii.value=l,ir(l)}catch{}}}function ir(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Z(n,"Joined","system");break;case"agent_left":Z(n,"Left","system");break;case"broadcast":Z(n,`${(t.message??t.content??"").slice(0,80)}`,"system");break;case"task_update":Z(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks");break;case"board_post":case"masc/board_post":Z(n,Ra("Post",t.content??t.message),"board");break;case"board_comment":case"masc/board_comment":Z(n,Ra("Comment",t.content??t.message),"board");break;case"keeper_heartbeat":Z(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers");break;case"keeper_handoff":Z(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers");break;case"keeper_compaction":Z(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers");break;case"keeper_guardrail":Z(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers");break;default:Z(n,e,"system")}}function or(){Di(),lt&&(lt.close(),lt=null),kt.value=!1}function Mi(){return new URLSearchParams(window.location.search)}function Ei(){const t=Mi(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Oi(){return{...Ei(),"Content-Type":"application/json"}}const rr=15e3,ji=3e4,lr=6e4,La=new Set([408,425,429,500,502,503,504]);class je extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ot(this,"method");Ot(this,"path");Ot(this,"status");Ot(this,"statusText");Ot(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function na(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new je({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function cr(){var e,n;const t=Mi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ft(t){const e=await na(t,{headers:Ei()},rr);if(!e.ok)throw new je({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function ur(t){return new Promise(e=>setTimeout(e,t))}function dr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function pr(t){if(t instanceof je)return t.timeout||typeof t.status=="number"&&La.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=dr(t.message);return e!==null&&La.has(e)}async function Fe(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!pr(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await ur(i),s+=1}}async function _t(t,e,n){const s=await na(t,{method:"POST",headers:{...Oi(),...n??{}},body:JSON.stringify(e)},ji);if(!s.ok)throw new je({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function vr(t,e,n,s=ji){const a=await na(t,{method:"POST",headers:{...Oi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new je({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function mr(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function fr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function B(t,e){const n=await vr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},lr),s=mr(n);return fr(s)}function _r(t="compact"){return ft(`/api/v1/dashboard?mode=${t}`)}function gr(){return ft("/api/v1/operator")}function $r(t){return _t("/api/v1/operator/action",t)}function hr(t,e){return _t("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const yr=new Set(["lodge-system","team-session"]);function Xt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function br(t){return yr.has(t.trim().toLowerCase())}function xr(t){return t.filter(e=>!br(e.author))}function kr(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Fi(t){if(!C(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=A(t.score,0),i=A(t.votes_up,0),r=A(t.votes_down,0),l=A(t.votes,a||i-r),d=A(t.comment_count,A(t.reply_count,0)),u=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(C(g)){const k=_(g.name,"").trim();if(k)return k}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||Xt(t.created_at),c=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Xt(t.updated_at):v),m=_(t.title,"").trim()||kr(s);return{id:e,author:n,title:m,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:v,updated_at:c,flair:u,hearth_count:A(t.hearth_count,0)}}function wr(t){if(!C(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:Xt(t.created_at)}}async function Sr(t,e){return Fe("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit","100");const s=n.toString(),a=await ft(`/api/v1/board${s?`?${s}`:""}`),i=Array.isArray(a.posts)?a.posts.map(Fi).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?xr(i):i}})}async function Ar(t){return Fe("fetchBoardPost",async()=>{const e=await ft(`/api/v1/board/${t}?format=flat`),n=C(e.post)?e.post:e,s=Fi(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(wr).filter(r=>r!==null);return{...s,comments:i}})}function zi(t,e){return _t("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:cr()})}function Cr(t,e,n){return _t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Nr(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function K(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function Ia(t){const e=Nr(K(t.outcome,t.result,t.result_code));if(!e)return;const n=K(t.reason,t.reason_code,t.description,t.detail),s=K(t.summary,t.summary_ko,t.summary_en,t.note),a=K(t.details,t.details_text,t.text,t.note),i=K(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=K(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=K(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(p=>{if(typeof p=="string")return p.trim();if(C(p)){const m=_(p.summary,"").trim();if(m)return m;const g=_(p.text,"").trim();if(g)return g;const $=_(p.type,"").trim();return $||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const c=A(t.turn,Number.NaN);if(Number.isFinite(c))return c;const p=A(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=A(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const g=A(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=K(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:u,phase:v||void 0}}function Tr(t,e){const n=C(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>C(r)?_(r.type,"")==="session.outcome":!1),i=C(n.session_outcome)?n.session_outcome:{};if(C(i)&&Object.keys(i).length>0){const r=Ia(i);if(r)return r}if(C(a))return Ia(C(a.payload)?a.payload:{})}function C(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function A(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ht(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function As(t,e=!1){return typeof t=="boolean"?t:e}function ne(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(C(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Rr(t){const e={};if(!C(t)&&!Array.isArray(t))return e;if(C(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!C(n))continue;const s=K(n.to,n.target,n.actor_id,n.name,n.id),a=K(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Lr(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function J(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Ir=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Dr(t){const e=C(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Ir.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Pr(t,e){if(t!=="dice.rolled")return;const n=A(e.raw_d20,0),s=A(e.total,0),a=A(e.bonus,0),i=_(e.action,"roll"),r=A(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Mr(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Er(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Or(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=A(s.total,0),l=A(s.dc,0),d=_(s.label,""),u=a||"actor",v=l>0?` vs DC ${l}`:"",c=d?` (${d})`:"";return`${u} ${i}: ${r}${v}${c}`}case"turn.started":return`Turn ${A(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,C(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${A(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${A(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=C(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),d=As(i.guardrail_applied,!1),u=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return u;const v=r&&l?`${r}->${l}`:l||r;return`${u} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Mr(s);return i?`${t}: ${i}`:t}}}function jr(t,e){const n=C(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(C(n.payload)?n.payload.actor_name:"",""),r=C(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),u=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:u||Er(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:Or(s,a,i,r),dice_roll:Pr(s,r),timestamp:l}}function Fr(t,e,n){var Q,dt;const s=_(t.room_id,"")||n||"default",a=C(t.state)?t.state:{},i=C(a.party)?a.party:{},r=C(a.actor_control)?a.actor_control:{},l=C(a.join_gate)?a.join_gate:{},d=C(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([L,z])=>{const h=C(z)?z:{},He=J(h,"max_hp",void 0,10),da=J(h,"hp",void 0,He),fo=J(h,"max_mp",void 0,0),_o=J(h,"mp",void 0,0),go=J(h,"level",void 0,1),$o=J(h,"xp",void 0,0),ho=As(h.alive,da>0),pa=r[L],va=typeof pa=="string"?pa:void 0,yo=Lr(h.role,L,va),bo=ht(h.generation),xo=K(h.joined_at,h.joinedAt,h.started_at,h.startedAt),ko=K(h.claimed_at,h.claimedAt,h.assigned_at,h.assignedAt,h.assigned_time),wo=K(h.last_seen,h.lastSeen,h.last_seen_at,h.lastSeenAt,h.last_active,h.lastActive),So=K(h.scene,h.current_scene,h.currentScene,h.world_scene,h.scene_name,h.sceneName),Ao=K(h.location,h.current_location,h.currentLocation,h.position,h.zone,h.area);return{id:L,name:_(h.name,L),role:yo,keeper:va,archetype:_(h.archetype,""),persona:_(h.persona,""),portrait:_(h.portrait,"")||void 0,background:_(h.background,"")||void 0,traits:ne(h.traits),skills:ne(h.skills),stats_raw:Dr(h),status:ho?"active":"dead",generation:bo,joined_at:xo||void 0,claimed_at:ko||void 0,last_seen:wo||void 0,scene:So||void 0,location:Ao||void 0,inventory:ne(h.inventory),notes:ne(h.notes),relationships:Rr(h.relationships),stats:{hp:da,max_hp:He,mp:_o,max_mp:fo,level:go,xp:$o,strength:J(h,"strength","str",10),dexterity:J(h,"dexterity","dex",10),constitution:J(h,"constitution","con",10),intelligence:J(h,"intelligence","int",10),wisdom:J(h,"wisdom","wis",10),charisma:J(h,"charisma","cha",10)}}}),v=u.filter(L=>L.status!=="dead"),c=Tr(t,e),p={phase_open:As(l.phase_open,!0),min_points:A(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},m=Object.entries(d).map(([L,z])=>{const h=C(z)?z:{};return{actor_id:L,score:A(h.score,0),last_reason:_(h.last_reason,"")||null,reasons:ne(h.reasons)}}),g=u.reduce((L,z)=>(L[z.id]=z.name,L),{}),$=e.map(L=>jr(L,g)),k=A(a.turn,1),T=_(a.phase,"round"),N=_(a.map,""),O=C(a.world)?a.world:{},H=N||_(O.ascii_map,_(O.map,"")),D=$.filter((L,z)=>{const h=e[z];if(!C(h))return!1;const He=C(h.payload)?h.payload:{};return A(He.turn,-1)===k}),X=(D.length>0?D:$).slice(-12),St=_(a.status,"active");return{session:{id:s,room:s,status:St==="ended"?"ended":St==="paused"?"paused":"active",round:k,actors:v,created_at:((Q=$[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:T,events:X,timestamp:((dt=$[$.length-1])==null?void 0:dt.timestamp)??new Date().toISOString()},map:H||void 0,join_gate:p,contribution_ledger:m,outcome:c,party:v,story_log:$,history:[]}}async function zr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ft(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ur(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ft(`/api/v1/trpg/state${e}`),zr(t)]);return Fr(n,s,t)}function Hr(t){return _t("/api/v1/trpg/rounds/run",{room_id:t})}function Kr(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Br(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),_t("/api/v1/trpg/dice/roll",e)}function qr(t,e){const n=Kr();return _t("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Gr(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),_t("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Wr(t,e,n){return _t("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Jr(t,e,n){const s=await B("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Vr(t){const e=await B("trpg.mid_join.request",t);return JSON.parse(e)}async function Ui(t,e){await B("masc_broadcast",{agent_name:t,message:e})}async function Yr(t,e,n=1){await B("masc_add_task",{title:t,description:e,priority:n})}async function Xr(t){return B("masc_join",{agent_name:t})}async function Hi(t){await B("masc_leave",{agent_name:t})}async function Qr(t){await B("masc_heartbeat",{agent_name:t})}async function Zr(t=40){return(await B("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function tl(t,e=20){return B("masc_task_history",{task_id:t,limit:e})}async function el(){return Fe("fetchDebates",async()=>{const t=await ft("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!C(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:A(e.argument_count,0),created_at:Xt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function nl(){return Fe("fetchCouncilSessions",async()=>{const t=await ft("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!C(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:A(e.votes,0),quorum:A(e.quorum,0),state:_(e.state,"open"),created_at:Xt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function sl(t){const e=await B("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function al(t){return Fe("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ft(`/api/v1/council/debates/${e}/summary`);if(!C(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:A(n.support_count,0),oppose_count:A(n.oppose_count,0),neutral_count:A(n.neutral_count,0),total_arguments:A(n.total_arguments,0),created_at:Xt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function il(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function ol(t){return C(t)?{iteration:ht(t.iteration)??0,metric_before:A(t.metric_before,0),metric_after:A(t.metric_after,0),delta:A(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:ht(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function rl(t){if(!C(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(ol).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:il(t.status),current_iteration:ht(t.iteration)??ht(t.current_iteration)??0,max_iterations:ht(t.max_iterations)??0,baseline_metric:A(t.baseline_metric,0),current_metric:A(t.current_metric,A(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:ht(t.stagnation_streak)??0,stagnation_limit:ht(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds,0),history:n}}function Da(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function ll(){try{const t=await B("masc_mdal_status",{}),e=JSON.parse(t),n=C(e)?_(e.error,"").trim():"";if(Da(n))return{state:"idle"};if(n)return{state:"error",message:n};const s=rl(e);return s?{state:"ready",loop:s}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return Da(e)?{state:"idle"}:{state:"error",message:e}}}async function cl(){try{const t=await B("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Dt=f([]),gt=f([]),ze=f([]),ut=f([]),Pt=f(null),ie=f(null),Cs=f(new Map),Mt=f([]),Te=f("hot"),Nt=f(!0),Ki=f(null),vt=f(""),Re=f([]),Kt=f(!1),et=f(new Map),an=f("unknown"),Ns=f(null),Ts=f(!1),Le=f(!1),Rs=f(!1),Bt=f(!1),ul=f(null),Ls=f(null),Bi=f(null),qi=f(null),Gi=W(()=>Dt.value.filter(t=>t.status==="active"||t.status==="idle")),sa=W(()=>{const t=gt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function dl(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const pl=W(()=>{const t=new Map;for(const e of ut.value)t.set(e.name,dl(e));return t}),vl=12e4,ml=W(()=>{const t=Date.now(),e=new Set,n=Cs.value;for(const s of ut.value){const a=n.get(s.name);a!=null&&t-a>vl&&e.add(s.name)}return e}),fn={},fl=5e3;function Is(){delete fn.compact,delete fn.full}function nt(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function le(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Wi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function _l(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function gl(t){if(!nt(t))return null;const e=x(t.name);return e?{name:e,status:Wi(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:le(t.traits),interests:le(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function $l(t){if(!nt(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:_l(t.status),priority:S(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function hl(t){if(!nt(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",s=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:S(t.seq),from:e,content:n,timestamp:s,type:x(t.type)}}function yl(t){return Array.isArray(t)?t.map(e=>{if(!nt(e))return null;const n=S(e.ts_unix);if(n==null)return null;const s=nt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?S(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function bl(t){return(Array.isArray(t)?t:nt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!nt(n))return null;const s=nt(n.agent)?n.agent:null,a=nt(n.context)?n.context:null,i=nt(n.metrics_window)?n.metrics_window:void 0,r=x(n.name);if(!r)return null;const l=S(n.context_ratio)??S(a==null?void 0:a.context_ratio),d=x(n.status)??x(s==null?void 0:s.status)??"offline",u=Wi(d),v=x(n.model)??x(n.active_model)??x(n.primary_model),c=le(n.skill_secondary),p=a?{source:x(a.source),context_ratio:S(a.context_ratio),context_tokens:S(a.context_tokens),context_max:S(a.context_max),message_count:S(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:x(s.name),status:x(s.status),current_task:x(s.current_task)??null,last_seen:x(s.last_seen)}:void 0,g=yl(n.metrics_series);return{name:r,emoji:x(n.emoji),koreanName:x(n.koreanName)??x(n.korean_name),agent_name:x(n.agent_name),trace_id:x(n.trace_id),model:v,primary_model:x(n.primary_model),active_model:x(n.active_model),next_model_hint:x(n.next_model_hint)??null,status:u,last_heartbeat:x(n.last_heartbeat)??x(s==null?void 0:s.last_seen),generation:S(n.generation),turn_count:S(n.turn_count)??S(n.total_turns),keeper_age_s:S(n.keeper_age_s),last_turn_ago_s:S(n.last_turn_ago_s),last_handoff_ago_s:S(n.last_handoff_ago_s),last_compaction_ago_s:S(n.last_compaction_ago_s),last_proactive_ago_s:S(n.last_proactive_ago_s),context_ratio:l,context_tokens:S(n.context_tokens)??S(a==null?void 0:a.context_tokens),context_max:S(n.context_max)??S(a==null?void 0:a.context_max),context_source:x(n.context_source)??x(a==null?void 0:a.source),context:p,traits:le(n.traits),interests:le(n.interests),primaryValue:x(n.primaryValue)??x(n.primary_value),activityLevel:S(n.activityLevel)??S(n.activity_level),memory_recent_note:x(n.memory_recent_note)??null,conversation_tail_count:S(n.conversation_tail_count),k2k_count:S(n.k2k_count),handoff_count_total:S(n.handoff_count_total)??S(n.trace_history_count),compaction_count:S(n.compaction_count),last_compaction_saved_tokens:S(n.last_compaction_saved_tokens),skill_primary:x(n.skill_primary)??null,skill_secondary:c,skill_reason:x(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function jn(t="full"){var s,a,i;const e=Date.now(),n=fn[t];if(!(n&&e-n.time<fl)){Ts.value=!0;try{const r=await _r(t);fn[t]={data:r,time:e},Dt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(gl).filter(l=>l!==null),gt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map($l).filter(l=>l!==null),ze.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(hl).filter(l=>l!==null),ut.value=bl(r.keepers),Pt.value=nt(r.status)?r.status:null,ie.value=r.perpetual??null,ul.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Ts.value=!1}}}async function ct(){Le.value=!0;try{const t=await Sr(Te.value,{excludeSystem:Nt.value});Mt.value=t.posts??[],Ls.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Le.value=!1}}async function mt(){var t;Rs.value=!0;try{const e=vt.value||((t=Pt.value)==null?void 0:t.room)||"default";vt.value||(vt.value=e);const n=await Ur(e);Ki.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Rs.value=!1}}async function ce(){Kt.value=!0;try{const t=await cl();Re.value=Array.isArray(t)?t:[],Bi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Kt.value=!1}}async function ue(){const t=++qn;Bt.value=!0;try{const e=await ll();if(t!==qn)return;if(e.state==="error"){an.value="error",Ns.value=e.message;return}if(qi.value=new Date().toISOString(),Ns.value=null,e.state==="idle"){an.value="idle";const i=new Map(et.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});et.value=i;return}const n=e.loop;an.value="ready";const s=new Map(et.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),et.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===qn&&(Bt.value=!1)}}let Kn=null,Bn=null,qn=0;function xl(){return Ii.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Cs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Cs.value=n}if(Is(),Kn||(Kn=setTimeout(()=>{jn(),Kn=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Bn||(Bn=setTimeout(()=>{ct(),Bn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Is(),e.type==="mdal_started"&&e.loop_id){const n=new Map(et.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),et.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(et.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),et.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(et.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),et.value=n}}})}let de=null;function kl(){de||(de=setInterval(()=>{Is(),jn()},1e4))}function wl(){de&&(clearInterval(de),de=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function it({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Sl(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function E({timestamp:t}){const e=Sl(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function jt(t){return(t??"").trim().toLowerCase()}function V(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function on(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Ge(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function se(t){return t.last_heartbeat??Ge(t.last_turn_ago_s)??Ge(t.last_proactive_ago_s)??Ge(t.last_handoff_ago_s)??Ge(t.last_compaction_ago_s)}function Al(t){const e=t.title.trim();return e||on(t.content)}function Cl(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function aa(t,e,n,s,a={}){const i=jt(t),r=e.filter($=>jt($.assignee)===i&&($.status==="claimed"||$.status==="in_progress")).length,l=n.filter($=>jt($.from)===i).sort(($,k)=>V(k.timestamp)-V($.timestamp))[0],d=s.filter($=>jt($.agent)===i).sort(($,k)=>V(k.timestamp)-V($.timestamp))[0],u=(a.boardPosts??[]).filter($=>jt($.author)===i).sort(($,k)=>V(k.updated_at||k.created_at)-V($.updated_at||$.created_at))[0],v=(a.keepers??[]).filter($=>jt($.name)===i&&se($)!==null).sort(($,k)=>V(se(k)??0)-V(se($)??0))[0],c=l?V(l.timestamp):0,p=d?V(d.timestamp):0,m=u?V(u.updated_at||u.created_at):0,g=v?V(se(v)??0):0;return c===0&&p===0&&m===0&&g===0?{activeAssignedCount:r,lastActivityAt:null,lastActivityText:r>0?`${r} claimed tasks`:null}:c>=p&&l?{activeAssignedCount:r,lastActivityAt:l.timestamp,lastActivityText:on(l.content)}:m>=p&&m>=g&&u?{activeAssignedCount:r,lastActivityAt:u.updated_at||u.created_at,lastActivityText:`Post: ${on(Al(u))}`}:g>=p&&v?{activeAssignedCount:r,lastActivityAt:se(v),lastActivityText:Cl(v)}:{activeAssignedCount:r,lastActivityAt:d?new Date(d.timestamp).toISOString():null,lastActivityText:d?on(d.text):null}}const ia=f(null);function Ji(t){ia.value=t}function Pa(){ia.value=null}const zt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Nl(t){if(!t)return 0;const e=zt.findIndex(n=>n.level===t);return e>=0?e:0}function Tl({keeper:t}){const e=Nl(t.autonomy_level),n=zt[e]??zt[0];if(!n)return null;const s=(e+1)/zt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${zt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${zt.map((a,i)=>o`
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
            <strong><${E} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function rn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Rl({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${rn(t.context_tokens)}</div>
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
  `}function Ll({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,m)=>{const g=a+m/(i-1)*(n-2*a),$=s-a-(p.context_ratio??0)*(s-2*a);return{x:g,y:$,p}}),l=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:m})=>o`
          <circle cx="${p.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Gn=f("");function Il({keeper:t}){var a,i,r,l;const e=Gn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Gn.value}
        onInput=${d=>{Gn.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${rn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${rn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${rn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Dl({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Pl({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Ml({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ma({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Wn(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function El({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Wn(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Wn(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Wn(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Ol({keeperName:t}){const[e,n]=Be("Loading internal monologue..."),[s,a]=Be(""),[i,r]=Be([]),[l,d]=Be(!1),u=async()=>{try{const c=await B("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};xt(()=>{u()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const c=s;a(""),r(p=>[...p,{role:"You",text:c}]);try{const p=await B("masc_keeper_msg",{name:t,message:c});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(c=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${c.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${c.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${c.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${c.role}</strong>
                <span style="white-space: pre-wrap;">${c.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${c=>a(c.currentTarget.value)} 
              onKeyDown=${c=>c.key==="Enter"&&!c.shiftKey&&v()}
              placeholder="Ping the agent..."
              disabled=${l}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${v} 
              disabled=${l||!s.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${l?.5:1};"
            >
              ${l?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function jl(){var e,n,s;const t=ia.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Pa()}}
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
            <${it} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Pa()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Rl} keeper=${t} />

        ${""}
        <${Ll} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${Il} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${Ma} traits=${t.traits??[]} label="Traits" />
            <${Ma} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${E} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${y} title="Autonomy">
                <${Tl} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${Dl} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${Pl} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${Ml} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${El} keeper=${t} />
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
        <${Ol} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Fl=0;const Tt=f([]);function b(t,e="success",n=4e3){const s=++Fl;Tt.value=[...Tt.value,{id:s,message:t,type:e}],setTimeout(()=>{Tt.value=Tt.value.filter(a=>a.id!==s)},n)}function zl(t){Tt.value=Tt.value.filter(e=>e.id!==t)}function Ul(){const t=Tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>zl(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Hl="masc_dashboard_agent_name",ee=f(null),_n=f(!1),Ie=f(""),gn=f([]),De=f([]),Wt=f(""),pe=f(!1);function Vi(t){ee.value=t,oa()}function Ea(){ee.value=null,Ie.value="",gn.value=[],De.value=[],Wt.value=""}function Kl(){const t=ee.value;return t?Dt.value.find(e=>e.name===t)??null:null}function Yi(t){return t?gt.value.filter(e=>e.assignee===t):[]}async function oa(){const t=ee.value;if(t){_n.value=!0,Ie.value="",gn.value=[],De.value=[];try{const e=await Zr(80);gn.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Yi(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await tl(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));De.value=s}catch(e){Ie.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{_n.value=!1}}}async function Oa(){var s;const t=ee.value,e=Wt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Hl))==null?void 0:s.trim())||"dashboard";pe.value=!0;try{await Ui(n,`@${t} ${e}`),Wt.value="",b(`Mention sent to ${t}`,"success"),oa()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";b(i,"error")}finally{pe.value=!1}}function Bl({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${it} status=${t.status} />
    </div>
  `}function ql({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Gl(){var a,i,r,l;const t=ee.value;if(!t)return null;const e=Kl(),n=Yi(t),s=gn.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ea()}}
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
                        <${it} status=${e.status} />
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
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${E} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{oa()}} disabled=${_n.value}>
              ${_n.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ea}>Close</button>
          </div>
        </div>

        ${Ie.value?o`<div class="council-error">${Ie.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Bl} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${De.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${De.value.map(d=>o`<${ql} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Wt.value}
              onInput=${d=>{Wt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Oa()}}
              disabled=${pe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Oa()}}
              disabled=${pe.value||Wt.value.trim()===""}
            >
              ${pe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Ft({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Wl({agent:t}){const e=aa(t.name,gt.value,ze.value,Yt.value,{boardPosts:Mt.value,keepers:ut.value});return o`
    <div class="agent" onClick=${()=>Vi(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${it} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
      ${!t.current_task&&e.activeAssignedCount>0?o`<span class="agent-task">${e.activeAssignedCount} claimed</span>`:null}
      ${e.lastActivityText?o`
            <span class="agent-activity-meta">
              ${e.lastActivityAt?o`<${E} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </span>
          `:null}
    </div>
  `}function Jl(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function ja(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Vl({keeper:t}){var r;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=pl.value.get(t.name),a=ml.value.has(t.name),i=((r=t.agent)==null?void 0:r.current_task)??"No current task";return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Ji(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${it} status=${t.status} />
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
              <div class="keeper-ctx-fill ${ja(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${ja(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Jl(t.context_tokens)})`:null}
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
          </div>
        `:null}

        <div class="keeper-focus-row">${i}</div>

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${E} timestamp=${t.last_heartbeat} />
          </div>
        `:null}
      </div>
    </div>
  `}function Fa(){var r,l,d,u,v;const t=Pt.value,e=Dt.value,n=ut.value,s=sa.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${Ft} label="Agents" value=${e.length} />
      <${Ft} label="Active" value=${Gi.value.length} color="#4ade80" />
      <${Ft} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Ft} label="Tasks" value=${gt.value.length} />
      <${Ft} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${Ft} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ua(a==null?void 0:a.alert_level)}`}>
                ${za(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${We(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${We(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ua(i==null?void 0:i.alert_level)}`}>
                ${za(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${We(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${We(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(c=>o`<${Wl} key=${c.name} agent=${c} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(c=>o`<${Vl} key=${c.name} keeper=${c} />`)}
        </div>
      <//>
    </div>

    ${ie.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${ie.value.running?"Running":"Stopped"}</span>
            ${ie.value.goal?o`<span>Goal: ${ie.value.goal}</span>`:null}
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
            <span>Uptime: ${Yl(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${E} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function Yl(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function We(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function za(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ua(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Ue=f(null),$n=f(!1),wt=f(null),P=f(!1),hn=f([]);let Xl=1;function M(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function w(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Xi(t){return typeof t=="boolean"?t:void 0}function Ql(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ut(t,e=[]){if(Array.isArray(t))return t;if(!M(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Zl(t){return M(t)?{id:w(t.id),seq:G(t.seq),from:w(t.from)??w(t.from_agent)??"system",content:w(t.content)??"",timestamp:w(t.timestamp)??new Date().toISOString(),type:w(t.type)}:null}function tc(t){return M(t)?{room_id:w(t.room_id),current_room:w(t.current_room)??w(t.room),project:w(t.project),cluster:w(t.cluster),paused:Xi(t.paused),pause_reason:w(t.pause_reason)??null,paused_by:w(t.paused_by)??null,paused_at:w(t.paused_at)??null}:{}}function Ha(t){if(!M(t))return;const e=Object.entries(t).map(([n,s])=>{const a=w(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function ec(t){if(!M(t))return null;const e=M(t.status)?t.status:void 0,n=M(t.summary)?t.summary:M(e==null?void 0:e.summary)?e.summary:void 0,s=M(t.session)?t.session:M(e==null?void 0:e.session)?e.session:void 0,a=w(t.session_id)??w(n==null?void 0:n.session_id)??w(s==null?void 0:s.session_id);if(!a)return null;const i=Ha(t.report_paths)??Ha(e==null?void 0:e.report_paths),r=Ut(t.recent_events,["events"]).filter(M);return{session_id:a,status:w(t.status)??w(n==null?void 0:n.status)??w(s==null?void 0:s.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:M(t.team_health)?t.team_health:M(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:M(t.communication_metrics)?t.communication_metrics:M(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:M(t.orchestration_state)?t.orchestration_state:M(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:M(t.cascade_metrics)?t.cascade_metrics:M(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function nc(t){if(!M(t))return null;const e=w(t.name);if(!e)return null;const n=M(t.context)?t.context:void 0;return{name:e,agent_name:w(t.agent_name),status:w(t.status),autonomy_level:w(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:Ql(t.active_goal_ids),last_autonomous_action_at:w(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:w(t.model)??w(t.active_model)??w(t.primary_model)}}function sc(t){if(!M(t))return null;const e=w(t.confirm_token)??w(t.token);return e?{confirm_token:e,actor:w(t.actor),action_type:w(t.action_type),target_type:w(t.target_type),target_id:w(t.target_id)??null,delegated_tool:w(t.delegated_tool),created_at:w(t.created_at),preview:t.preview}:null}function ac(t){const e=M(t)?t:{};return{room:tc(e.room),sessions:Ut(e.sessions,["items","sessions"]).map(ec).filter(n=>n!==null),keepers:Ut(e.keepers,["items","keepers"]).map(nc).filter(n=>n!==null),recent_messages:Ut(e.recent_messages,["messages"]).map(Zl).filter(n=>n!==null),pending_confirms:Ut(e.pending_confirms,["items","confirms"]).map(sc).filter(n=>n!==null),available_actions:Ut(e.available_actions,["actions"]).filter(M).map(n=>({action_type:w(n.action_type)??"unknown",target_type:w(n.target_type)??"unknown",description:w(n.description),confirm_required:Xi(n.confirm_required)}))}}function Je(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ka(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function yn(t){hn.value=[{...t,id:Xl++,at:new Date().toISOString()},...hn.value].slice(0,20)}function Qi(t){return t.confirm_required?Je(t.preview)||"Confirmation required":Je(t.result)||Je(t.executed_action)||Je(t.delegated_tool_result)||t.status}async function Qt(){$n.value=!0,wt.value=null;try{const t=await gr();Ue.value=ac(t)}catch(t){wt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{$n.value=!1}}async function ic(t){P.value=!0,wt.value=null;try{const e=await $r(t);return yn({actor:t.actor,action_type:t.action_type,target_label:Ka(t),outcome:e.confirm_required?"preview":"executed",message:Qi(e),delegated_tool:e.delegated_tool}),await Qt(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw wt.value=n,yn({actor:t.actor,action_type:t.action_type,target_label:Ka(t),outcome:"error",message:n}),e}finally{P.value=!1}}async function oc(t,e){P.value=!0,wt.value=null;try{const n=await hr(t,e);return yn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Qi(n),delegated_tool:n.delegated_tool}),await Qt(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw wt.value=s,yn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{P.value=!1}}const Zi="masc_dashboard_agent_name";function rc(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Zi))==null?void 0:s.trim())||"dashboard"}const Fn=f(rc()),ve=f(""),Ds=f("Operator pause"),me=f(""),bn=f(""),Ps=f("2"),xn=f(""),Jt=f("note"),kn=f(""),wn=f(""),Sn=f(""),Ms=f("2"),Es=f("Operator stop request"),Os=f(""),fe=f("");function lc(t){const e=t.trim()||"dashboard";Fn.value=e,localStorage.setItem(Zi,e)}function Ba(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function cc(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function Et(t){const e=Fn.value.trim()||"dashboard";try{const n=await ic({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?b("Confirmation queued","warning"):b(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return b(s,"error"),null}}async function qa(){const t=ve.value.trim();if(!t)return;await Et({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(ve.value="")}async function uc(){await Et({action_type:"room_pause",target_type:"room",payload:{reason:Ds.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function dc(){await Et({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function pc(){const t=me.value.trim();if(!t)return;await Et({action_type:"task_inject",target_type:"room",payload:{title:t,description:bn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ps.value,10)||2},successMessage:"Task injection submitted"})&&(me.value="",bn.value="")}async function vc(){var i;const t=Ue.value,e=xn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){b("Select a team session first","warning");return}const n={turn_kind:Jt.value},s=kn.value.trim();s&&(n.message=s),Jt.value==="task"&&(n.task_title=wn.value.trim()||"Operator injected task",n.task_description=Sn.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ms.value,10)||2),await Et({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(kn.value="",Jt.value==="task"&&(wn.value="",Sn.value=""))}async function mc(){var n;const t=Ue.value,e=xn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){b("Select a team session first","warning");return}await Et({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Es.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function fc(){var a;const t=Ue.value,e=Os.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=fe.value.trim();if(!e){b("Select a keeper first","warning");return}if(!n)return;await Et({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(fe.value="")}async function _c(t){const e=Fn.value.trim()||"dashboard";try{await oc(e,t),b("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";b(s,"error")}}function gc(){var d;xt(()=>{Qt()},[]);const t=Ue.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(u=>u.session_id===xn.value)??n[0]??null,l=s.find(u=>u.name===Os.value)??s[0]??null;return o`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${Fn.value}
            onInput=${u=>lc(u.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Qt()}} disabled=${$n.value||P.value}>
            ${$n.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${wt.value?o`
        <section class="ops-banner error">${wt.value}</section>
      `:null}

      ${a.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <div class="ops-confirmation-list">
            ${a.map(u=>o`
              <article key=${u.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${u.action_type??"unknown"}</strong>
                  <span>${u.target_type??"target"}${u.target_id?`:${u.target_id}`:""}</span>
                  <span>${u.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${u.preview?o`<pre class="ops-code-block">${Ba(u.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{_c(u.confirm_token)}} disabled=${P.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${u.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
          <div class="ops-stat-grid">
            <div class="ops-stat">
              <span>Room</span>
              <strong>${e.current_room??e.room_id??"default"}</strong>
            </div>
            <div class="ops-stat">
              <span>Project</span>
              <strong>${e.project??"n/a"}</strong>
            </div>
            <div class="ops-stat">
              <span>Cluster</span>
              <strong>${e.cluster??"n/a"}</strong>
            </div>
            <div class="ops-stat ${e.paused?"warn":"ok"}">
              <span>Status</span>
              <strong>${e.paused?"Paused":"Running"}</strong>
            </div>
          </div>

          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${ve.value}
              onInput=${u=>{ve.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&qa()}}
              disabled=${P.value}
            />
            <button class="control-btn" onClick=${()=>{qa()}} disabled=${P.value||ve.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Ds.value}
              onInput=${u=>{Ds.value=u.target.value}}
              disabled=${P.value}
            />
            <button class="control-btn ghost" onClick=${()=>{uc()}} disabled=${P.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{dc()}} disabled=${P.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${me.value}
            onInput=${u=>{me.value=u.target.value}}
            disabled=${P.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${bn.value}
            onInput=${u=>{bn.value=u.target.value}}
            disabled=${P.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Ps.value}
              onChange=${u=>{Ps.value=u.target.value}}
              disabled=${P.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{pc()}} disabled=${P.value||me.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Recent Messages</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(u=>o`
                <article key=${u.seq??u.id??u.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${u.from}</strong>
                    <span>${u.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${u.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(u=>{var v;return o`
              <button
                key=${u.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===u.session_id?"active":""}"
                onClick=${()=>{xn.value=u.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.session_id}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(u.progress_pct??0)}%</span>
                  <span>${u.done_delta_total??0} done</span>
                  <span>${(v=u.team_health)!=null&&v.status?String(u.team_health.status):"health n/a"}</span>
                </div>
              </button>
            `})}
          </div>

          ${r?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?o`
                <pre class="ops-code-block compact">${Ba(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Jt.value}
              onChange=${u=>{Jt.value=u.target.value}}
              disabled=${P.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{vc()}} disabled=${P.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${kn.value}
            onInput=${u=>{kn.value=u.target.value}}
            disabled=${P.value||!r}
          ></textarea>
          ${Jt.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${wn.value}
              onInput=${u=>{wn.value=u.target.value}}
              disabled=${P.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${Sn.value}
              onInput=${u=>{Sn.value=u.target.value}}
              disabled=${P.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ms.value}
              onChange=${u=>{Ms.value=u.target.value}}
              disabled=${P.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${Es.value}
              onInput=${u=>{Es.value=u.target.value}}
              disabled=${P.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{mc()}} disabled=${P.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${s.length===0?o`<div class="ops-empty">No keepers available.</div>`:s.map(u=>o`
              <button
                key=${u.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===u.name?"active":""}"
                onClick=${()=>{Os.value=u.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.name}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${u.model??"model n/a"}</span>
                  <span>${typeof u.context_ratio=="number"?`${Math.round(u.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${cc(u.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${l?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${l.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                <span>Generation: ${l.generation??0}</span>
                <span>Goals: ${((d=l.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${fe.value}
            onInput=${u=>{fe.value=u.target.value}}
            disabled=${P.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{fc()}} disabled=${P.value||!l||fe.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${hn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:hn.value.map(u=>o`
            <article key=${u.id} class="ops-log-entry ${u.outcome}">
              <div class="ops-log-head">
                <strong>${u.action_type}</strong>
                <span>${u.target_label}</span>
                <span>${u.at}</span>
              </div>
              <div class="ops-log-body">${u.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const js=f([]),Fs=f([]),_e=f(""),An=f(!1),ge=f(!1),Pe=f(""),Cn=f(null),tt=f(null),zs=f(!1);async function Us(){An.value=!0,Pe.value="";try{const[t,e]=await Promise.all([el(),nl()]);js.value=t,Fs.value=e}catch(t){Pe.value=t instanceof Error?t.message:"Failed to load council data"}finally{An.value=!1}}async function Ga(){const t=_e.value.trim();if(t){ge.value=!0;try{const e=await sl(t);_e.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Us()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{ge.value=!1}}}async function $c(t){Cn.value=t,zs.value=!0,tt.value=null;try{tt.value=await al(t)}catch(e){Pe.value=e instanceof Error?e.message:"Failed to load debate status",tt.value=null}finally{zs.value=!1}}function hc({debate:t}){const e=Cn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>$c(t.id)}
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
  `}function yc({session:t}){return o`
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
  `}function bc(){var e;const t=(e=Pt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${E} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function xc(){var e,n;xt(()=>{Us()},[]);const t=((n=(e=Pt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${bc} />
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${_e.value}
            onInput=${s=>{_e.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&Ga()}}
            disabled=${ge.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ga}
            disabled=${ge.value||_e.value.trim()===""}
          >
            ${ge.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Us} disabled=${An.value}>
            ${An.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Pe.value?o`<div class="council-error">${Pe.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${js.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:js.value.map(s=>o`<${hc} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Fs.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Fs.value.map(s=>o`<${yc} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Cn.value?`Debate Detail (${Cn.value})`:"Debate Detail"} class="section">
        ${zs.value?o`<div class="loading-indicator">Loading debate detail...</div>`:tt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${tt.value.status}</span>
                  <span>Total arguments: ${tt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${tt.value.support_count}</span>
                  <span>Oppose: ${tt.value.oppose_count}</span>
                  <span>Neutral: ${tt.value.neutral_count}</span>
                </div>
                ${tt.value.summary_text?o`<pre class="council-detail">${tt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function kc({text:t}){if(!t)return null;const e=wc(t);return o`<div class="markdown-content">${e}</div>`}function wc(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Jn(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Jn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Jn(i.join(`
`))}</p>`)}return n}function Jn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const to=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ln=f(null),$e=f([]),Lt=f(!1),Rt=f(null),he=f("");function Sc(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Ac=f(Sc()),ye=f(!1);async function ra(t){Rt.value=t,ln.value=null,$e.value=[],Lt.value=!0;try{const e=await Ar(t);if(Rt.value!==t)return;ln.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},$e.value=e.comments??[]}catch{Rt.value===t&&(ln.value=null,$e.value=[])}finally{Rt.value===t&&(Lt.value=!1)}}async function Wa(t){const e=he.value.trim();if(e){ye.value=!0;try{await Cr(t,Ac.value,e),he.value="",b("Comment posted","success"),await ra(t),ct()}catch{b("Failed to post comment","error")}finally{ye.value=!1}}}function Cc(){const t=Te.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${to.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Te.value=e.id,ct()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Nt.value?"is-active":""}"
          onClick=${()=>{Nt.value=!Nt.value,ct()}}
        >
          ${Nt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${ct} disabled=${Le.value}>
          ${Le.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Vn(){var e;const t=(e=Pt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${E} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function eo({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Nc(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Ja(t){return t.updated_at!==t.created_at}function Yn(){var n;const t=((n=to.find(s=>s.id===Te.value))==null?void 0:n.label)??Te.value,e=Mt.value.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Nt.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ls.value?o`<${E} timestamp=${Ls.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Tc({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await zi(t.id,n),ct()}catch{b("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Xo(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
          <div class="post-title-row">
            <div class="post-title">${t.title}</div>
            <div class="post-chip-row">
              <${eo} flair=${t.flair} />
              ${Ja(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${E} timestamp=${t.created_at} /></span>
            ${Ja(t)?o`<span>Updated <${E} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Nc(t.content)}</div>
      </div>
    </div>
  `}function Rc({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${E} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Lc({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${he.value}
        onInput=${e=>{he.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Wa(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${ye.value}
      />
      <button
        onClick=${()=>Wa(t)}
        disabled=${ye.value||he.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${ye.value?"...":"Post"}
      </button>
    </div>
  `}function Ic({post:t}){Rt.value!==t.id&&!Lt.value&&ra(t.id);const e=async n=>{try{await zi(t.id,n),ct()}catch{b("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>En("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${eo} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${kc} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${E} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${Lt.value?"...":$e.value.length})">
        ${Lt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Rc} comments=${$e.value} />`}
        <${Lc} postId=${t.id} />
      <//>
    </div>
  `}function Dc(){var a,i;const t=Mt.value,e=Le.value,n=at.value.postId,s=((i=(a=Pt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(Rt.value===n?ln.value:null);return!r&&Rt.value!==n&&!Lt.value&&ra(n),r?o`
          <${Vn} />
          <${Yn} />
          <${Ic} post=${r} />
        `:o`
          <div>
            <${Vn} />
            <${Yn} />
            <button class="back-btn" onClick=${()=>En("board")}>← Back to Board</button>
            ${Lt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Vn} />
    <${Yn} />
    <${Cc} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":Nt.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Tc} key=${r.id} post=${r} />`)}
          </div>`}
  `}const no=120,Pc=12,Mc=16,Ec=12,Hs=f("all"),Oc={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},jc={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Fc(t){if(t.kind)return t.kind;const e=t.text;return e==="New post"||e==="New comment"?"board":e.startsWith("Task:")?"tasks":e.startsWith("Heartbeat")||e.startsWith("Handoff")||e.startsWith("Compaction")||e.startsWith("Guardrail")?"keepers":"system"}function zc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Uc(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",kind:Fc(t),actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Hc(t,e){var a;const n=(a=t.assignee)==null?void 0:a.trim(),s=t.updated_at??t.created_at;return!n||!s?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:s}}function Kc(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Ve(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ks(t){return t.last_heartbeat??Ve(t.last_turn_ago_s)??Ve(t.last_proactive_ago_s)??Ve(t.last_handoff_ago_s)??Ve(t.last_compaction_ago_s)}function Bc(t,e){const n=Ks(t);if(!n)return null;const s=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${s}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${s}`,timestamp:n}}function ot(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Bs=W(()=>{const t=ze.value.map(zc),e=Yt.value.map(Uc),n=[...gt.value].sort((i,r)=>ot(r.updated_at??r.created_at??0)-ot(i.updated_at??i.created_at??0)).slice(0,Pc).map(Hc).filter(i=>i!==null),s=[...Mt.value].sort((i,r)=>ot(r.updated_at||r.created_at)-ot(i.updated_at||i.created_at)).slice(0,Mc).map(Kc),a=[...ut.value].sort((i,r)=>ot(Ks(r)??0)-ot(Ks(i)??0)).slice(0,Ec).map(Bc).filter(i=>i!==null);return[...t,...e,...n,...s,...a].sort((i,r)=>ot(r.timestamp)-ot(i.timestamp))}),qc=W(()=>{const t=Bs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Gc=W(()=>{const t=Hs.value;return(t==="all"?Bs.value:Bs.value.filter(n=>n.kind===t)).slice(0,no)}),Wc=W(()=>Dt.value.map(t=>({agent:t,motion:aa(t.name,gt.value,ze.value,Yt.value,{boardPosts:Mt.value,keepers:ut.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:ot(e.motion.lastActivityAt??0)-ot(t.motion.lastActivityAt??0)}));function Jc(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function ae({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Vc({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Jc(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${jc[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Yc(){const t=qc.value,e=Gc.value,n=e[0],s=Wc.value;return o`
    <div class="stats-grid">
      <${ae} label="Visible rows" value=${e.length} />
      <${ae} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${ae} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${ae} label="Board signals" value=${t.board} color="#fbbf24" />
      <${ae} label="SSE events" value=${On.value} color="#c084fc" />
    </div>

    <${y} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${Hs.value===a?"active":""}"
              onClick=${()=>{Hs.value=a}}
            >
              ${Oc[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${kt.value?"":"pill-stale"}">
            ${kt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${E} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${no} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(a=>o`<${Vc} key=${a.id} row=${a} />`)}
      </div>
    <//>

    <${y} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${E} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function so({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}function Xc({agent:t}){const e=aa(t.name,gt.value,ze.value,Yt.value,{boardPosts:Mt.value,keepers:ut.value});return o`
    <button class="agent-card ${t.status}" onClick=${()=>Vi(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${so} ratio=${t.context_ratio} />
        <${it} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:e.activeAssignedCount>0?o`<div class="agent-task">${e.activeAssignedCount} claimed tasks</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
      ${e.lastActivityText?o`
            <div class="agent-activity-meta">
              ${e.lastActivityAt?o`<${E} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </div>
          `:null}
    </button>
  `}function Qc(t){return typeof t.context_ratio!="number"||Number.isNaN(t.context_ratio)?"—":`${Math.round(t.context_ratio*100)}%`}function Zc(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??"No active focus"}function tu(t){return[`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`,`Compactions ${t.compaction_count??0}`].join(" · ")}function eu({keeper:t}){return o`
    <div class="live-agent keeper-card" onClick=${()=>Ji(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${so} ratio=${t.context_ratio} />
        <${it} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Context</span>
            <strong class="keeper-core-value">${Qc(t)}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Generation</span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Heartbeat</span>
            <strong class="keeper-core-value">
              ${t.last_heartbeat?o`<${E} timestamp=${t.last_heartbeat} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Model</span>
            <strong class="keeper-core-value">${t.model??"—"}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Focus</span>
            <strong class="keeper-core-value keeper-core-text">${Zc(t)}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Continuity</span>
            <strong class="keeper-core-value">${tu(t)}</strong>
          </div>
        </div>
      </div>
    </div>
  `}function nu(){const t=Dt.value,e=ut.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${eu} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Xc} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Xn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${E} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function su(){const{todo:t,inProgress:e,done:n}=sa.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Xn} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Xn} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Xn} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function au(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function Qn({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${au(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${E} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function iu(){const t=sa.value,e=t.inProgress,n=t.todo,s=t.done,a=Gi.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${Qn} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${Qn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${it} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${Qn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const Nn=f("all"),Tn=f("all"),qs=W(()=>{let t=Re.value;return Nn.value!=="all"&&(t=t.filter(e=>e.horizon===Nn.value)),Tn.value!=="all"&&(t=t.filter(e=>e.status===Tn.value)),t}),ou=W(()=>{const t={short:[],mid:[],long:[]};for(const e of qs.value){const n=t[e.horizon];n&&n.push(e)}return t}),ru=W(()=>{const t=Array.from(et.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function lu(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function la(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function cn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function cu(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Va(t){return t.toFixed(4)}function Ya(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function uu({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${cn(t.horizon)}">
            ${la(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${lu(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${E} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${it} status=${t.status} />
        <div class="goal-updated">
          <${E} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Xa({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${E} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Zn({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${y} title="${la(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${uu} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function du(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Nn.value===t?"active":""}"
            onClick=${()=>{Nn.value=t}}
          >
            ${t==="all"?"All":la(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Tn.value===t?"active":""}"
            onClick=${()=>{Tn.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function pu(){const t=Re.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${cn("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${cn("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${cn("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function vu({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${it} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Va(t.baseline_metric)}</span>
          <span>Current ${Va(t.current_metric)}</span>
          <span class=${Ya(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Ya(t)}
          </span>
          <span>Elapsed ${cu(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function mu(){xt(()=>{ce(),ue()},[]);const t=ou.value,e=ru.value,n=e.filter(r=>r.status==="running").length,s=Re.value.filter(r=>r.status==="active").length,a=an.value,i=a==="idle"?"No loop running":a==="error"?Ns.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${qs.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${y} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${ce} disabled=${Kt.value}>
              ${Kt.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${ue} disabled=${Bt.value}>
              ${Bt.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{ce(),ue()}}
              disabled=${Kt.value||Bt.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Xa} label="Goals" timestamp=${Bi.value} source="masc_goal_list" />
          <${Xa}
            label="MDAL loops"
            timestamp=${qi.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${y} title="Goal Pipeline" class="section">
        <${pu} />
        <${du} />
      <//>

      ${Kt.value&&Re.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:qs.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Zn} horizon="short" items=${t.short??[]} />
              <${Zn} horizon="mid" items=${t.mid??[]} />
              <${Zn} horizon="long" items=${t.long??[]} />
            `}

      <${y} title="MDAL Loops" class="section">
        ${Bt.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&a==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&a==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(r=>o`<${vu} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Ht=f(""),ts=f("ability_check"),es=f("10"),ns=f("12"),Ye=f(""),Xe=f("idle"),$t=f(""),Qe=f("keeper-late"),ss=f("player"),as=f(""),Y=f("idle"),is=f(null),Ze=f(""),os=f(""),rs=f("player"),ls=f(""),cs=f(""),us=f(""),be=f("20"),ds=f("20"),ps=f(""),tn=f("idle"),Gs=f(null),ao=f("overview"),vs=f("all"),ms=f("all"),fs=f("all"),fu=12e4,zn=f(null),Qa=f(Date.now());function _u(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function gu(t,e){return e>0?Math.round(t/e*100):0}const $u={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},hu={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function en(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function yu(t){const e=t.trim().toLowerCase();return $u[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function bu(t){const e=t.trim().toLowerCase();return hu[e]??"상황에 따라 선택되는 전술 액션입니다."}function bt(t){return typeof t=="object"&&t!==null}function q(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function rt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Me(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const xu=new Set(["str","dex","con","int","wis","cha"]);function ku(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!bt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function wu(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(be.value.trim(),10);Number.isFinite(s)&&s>n&&(be.value=String(n))}function Ws(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Su(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Au(t){ao.value=t}function io(t){const e=zn.value;return e==null||e<=t}function Cu(t){const e=zn.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Rn(){zn.value=null}function oo(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Nu(t,e){oo(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(zn.value=Date.now()+fu,b("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function un(t){return io(t)?(b("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Js(t,e,n){return oo([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tu({hp:t,max:e}){const n=gu(t,e),s=_u(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Ru({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Lu({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function ro({actor:t}){var d,u,v,c;const e=(d=t.archetype)==null?void 0:d.trim(),n=(u=t.persona)==null?void 0:u.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(c=t.background)==null?void 0:c.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([p,m])=>Number.isFinite(m)).filter(([p])=>!xu.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const m=p.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${it} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Lu} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Tu} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ru} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${en(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([p,m])=>o`
                <span class="trpg-custom-stat-chip">${en(p)} ${m}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(p=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${en(p)}</span>
                  <span class="trpg-annot-desc">${yu(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(p=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${en(p)}</span>
                  <span class="trpg-annot-desc">${bu(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Iu({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function lo({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Su(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ws(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${E} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Du({events:t}){const e="__none__",n=vs.value,s=ms.value,a=fs.value,i=Array.from(new Set(t.map(Ws).map(c=>c.trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),l=t.some(c=>(c.type??"").trim()===""),d=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),u=t.some(c=>(c.phase??"").trim()===""),v=t.filter(c=>{if(n!=="all"&&Ws(c)!==n)return!1;const p=(c.type??"").trim(),m=(c.phase??"").trim();if(s===e){if(p!=="")return!1}else if(s!=="all"&&p!==s)return!1;if(a===e){if(m!=="")return!1}else if(a!=="all"&&m!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{vs.value=c.target.value}}>
          <option value="all">all</option>
          ${i.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${c=>{ms.value=c.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${c=>{fs.value=c.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${d.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{vs.value="all",ms.value="all",fs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${lo} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Pu({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function co({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Mu({state:t,nowMs:e}){var u;const n=vt.value||((u=t.session)==null?void 0:u.room)||"",s=Xe.value,a=t.party??[];if(!a.find(v=>v.id===Ht.value)&&a.length>0){const v=a[0];v&&(Ht.value=v.id)}const r=async()=>{var c,p;if(!n){b("Room ID가 비어 있습니다.","error");return}if(!un(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Js("라운드 실행",n,v)){Xe.value="running";try{const m=await Hr(n);Gs.value=m,Xe.value="ok";const g=bt(m.summary)?m.summary:null,$=g?Me(g,"advanced",!1):!1,k=g?q(g,"progress_reason",""):"";b($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,$?"success":"warning"),mt()}catch(m){Gs.value=null,Xe.value="error";const g=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";b(g,"error")}finally{Rn()}}},l=async()=>{var c,p;if(!n||!un(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Js("턴 강제 진행",n,v))try{await qr(n),b("턴을 다음 단계로 이동했습니다.","success"),mt()}catch{b("턴 이동에 실패했습니다.","error")}finally{Rn()}},d=async()=>{if(!n||!un(e))return;const v=Ht.value.trim();if(!v){b("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(es.value,10),p=Number.parseInt(ns.value,10);if(Number.isNaN(c)||Number.isNaN(p)){b("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(Ye.value,10),g=Ye.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Br({roomId:n,actorId:v,action:ts.value.trim()||"ability_check",statValue:c,dc:p,rawD20:g}),b("주사위 판정을 기록했습니다.","success"),mt()}catch{b("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{vt.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ht.value}
            onChange=${v=>{Ht.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(v=>o`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ts.value}
              onInput=${v=>{ts.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${es.value}
              onInput=${v=>{es.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ns.value}
              onInput=${v=>{ns.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Ye.value}
              onInput=${v=>{Ye.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&d()}}
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
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Eu({state:t}){var a;const e=vt.value||((a=t.session)==null?void 0:a.room)||"",n=tn.value,s=async()=>{if(!e){b("Room ID가 비어 있습니다.","warning");return}const i=Ze.value.trim(),r=os.value.trim();if(!r&&!i){b("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(be.value.trim(),10),d=Number.parseInt(ds.value.trim(),10),u=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(l)?Math.max(0,Math.min(u,l)):u;let c={};try{c=ku(ps.value)}catch(p){b(p instanceof Error?p.message:"능력치 JSON 오류","error");return}tn.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Gr(e,{actor_id:i||void 0,name:r||void 0,role:rs.value,idempotencyKey:p,portrait:cs.value.trim()||void 0,background:us.value.trim()||void 0,hp:v,max_hp:u,alive:v>0,stats:Object.keys(c).length>0?c:void 0}),g=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const $=ls.value.trim();$&&await Wr(e,g,$),Ht.value=g,$t.value=g,i||(Ze.value=""),tn.value="ok",b(`Actor 생성 완료: ${g}`,"success"),await mt()}catch(p){tn.value="error",b(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${os.value}
            onInput=${i=>{os.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${rs.value}
            onChange=${i=>{rs.value=i.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${ls.value}
            onInput=${i=>{ls.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${s} disabled=${n==="spawning"}>
              ${n==="spawning"?"Spawning...":"Spawn Actor"}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${Ze.value}
              onInput=${i=>{Ze.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${cs.value}
              onInput=${i=>{cs.value=i.target.value}}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${be.value}
              onInput=${i=>{be.value=i.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${ds.value}
              onInput=${i=>{const r=i.target.value;ds.value=r,wu(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${us.value}
              onInput=${i=>{us.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ps.value}
              onInput=${i=>{ps.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Ou({state:t,nowMs:e}){var p;const n=vt.value||((p=t.session)==null?void 0:p.room)||"",s=t.join_gate,a=is.value,i=bt(a)?a:null,r=(t.party??[]).filter(m=>m.role!=="dm"),l=$t.value.trim(),d=r.some(m=>m.id===l),u=d?l:l?"__manual__":"",v=async()=>{const m=$t.value.trim(),g=Qe.value.trim();if(!n||!m){b("Room/Actor가 필요합니다.","warning");return}Y.value="checking";try{const $=await Jr(n,m,g||void 0);is.value=$,Y.value="ok",b("참가 가능 여부를 갱신했습니다.","success")}catch($){Y.value="error";const k=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";b(k,"error")}},c=async()=>{var T,N;const m=$t.value.trim(),g=Qe.value.trim(),$=as.value.trim();if(!n||!m||!g){b("Room/Actor/Keeper가 필요합니다.","warning");return}if(!un(e))return;const k=((T=t.current_round)==null?void 0:T.phase)??((N=t.session)==null?void 0:N.status)??"unknown";if(Js("Mid-Join 승인 요청",n,k)){Y.value="requesting";try{const O=await Vr({room_id:n,actor_id:m,keeper_name:g,role:ss.value,...$?{name:$}:{}});is.value=O;const H=bt(O)?Me(O,"granted",!1):!1,D=bt(O)?q(O,"reason_code",""):"";H?b("Mid-Join이 승인되었습니다.","success"):b(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),Y.value=H?"ok":"error",mt()}catch(O){Y.value="error";const H=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";b(H,"error")}finally{Rn()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${u}
            onChange=${m=>{const g=m.target.value;if(g==="__manual__"){(d||!l)&&($t.value="");return}$t.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${u==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${$t.value}
                onInput=${m=>{$t.value=m.target.value}}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `:null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${Qe.value}
            onInput=${m=>{Qe.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ss.value}
            onChange=${m=>{ss.value=m.target.value}}
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
            value=${as.value}
            onInput=${m=>{as.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${Y.value==="checking"||Y.value==="requesting"}>
              ${Y.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${Y.value==="checking"||Y.value==="requesting"}>
              ${Y.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Me(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${rt(i,"effective_score",0)}/${rt(i,"required_points",0)}</span>
            ${q(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${q(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function uo({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function po({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function vo(){const t=Gs.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=bt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(bt).slice(-8),i=t.canon_check,r=bt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],u=n?Me(n,"advanced",!1):!1,v=n?q(n,"progress_reason",""):"",c=n?q(n,"progress_detail",""):"",p=n?rt(n,"player_successes",0):0,m=n?rt(n,"player_required_successes",0):0,g=n?Me(n,"dm_success",!1):!1,$=n?rt(n,"timeouts",0):0,k=n?rt(n,"unavailable",0):0,T=n?rt(n,"reprompts",0):0,N=n?rt(n,"npc_attacks",0):0,O=n?rt(n,"keeper_timeout_sec",0):0,H=n?rt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${H}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const X=q(D,"status","unknown"),St=q(D,"actor_id","-"),At=q(D,"role","-"),Q=q(D,"reason",""),dt=q(D,"action_type",""),L=q(D,"reply","");return o`
                <div class="trpg-round-item ${X.includes("fallback")||X.includes("timeout")?"failed":"active"}">
                  <span>${St} (${At})</span>
                  <span style="margin-left:auto; font-size:11px;">${X}</span>
                  ${dt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${dt}</div>`:null}
                  ${Q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${L?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${L.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${q(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function ju({state:t,nowMs:e}){var r,l,d;const n=vt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=io(e),i=Cu(e);return o`
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
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Nu(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Rn(),b("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Fu({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Au(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function zu({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${lo} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${Iu} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${po} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${uo} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${ro} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${co} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Uu({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${Du} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${vo} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${po} state=${t} />
        <//>
      </div>
    </div>
  `}function Hu({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${ju} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${Mu} state=${t} nowMs=${e} />
          <//>

          <${y} title="Actor Spawn" style="margin-top:16px;">
            <${Eu} state=${t} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${Ou} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${vo} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${uo} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${ro} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${co} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Ku(){var l,d,u,v,c;const t=Ki.value,e=Rs.value;if(xt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{Qa.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>mt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=ao.value,r=Qa.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${vt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((u=t.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>mt()}>새로고침</button>
      </div>

      <${Pu} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((c=t.current_round)==null?void 0:c.round_number)??0}</div>
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

      <${Fu} active=${i} />

      ${i==="overview"?o`<${zu} state=${t} />`:i==="timeline"?o`<${Uu} state=${t} />`:o`<${Hu} state=${t} nowMs=${r} />`}
    </div>
  `}const ca="masc_dashboard_agent_name";function Bu(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ca);return e??n??"dashboard"}const st=f(Bu()),xe=f(""),ke=f(""),Ln=f(""),we=f(!1),qt=f(!1),Se=f(!1),Ae=f(!1),In=f(!1),Un=f(!1);function ua(t){const e=t.trim();st.value=e,e&&localStorage.setItem(ca,e)}function qu(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Vs(){const t=st.value.trim();if(t){Se.value=!0;try{const e=await Xr(t),n=qu(e);n&&ua(n),Un.value=!0,b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{Se.value=!1}}}async function Gu(){const t=st.value.trim();if(t){Ae.value=!0;try{await Hi(t),Un.value=!1,b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{Ae.value=!1}}}async function Wu(){const t=st.value.trim();if(t)try{await Hi(t)}catch{}localStorage.removeItem(ca),ua("dashboard"),Un.value=!1,await Vs()}async function Ju(){const t=st.value.trim();if(t){In.value=!0;try{await Qr(t),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{In.value=!1}}}async function Za(){const t=st.value.trim(),e=xe.value.trim();if(!(!t||!e)){we.value=!0;try{await Ui(t,e),xe.value="",b("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";b(s,"error")}finally{we.value=!1}}}async function Vu(){const t=ke.value.trim(),e=Ln.value.trim()||"Created from dashboard";if(t){qt.value=!0;try{await Yr(t,e,1),ke.value="",Ln.value="",b("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";b(s,"error")}finally{qt.value=!1}}}function Yu(){return xt(()=>{Vs()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${st.value}
        onInput=${t=>ua(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${xe.value}
          onInput=${t=>{xe.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Za()}}
          disabled=${we.value}
        />
        <button
          class="control-btn"
          onClick=${Za}
          disabled=${we.value||xe.value.trim()===""||st.value.trim()===""}
        >
          ${we.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Vs()}}
          disabled=${Se.value||st.value.trim()===""}
        >
          ${Se.value?"Joining...":Un.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Gu()}}
          disabled=${Ae.value||st.value.trim()===""}
        >
          ${Ae.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Wu()}}
          disabled=${Se.value||Ae.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ju()}}
          disabled=${In.value||st.value.trim()===""}
        >
          ${In.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${ke.value}
        onInput=${t=>{ke.value=t.target.value}}
        disabled=${qt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Ln.value}
        onInput=${t=>{Ln.value=t.target.value}}
        disabled=${qt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Vu}
        disabled=${qt.value||ke.value.trim()===""}
      >
        ${qt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}const mo={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Operational directory for agents and keepers",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function Xu(){const t=kt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${On.value} events</span>
    </div>
  `}function Qu(){const t=at.value.tab,e=kt.value,n=ws.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ws.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>En(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${mo[t]??"Live operational view"}</p>
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
            <strong>${Dt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${ut.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${gt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${On.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{jn(),t==="ops"&&Qt(),t==="board"&&ct(),t==="trpg"&&mt(),t==="goals"&&(ce(),ue())}}
        >
          Refresh Now
        </button>
      </section>

      <${Yu} />
    </aside>
  `}function Zu(){switch(at.value.tab){case"overview":return o`<${Fa} />`;case"ops":return o`<${gc} />`;case"council":return o`<${xc} />`;case"board":return o`<${Dc} />`;case"execution":return o`<${iu} />`;case"activity":return o`<${Yc} />`;case"agents":return o`<${nu} />`;case"tasks":return o`<${su} />`;case"goals":return o`<${mu} />`;case"trpg":return o`<${Ku} />`;default:return o`<${Fa} />`}}function td(){xt(()=>{Qo(),Pi(),jn(),ct();const e=xl();return kl(),()=>{or(),e(),wl()}},[]),xt(()=>{const e=at.value.tab;e==="ops"&&Qt(),e==="board"&&ct(),e==="trpg"&&mt(),e==="goals"&&(ce(),ue())},[at.value.tab]);const t=at.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${mo[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${Xu} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Zo} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Ts.value&&!kt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Zu} />`}
        </main>
        <${Qu} />
      </div>

      <${jl} />
      <${Gl} />
      <${Ul} />
    </div>
  `}const ti=document.getElementById("app");ti&&Po(o`<${td} />`,ti);
