var To=Object.defineProperty;var No=(t,e,n)=>e in t?To(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Pt=(t,e,n)=>No(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Rn,L,ni,si,At,ma,ai,ii,oi,Ws,ms,fs,Ce={},ri=[],Ro=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,In=Array.isArray;function lt(t,e){for(var n in e)t[n]=e[n];return t}function Js(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function li(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Rn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return tn(t,r,s,a,null)}function tn(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ni,__i:-1,__u:0};return a==null&&L.vnode!=null&&L.vnode(i),i}function Me(t){return t.children}function oe(t,e){this.props=t,this.context=e}function Wt(t,e){if(e==null)return t.__?Wt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Wt(t):null}function ci(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return ci(t)}}function fa(t){(!t.__d&&(t.__d=!0)&&At.push(t)&&!rn.__r++||ma!=L.debounceRendering)&&((ma=L.debounceRendering)||ai)(rn)}function rn(){for(var t,e,n,s,a,i,r,l=1;At.length;)At.length>l&&At.sort(ii),t=At.shift(),l=At.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=lt({},s)).__v=s.__v+1,L.vnode&&L.vnode(n),Vs(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??Wt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,pi(i,n,r),s.__e=s.__=null,n.__e!=a&&ci(n)));rn.__r=0}function ui(t,e,n,s,a,i,r,l,d,c,v){var u,p,m,g,k,C,N,T=s&&s.__k||ri,O=e.length;for(d=Io(n,e,T,d,O),u=0;u<O;u++)(m=n.__k[u])!=null&&(p=m.__i==-1?Ce:T[m.__i]||Ce,m.__i=u,C=Vs(t,m,p,a,i,r,l,d,c,v),g=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&Ys(p.ref,null,m),v.push(m.ref,m.__c||g,m)),k==null&&g!=null&&(k=g),(N=!!(4&m.__u))||p.__k===m.__k?d=di(m,d,t,N):typeof m.type=="function"&&C!==void 0?d=C:g&&(d=g.nextSibling),m.__u&=-7);return n.__e=k,d}function Io(t,e,n,s,a){var i,r,l,d,c,v=n.length,u=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=tn(null,r,null,null,null):In(r)?r=t.__k[i]=tn(Me,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=tn(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(c=r.__i=Lo(r,n,d,u))!=-1&&(u--,(l=n[c])&&(l.__u|=2)),l==null||l.__v==null?(c==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):c!=d&&(c==d-1?p--:c==d+1?p++:(c>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(u)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=Wt(l)),mi(l,l));return s}function di(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=di(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=Wt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Lo(t,e,n,s){var a,i,r,l=t.key,d=t.type,c=e[n],v=c!=null&&(2&c.__u)==0;if(c===null&&l==null||v&&l==c.key&&d==c.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((c=e[r=a>=0?a--:i++])!=null&&(2&c.__u)==0&&l==c.key&&d==c.type)return r}return-1}function _a(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Ro.test(e)?n:n+"px"}function Ke(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||_a(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||_a(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(oi,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Ws,t.addEventListener(e,i?fs:ms,i)):t.removeEventListener(e,i?fs:ms,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ga(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ws++;else if(e.t<n.u)return;return n(L.event?L.event(e):e)}}}function Vs(t,e,n,s,a,i,r,l,d,c){var v,u,p,m,g,k,C,N,T,O,U,D,Y,xt,wt,Q,rt,I=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=L.__b)&&v(e);t:if(typeof I=="function")try{if(N=e.props,T="prototype"in I&&I.prototype.render,O=(v=I.contextType)&&s[v.__c],U=v?O?O.props.value:v.__:s,n.__c?C=(u=e.__c=n.__c).__=u.__E:(T?e.__c=u=new I(N,U):(e.__c=u=new oe(N,U),u.constructor=I,u.render=Eo),O&&O.sub(u),u.state||(u.state={}),u.__n=s,p=u.__d=!0,u.__h=[],u._sb=[]),T&&u.__s==null&&(u.__s=u.state),T&&I.getDerivedStateFromProps!=null&&(u.__s==u.state&&(u.__s=lt({},u.__s)),lt(u.__s,I.getDerivedStateFromProps(N,u.__s))),m=u.props,g=u.state,u.__v=e,p)T&&I.getDerivedStateFromProps==null&&u.componentWillMount!=null&&u.componentWillMount(),T&&u.componentDidMount!=null&&u.__h.push(u.componentDidMount);else{if(T&&I.getDerivedStateFromProps==null&&N!==m&&u.componentWillReceiveProps!=null&&u.componentWillReceiveProps(N,U),e.__v==n.__v||!u.__e&&u.shouldComponentUpdate!=null&&u.shouldComponentUpdate(N,u.__s,U)===!1){for(e.__v!=n.__v&&(u.props=N,u.state=u.__s,u.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),D=0;D<u._sb.length;D++)u.__h.push(u._sb[D]);u._sb=[],u.__h.length&&r.push(u);break t}u.componentWillUpdate!=null&&u.componentWillUpdate(N,u.__s,U),T&&u.componentDidUpdate!=null&&u.__h.push(function(){u.componentDidUpdate(m,g,k)})}if(u.context=U,u.props=N,u.__P=t,u.__e=!1,Y=L.__r,xt=0,T){for(u.state=u.__s,u.__d=!1,Y&&Y(e),v=u.render(u.props,u.state,u.context),wt=0;wt<u._sb.length;wt++)u.__h.push(u._sb[wt]);u._sb=[]}else do u.__d=!1,Y&&Y(e),v=u.render(u.props,u.state,u.context),u.state=u.__s;while(u.__d&&++xt<25);u.state=u.__s,u.getChildContext!=null&&(s=lt(lt({},s),u.getChildContext())),T&&!p&&u.getSnapshotBeforeUpdate!=null&&(k=u.getSnapshotBeforeUpdate(m,g)),Q=v,v!=null&&v.type===Me&&v.key==null&&(Q=vi(v.props.children)),l=ui(t,In(Q)?Q:[Q],e,n,s,a,i,r,l,d,c),u.base=e.__e,e.__u&=-161,u.__h.length&&r.push(u),C&&(u.__E=u.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(rt=i.length;rt--;)Js(i[rt]);_s(e)}else e.__e=n.__e,e.__k=n.__k,z.then||_s(e);L.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Do(n.__e,e,n,s,a,i,r,d,c);return(v=L.diffed)&&v(e),128&e.__u?void 0:l}function _s(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(_s)}function pi(t,e,n){for(var s=0;s<n.length;s++)Ys(n[s],n[++s],n[++s]);L.__c&&L.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){L.__e(i,a.__v)}})}function vi(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:In(t)?t.map(vi):lt({},t)}function Do(t,e,n,s,a,i,r,l,d){var c,v,u,p,m,g,k,C=n.props||Ce,N=e.props,T=e.type;if(T=="svg"?a="http://www.w3.org/2000/svg":T=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((m=i[c])&&"setAttribute"in m==!!T&&(T?m.localName==T:m.nodeType==3)){t=m,i[c]=null;break}}if(t==null){if(T==null)return document.createTextNode(N);t=document.createElementNS(a,T,N.is&&N),l&&(L.__m&&L.__m(e,i),l=!1),i=null}if(T==null)C===N||l&&t.data==N||(t.data=N);else{if(i=i&&Rn.call(t.childNodes),!l&&i!=null)for(C={},c=0;c<t.attributes.length;c++)C[(m=t.attributes[c]).name]=m.value;for(c in C)if(m=C[c],c!="children"){if(c=="dangerouslySetInnerHTML")u=m;else if(!(c in N)){if(c=="value"&&"defaultValue"in N||c=="checked"&&"defaultChecked"in N)continue;Ke(t,c,null,m,a)}}for(c in N)m=N[c],c=="children"?p=m:c=="dangerouslySetInnerHTML"?v=m:c=="value"?g=m:c=="checked"?k=m:l&&typeof m!="function"||C[c]===m||Ke(t,c,m,C[c],a);if(v)l||u&&(v.__html==u.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(u&&(t.innerHTML=""),ui(e.type=="template"?t.content:t,In(p)?p:[p],e,n,s,T=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&Wt(n,0),l,d),i!=null)for(c=i.length;c--;)Js(i[c]);l||(c="value",T=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[c]||T=="progress"&&!g||T=="option"&&g!=C[c])&&Ke(t,c,g,C[c],a),c="checked",k!=null&&k!=t[c]&&Ke(t,c,k,C[c],a))}return t}function Ys(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){L.__e(a,n)}}function mi(t,e,n){var s,a;if(L.unmount&&L.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Ys(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){L.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&mi(s[a],e,n||typeof t.type!="function");n||Js(t.__e),t.__c=t.__=t.__e=void 0}function Eo(t,e,n){return this.constructor(t,n)}function Po(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),L.__&&L.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Vs(e,t=e.__k=li(Me,null,[t]),a||Ce,Ce,e.namespaceURI,a?null:e.firstChild?Rn.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),pi(i,t,r)}Rn=ri.slice,L={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},ni=0,si=function(t){return t!=null&&t.constructor===void 0},oe.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=lt({},this.state),typeof t=="function"&&(t=t(lt({},n),this.props)),t&&lt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),fa(this))},oe.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),fa(this))},oe.prototype.render=Me,At=[],ai=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,ii=function(t,e){return t.__v.__b-e.__v.__b},rn.__r=0,oi=/(PointerCapture)$|Capture$/i,Ws=0,ms=ga(!1),fs=ga(!0);var fi=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,fi(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},$a=new Map;function Mo(t){var e=$a.get(this);return e||(e=new Map,$a.set(this,e)),(e=fi(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],c=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&c(),c(v));for(var u=0;u<n[v].length;u++)s=n[v][u],i===1?s==="<"?(c(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(c(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][u+1]===">")?(c(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(c(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return c(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Mo.bind(li),Te,j,Fn,ha,gs=0,_i=[],F=L,ya=F.__b,ba=F.__r,ka=F.diffed,xa=F.__c,wa=F.unmount,Sa=F.__;function Qs(t,e){F.__h&&F.__h(j,t,gs||e),gs=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Be(t){return gs=1,Oo(hi,t)}function Oo(t,e,n){var s=Qs(Te++,2);if(s.t=t,!s.__c&&(s.__=[hi(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],c=s.t(d,l);d!==c&&(s.__N=[c,s.__[1]],s.__c.setState({}))}],s.__c=j,!j.__f)){var a=function(l,d,c){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,c);var u=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(u=!0)}}),i&&i.call(this,l,d,c)||u};j.__f=!0;var i=j.shouldComponentUpdate,r=j.componentWillUpdate;j.componentWillUpdate=function(l,d,c){if(this.__e){var v=i;i=void 0,a(l,d,c),i=v}r&&r.call(this,l,d,c)},j.shouldComponentUpdate=a}return s.__N||s.__}function ht(t,e){var n=Qs(Te++,3);!F.__s&&$i(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function gi(t,e){var n=Qs(Te++,7);return $i(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function jo(){for(var t;t=_i.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(en),t.__H.__h.forEach($s),t.__H.__h=[]}catch(e){t.__H.__h=[],F.__e(e,t.__v)}}F.__b=function(t){j=null,ya&&ya(t)},F.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Sa&&Sa(t,e)},F.__r=function(t){ba&&ba(t),Te=0;var e=(j=t.__c).__H;e&&(Fn===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(en),e.__h.forEach($s),e.__h=[],Te=0)),Fn=j},F.diffed=function(t){ka&&ka(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(_i.push(e)!==1&&ha===F.requestAnimationFrame||((ha=F.requestAnimationFrame)||Fo)(jo)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Fn=j=null},F.__c=function(t,e){e.some(function(n){try{n.__h.forEach(en),n.__h=n.__h.filter(function(s){return!s.__||$s(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],F.__e(s,n.__v)}}),xa&&xa(t,e)},F.unmount=function(t){wa&&wa(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{en(s)}catch(a){e=a}}),n.__H=void 0,e&&F.__e(e,n.__v))};var Aa=typeof requestAnimationFrame=="function";function Fo(t){var e,n=function(){clearTimeout(s),Aa&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Aa&&(e=requestAnimationFrame(n))}function en(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function $s(t){var e=j;t.__c=t.__(),j=e}function $i(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function hi(t,e){return typeof e=="function"?e(t):e}var zo=Symbol.for("preact-signals");function Ln(){if(gt>1)gt--;else{for(var t,e=!1;re!==void 0;){var n=re;for(re=void 0,hs++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ki(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(hs=0,gt--,e)throw t}}function Ho(t){if(gt>0)return t();gt++;try{return t()}finally{Ln()}}var R=void 0;function yi(t){var e=R;R=void 0;try{return t()}finally{R=e}}var re=void 0,gt=0,hs=0,ln=0;function bi(t){if(R!==void 0){var e=t.n;if(e===void 0||e.t!==R)return e={i:0,S:t,p:R.s,n:void 0,t:R,e:void 0,x:void 0,r:e},R.s!==void 0&&(R.s.n=e),R.s=e,t.n=e,32&R.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=R.s,e.n=void 0,R.s.n=e,R.s=e),e}}function H(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}H.prototype.brand=zo;H.prototype.h=function(){return!0};H.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:yi(function(){var s;(s=e.W)==null||s.call(e)}))};H.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&yi(function(){var a;(a=e.Z)==null||a.call(e)}))}};H.prototype.subscribe=function(t){var e=this;return Oe(function(){var n=e.value,s=R;R=void 0;try{t(n)}finally{R=s}},{name:"sub"})};H.prototype.valueOf=function(){return this.value};H.prototype.toString=function(){return this.value+""};H.prototype.toJSON=function(){return this.value};H.prototype.peek=function(){var t=R;R=void 0;try{return this.value}finally{R=t}};Object.defineProperty(H.prototype,"value",{get:function(){var t=bi(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(hs>100)throw new Error("Cycle detected");this.v=t,this.i++,ln++,gt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ln()}}}});function f(t,e){return new H(t,e)}function ki(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function xi(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function wi(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function It(t,e){H.call(this,void 0),this.x=t,this.s=void 0,this.g=ln-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}It.prototype=new H;It.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ln))return!0;if(this.g=ln,this.f|=1,this.i>0&&!ki(this))return this.f&=-2,!0;var t=R;try{xi(this),R=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return R=t,wi(this),this.f&=-2,!0};It.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}H.prototype.S.call(this,t)};It.prototype.U=function(t){if(this.t!==void 0&&(H.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};It.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(It.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=bi(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function W(t,e){return new It(t,e)}function Si(t){var e=t.u;if(t.u=void 0,typeof e=="function"){gt++;var n=R;R=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Xs(t),s}finally{R=n,Ln()}}}function Xs(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Si(t)}function Uo(t){if(R!==this)throw new Error("Out-of-order effect");wi(this),R=t,this.f&=-2,8&this.f&&Xs(this),Ln()}function Qt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Qt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Qt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Si(this),xi(this),gt++;var t=R;return R=this,Uo.bind(this,t)};Qt.prototype.N=function(){2&this.f||(this.f|=2,this.o=re,re=this)};Qt.prototype.d=function(){this.f|=8,1&this.f||Xs(this)};Qt.prototype.dispose=function(){this.d()};function Oe(t,e){var n=new Qt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Ai,qe,Ko=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ci=[];Oe(function(){Ai=this.N})();function Xt(t,e){L[t]=e.bind(null,L[t]||function(){})}function cn(t){if(qe){var e=qe;qe=void 0,e()}qe=t&&t.S()}function Ti(t){var e=this,n=t.data,s=qo(n);s.value=n;var a=gi(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var c=W(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),v=W(function(){return!Array.isArray(c.value)&&!si(c.value)}),u=Oe(function(){if(this.N=Ni,v.value){var m=c.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){u(),p.call(this)},[v,c]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Ti.displayName="ReactiveTextNode";Object.defineProperties(H.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ti},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Xt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof H&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});Xt("__r",function(t,e){if(t(e),e.type!==Me){cn();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Oe(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Ko&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),cn(n)}});Xt("__e",function(t,e,n,s){cn(),t(e,n,s)});Xt("diffed",function(t,e){cn();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var c=i[d],v=s[d];c===void 0?(c=Bo(n,d,v),i[d]=c):c.o(v,a)}for(var u in s)a[u]=s[u]}}t(e)});function Bo(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:Oe(function(){this.N=Ni;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}Xt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});Xt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});oe.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function qo(t,e){return gi(function(){return f(t,e)},[])}var Go=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Wo(){Ho(function(){for(var t;t=Ci.shift();)Ai.call(t)})}function Ni(){Ci.push(this)===1&&(L.requestAnimationFrame||Go)(Wo)}const Jo=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],Ri={tab:"overview",params:{},postId:null},Vo={journal:"activity",mdal:"goals"};function Ca(t){return!!t&&Jo.includes(t)}function Ta(t){if(t)return Vo[t]??t}function ys(t){try{return decodeURIComponent(t)}catch{return t}}function bs(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Yo(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ii(t,e){const n=Ta(t[0]),s=Ta(e.tab),a=Ca(n)?n:Ca(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=ys(t[2]):t[0]==="post"&&t[1]&&(i=ys(t[1]))),{tab:a,params:e,postId:i}}function un(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ri;const n=ys(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=bs(a),r=Yo(s);return Ii(r,i)}function Qo(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ri,params:bs(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=bs(e.replace(/^\?/,""));return Ii(s,a)}function Li(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const st=f(un(window.location.hash));window.addEventListener("hashchange",()=>{st.value=un(window.location.hash)});function Dn(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Li(n)}function Xo(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Zo(){if(window.location.hash&&window.location.hash!=="#"){st.value=un(window.location.hash);return}const t=Qo(window.location.pathname,window.location.search);if(t){st.value=t;const e=Li(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",st.value=un(window.location.hash)}const ks=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function tr(){const t=st.value.tab;return o`
    <div class="main-tab-bar">
      ${ks.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Dn(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Na="masc_dashboard_sse_session_id",er=1e3,nr=15e3,yt=f(!1),En=f(0),Di=f(null),Jt=f([]);function sr(){let t=sessionStorage.getItem(Na);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Na,t)),t}const ar=200;function ir(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Jt.value=[a,...Jt.value].slice(0,ar)}function xs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Ra(t,e){const n=xs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function X(t,e,n,s,a={}){ir(t,e,n,{eventType:s,...a})}let ot=null,Bt=null,ws=0;function Ei(){Bt&&(clearTimeout(Bt),Bt=null)}function or(){if(Bt)return;ws++;const t=Math.min(ws,5),e=Math.min(nr,er*Math.pow(2,t));Bt=setTimeout(()=>{Bt=null,Pi()},e)}function Pi(){Ei(),ot&&(ot.close(),ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",sr());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);ot=i,i.onopen=()=>{ot===i&&(ws=0,yt.value=!0)},i.onerror=()=>{ot===i&&(yt.value=!1,i.close(),ot=null,or())},i.onmessage=r=>{try{const l=JSON.parse(r.data);En.value++,Di.value=l,rr(l)}catch{}}}function rr(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":X(n,"Joined","system","agent_joined");break;case"agent_left":X(n,"Left","system","agent_left");break;case"broadcast":X(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":X(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":X(n,Ra("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:xs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":X(n,Ra("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:xs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":X(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":X(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":X(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":X(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:X(n,e,"system","unknown")}}function lr(){Ei(),ot&&(ot.close(),ot=null),yt.value=!1}function Mi(){return new URLSearchParams(window.location.search)}function Oi(){const t=Mi(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function ji(){return{...Oi(),"Content-Type":"application/json"}}const cr=15e3,Fi=3e4,ur=6e4,Ia=new Set([408,425,429,500,502,503,504]);class je extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Pt(this,"method");Pt(this,"path");Pt(this,"status");Pt(this,"statusText");Pt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Zs(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new je({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function dr(){var e,n;const t=Mi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function pt(t){const e=await Zs(t,{headers:Oi()},cr);if(!e.ok)throw new je({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function pr(t){return new Promise(e=>setTimeout(e,t))}function vr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function mr(t){if(t instanceof je)return t.timeout||typeof t.status=="number"&&Ia.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=vr(t.message);return e!==null&&Ia.has(e)}async function Fe(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!mr(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await pr(i),s+=1}}async function vt(t,e,n){const s=await Zs(t,{method:"POST",headers:{...ji(),...n??{}},body:JSON.stringify(e)},Fi);if(!s.ok)throw new je({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function fr(t,e,n,s=Fi){const a=await Zs(t,{method:"POST",headers:{...ji(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new je({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function _r(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function gr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function B(t,e){const n=await fr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ur),s=_r(n);return gr(s)}function $r(t="compact"){return pt(`/api/v1/dashboard?mode=${t}`)}function hr(){return pt("/api/v1/operator")}function yr(t){return vt("/api/v1/operator/action",t)}function br(t,e){return vt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Vt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function kr(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function zi(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=w(t.score,0),i=w(t.votes_up,0),r=w(t.votes_down,0),l=w(t.votes,a||i-r),d=w(t.comment_count,w(t.reply_count,0)),c=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(S(g)){const C=_(g.name,"").trim();if(C)return C}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||Vt(t.created_at),u=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Vt(t.updated_at):v),m=_(t.title,"").trim()||kr(s);return{id:e,author:n,title:m,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:v,updated_at:u,flair:c,hearth_count:w(t.hearth_count,0)}}function xr(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:Vt(t.created_at)}}async function wr(t,e){return Fe("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit","100");const s=n.toString(),a=await pt(`/api/v1/board${s?`?${s}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(zi).filter(r=>r!==null):[]}})}async function Sr(t){return Fe("fetchBoardPost",async()=>{const e=await pt(`/api/v1/board/${t}?format=flat`),n=S(e.post)?e.post:e,s=zi(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(xr).filter(r=>r!==null);return{...s,comments:i}})}function Hi(t,e){return vt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:dr()})}function Ar(t,e,n){return vt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Cr(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function K(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function La(t){const e=Cr(K(t.outcome,t.result,t.result_code));if(!e)return;const n=K(t.reason,t.reason_code,t.description,t.detail),s=K(t.summary,t.summary_ko,t.summary_en,t.note),a=K(t.details,t.details_text,t.text,t.note),i=K(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=K(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=K(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const u=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof u=="string"?[u]:Array.isArray(u)?u.map(p=>{if(typeof p=="string")return p.trim();if(S(p)){const m=_(p.summary,"").trim();if(m)return m;const g=_(p.text,"").trim();if(g)return g;const k=_(p.type,"").trim();return k||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),c=(()=>{const u=w(t.turn,Number.NaN);if(Number.isFinite(u))return u;const p=w(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=w(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const g=w(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=K(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:c,phase:v||void 0}}function Tr(t,e){const n=S(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>S(r)?_(r.type,"")==="session.outcome":!1),i=S(n.session_outcome)?n.session_outcome:{};if(S(i)&&Object.keys(i).length>0){const r=La(i);if(r)return r}if(S(a))return La(S(a.payload)?a.payload:{})}function S(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function w(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function _t(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ss(t,e=!1){return typeof t=="boolean"?t:e}function ee(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(S(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Nr(t){const e={};if(!S(t)&&!Array.isArray(t))return e;if(S(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!S(n))continue;const s=K(n.to,n.target,n.actor_id,n.name,n.id),a=K(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Rr(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function J(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Ir=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Lr(t){const e=S(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Ir.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Dr(t,e){if(t!=="dice.rolled")return;const n=w(e.raw_d20,0),s=w(e.total,0),a=w(e.bonus,0),i=_(e.action,"roll"),r=w(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Er(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Pr(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Mr(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=w(s.total,0),l=w(s.dc,0),d=_(s.label,""),c=a||"actor",v=l>0?` vs DC ${l}`:"",u=d?` (${d})`:"";return`${c} ${i}: ${r}${v}${u}`}case"turn.started":return`Turn ${w(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,S(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${w(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${w(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=S(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),d=Ss(i.guardrail_applied,!1),c=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return c;const v=r&&l?`${r}->${l}`:l||r;return`${c} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Er(s);return i?`${t}: ${i}`:t}}}function Or(t,e){const n=S(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(S(n.payload)?n.payload.actor_name:"",""),r=S(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),c=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:c||Pr(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:Mr(s,a,i,r),dice_roll:Dr(s,r),timestamp:l}}function jr(t,e,n){var Q,rt;const s=_(t.room_id,"")||n||"default",a=S(t.state)?t.state:{},i=S(a.party)?a.party:{},r=S(a.actor_control)?a.actor_control:{},l=S(a.join_gate)?a.join_gate:{},d=S(a.contribution_ledger)?a.contribution_ledger:{},c=Object.entries(i).map(([I,z])=>{const $=S(z)?z:{},Ue=J($,"max_hp",void 0,10),da=J($,"hp",void 0,Ue),_o=J($,"max_mp",void 0,0),go=J($,"mp",void 0,0),$o=J($,"level",void 0,1),ho=J($,"xp",void 0,0),yo=Ss($.alive,da>0),pa=r[I],va=typeof pa=="string"?pa:void 0,bo=Rr($.role,I,va),ko=_t($.generation),xo=K($.joined_at,$.joinedAt,$.started_at,$.startedAt),wo=K($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),So=K($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Ao=K($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),Co=K($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:I,name:_($.name,I),role:bo,keeper:va,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:ee($.traits),skills:ee($.skills),stats_raw:Lr($),status:yo?"active":"dead",generation:ko,joined_at:xo||void 0,claimed_at:wo||void 0,last_seen:So||void 0,scene:Ao||void 0,location:Co||void 0,inventory:ee($.inventory),notes:ee($.notes),relationships:Nr($.relationships),stats:{hp:da,max_hp:Ue,mp:go,max_mp:_o,level:$o,xp:ho,strength:J($,"strength","str",10),dexterity:J($,"dexterity","dex",10),constitution:J($,"constitution","con",10),intelligence:J($,"intelligence","int",10),wisdom:J($,"wisdom","wis",10),charisma:J($,"charisma","cha",10)}}}),v=c.filter(I=>I.status!=="dead"),u=Tr(t,e),p={phase_open:Ss(l.phase_open,!0),min_points:w(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},m=Object.entries(d).map(([I,z])=>{const $=S(z)?z:{};return{actor_id:I,score:w($.score,0),last_reason:_($.last_reason,"")||null,reasons:ee($.reasons)}}),g=c.reduce((I,z)=>(I[z.id]=z.name,I),{}),k=e.map(I=>Or(I,g)),C=w(a.turn,1),N=_(a.phase,"round"),T=_(a.map,""),O=S(a.world)?a.world:{},U=T||_(O.ascii_map,_(O.map,"")),D=k.filter((I,z)=>{const $=e[z];if(!S($))return!1;const Ue=S($.payload)?$.payload:{};return w(Ue.turn,-1)===C}),Y=(D.length>0?D:k).slice(-12),xt=_(a.status,"active");return{session:{id:s,room:s,status:xt==="ended"?"ended":xt==="paused"?"paused":"active",round:C,actors:v,created_at:((Q=k[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:N,events:Y,timestamp:((rt=k[k.length-1])==null?void 0:rt.timestamp)??new Date().toISOString()},map:U||void 0,join_gate:p,contribution_ledger:m,outcome:u,party:v,story_log:k,history:[]}}async function Fr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await pt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function zr(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([pt(`/api/v1/trpg/state${e}`),Fr(t)]);return jr(n,s,t)}function Hr(t){return vt("/api/v1/trpg/rounds/run",{room_id:t})}function Ur(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Kr(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),vt("/api/v1/trpg/dice/roll",e)}function Br(t,e){const n=Ur();return vt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function qr(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),vt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Gr(t,e,n){return vt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Wr(t,e,n){const s=await B("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Jr(t){const e=await B("trpg.mid_join.request",t);return JSON.parse(e)}async function Ui(t,e){await B("masc_broadcast",{agent_name:t,message:e})}async function Vr(t,e,n=1){await B("masc_add_task",{title:t,description:e,priority:n})}async function Yr(t){return B("masc_join",{agent_name:t})}async function Ki(t){await B("masc_leave",{agent_name:t})}async function Qr(t){await B("masc_heartbeat",{agent_name:t})}async function Xr(t=40){return(await B("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Zr(t,e=20){return B("masc_task_history",{task_id:t,limit:e})}async function tl(){return Fe("fetchDebates",async()=>{const t=await pt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:w(e.argument_count,0),created_at:Vt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function el(){return Fe("fetchCouncilSessions",async()=>{const t=await pt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:w(e.votes,0),quorum:w(e.quorum,0),state:_(e.state,"open"),created_at:Vt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function nl(t){const e=await B("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function sl(t){return Fe("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await pt(`/api/v1/council/debates/${e}/summary`);if(!S(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:w(n.support_count,0),oppose_count:w(n.oppose_count,0),neutral_count:w(n.neutral_count,0),total_arguments:w(n.total_arguments,0),created_at:Vt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function al(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function il(t){return S(t)?{iteration:_t(t.iteration)??0,metric_before:w(t.metric_before,0),metric_after:w(t.metric_after,0),delta:w(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:_t(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function ol(t){if(!S(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(il).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:al(t.status),current_iteration:_t(t.iteration)??_t(t.current_iteration)??0,max_iterations:_t(t.max_iterations)??0,baseline_metric:w(t.baseline_metric,0),current_metric:w(t.current_metric,w(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:_t(t.stagnation_streak)??0,stagnation_limit:_t(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds,0),history:n}}async function rl(){try{const t=await B("masc_mdal_status",{}),e=JSON.parse(t);if(S(e)&&_(e.error,"").trim()!=="")return{state:"idle"};const n=ol(e);return n?{state:"ready",loop:n}:{state:"error"}}catch{return{state:"error"}}}async function ll(){try{const t=await B("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Lt=f([]),kt=f([]),ze=f([]),Zt=f([]),Dt=f(null),ie=f(null),As=f(new Map),ta=f([]),Ne=f("hot"),Ct=f(!0),Bi=f(null),ct=f(""),Re=f([]),Ht=f(!1),tt=f(new Map),Cs=f(!1),Ie=f(!1),Ts=f(!1),Ut=f(!1),cl=f(null),Ns=f(null),qi=f(null),Gi=f(null),Wi=W(()=>Lt.value.filter(t=>t.status==="active"||t.status==="idle")),ea=W(()=>{const t=kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function ul(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Ji=W(()=>{const t=new Map;for(const e of Zt.value)t.set(e.name,ul(e));return t}),dl=12e4;function pl(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const Vi=W(()=>{const t=Date.now(),e=new Set,n=As.value;for(const s of Zt.value){const a=pl(s,n);a!=null&&t-a>dl&&e.add(s.name)}return e}),dn={},vl=5e3;function Rs(){delete dn.compact,delete dn.full}function et(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function le(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Yi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function ml(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function fl(t){if(!et(t))return null;const e=b(t.name);return e?{name:e,status:Yi(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:le(t.traits),interests:le(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function _l(t){if(!et(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:ml(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function gl(t){if(!et(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",s=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:s,type:b(t.type)}}function $l(t){return Array.isArray(t)?t.map(e=>{if(!et(e))return null;const n=A(e.ts_unix);if(n==null)return null;const s=et(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?A(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function hl(t){return(Array.isArray(t)?t:et(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!et(n))return null;const s=et(n.agent)?n.agent:null,a=et(n.context)?n.context:null,i=et(n.metrics_window)?n.metrics_window:void 0,r=b(n.name);if(!r)return null;const l=A(n.context_ratio)??A(a==null?void 0:a.context_ratio),d=b(n.status)??b(s==null?void 0:s.status)??"offline",c=Yi(d),v=b(n.model)??b(n.active_model)??b(n.primary_model),u=le(n.skill_secondary),p=a?{source:b(a.source),context_ratio:A(a.context_ratio),context_tokens:A(a.context_tokens),context_max:A(a.context_max),message_count:A(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:b(s.name),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen)}:void 0,g=$l(n.metrics_series);return{name:r,emoji:b(n.emoji),koreanName:b(n.koreanName)??b(n.korean_name),agent_name:b(n.agent_name),trace_id:b(n.trace_id),model:v,primary_model:b(n.primary_model),active_model:b(n.active_model),next_model_hint:b(n.next_model_hint)??null,status:c,last_heartbeat:b(n.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:A(n.generation),turn_count:A(n.turn_count)??A(n.total_turns),context_ratio:l,context_tokens:A(n.context_tokens)??A(a==null?void 0:a.context_tokens),context_max:A(n.context_max)??A(a==null?void 0:a.context_max),context_source:b(n.context_source)??b(a==null?void 0:a.source),context:p,traits:le(n.traits),interests:le(n.interests),primaryValue:b(n.primaryValue)??b(n.primary_value),activityLevel:A(n.activityLevel)??A(n.activity_level),memory_recent_note:b(n.memory_recent_note)??null,conversation_tail_count:A(n.conversation_tail_count),k2k_count:A(n.k2k_count),handoff_count_total:A(n.handoff_count_total)??A(n.trace_history_count),compaction_count:A(n.compaction_count),last_compaction_saved_tokens:A(n.last_compaction_saved_tokens),skill_primary:b(n.skill_primary)??null,skill_secondary:u,skill_reason:b(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function Pn(t="full"){var s,a,i;const e=Date.now(),n=dn[t];if(!(n&&e-n.time<vl)){Cs.value=!0;try{const r=await $r(t);dn[t]={data:r,time:e},Lt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(fl).filter(l=>l!==null),kt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(_l).filter(l=>l!==null),ze.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(gl).filter(l=>l!==null),Zt.value=hl(r.keepers),Dt.value=et(r.status)?r.status:null,ie.value=r.perpetual??null,cl.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Cs.value=!1}}}async function ut(){Ie.value=!0;try{const t=await wr(Ne.value,{excludeSystem:Ct.value});ta.value=t.posts??[],Ns.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Ie.value=!1}}async function dt(){var t;Ts.value=!0;try{const e=ct.value||((t=Dt.value)==null?void 0:t.room)||"default";ct.value||(ct.value=e);const n=await zr(e);Bi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ts.value=!1}}async function ce(){Ht.value=!0;try{const t=await ll();Re.value=Array.isArray(t)?t:[],qi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Ht.value=!1}}async function ue(){const t=++Un;Ut.value=!0;try{const e=await rl();if(t!==Un||e.state==="error")return;if(Gi.value=new Date().toISOString(),e.state==="idle"){const i=new Map(tt.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});tt.value=i;return}const n=e.loop,s=new Map(tt.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),tt.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===Un&&(Ut.value=!1)}}let zn=null,Hn=null,Un=0;function yl(){return Di.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(As.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),As.value=n}if(Rs(),zn||(zn=setTimeout(()=>{Pn(),zn=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Hn||(Hn=setTimeout(()=>{ut(),Hn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Rs(),e.type==="mdal_started"&&e.loop_id){const n=new Map(tt.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),tt.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(tt.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),tt.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(tt.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),tt.value=n}}})}let de=null;function bl(){de||(de=setInterval(()=>{Rs(),Pn()},1e4))}function kl(){de&&(clearInterval(de),de=null)}function h({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function at({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function xl(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function P({timestamp:t}){const e=xl(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function ne(t){return(t??"").trim().toLowerCase()}function St(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Da(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function na(t,e,n,s,a={}){var m;const i=ne(t),r=e.filter(g=>ne(g.assignee)===i&&(g.status==="claimed"||g.status==="in_progress")).length,l=n.filter(g=>ne(g.from)===i).sort((g,k)=>St(k.timestamp)-St(g.timestamp))[0],d=s.filter(g=>ne(g.agent)===i||ne(g.author)===i).sort((g,k)=>St(k.timestamp)-St(g.timestamp))[0],c=l?St(l.timestamp):0,v=d?St(d.timestamp):0,u=a.lastSeen?St(a.lastSeen):0,p=((m=a.currentTask)==null?void 0:m.trim())||(r>0?`${r} claimed tasks`:null);return c===0&&v===0&&u===0?{activeAssignedCount:r,lastActivityAt:null,lastActivityText:p}:c>=v&&l&&c>=u?{activeAssignedCount:r,lastActivityAt:l.timestamp,lastActivityText:Da(l.content)}:v>=u&&d?{activeAssignedCount:r,lastActivityAt:new Date(d.timestamp).toISOString(),lastActivityText:Da(d.text)}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:p??"Presence heartbeat"}}const sa=f(null);function aa(t){sa.value=t}function Ea(){sa.value=null}const jt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function wl(t){if(!t)return 0;const e=jt.findIndex(n=>n.level===t);return e>=0?e:0}function Sl({keeper:t}){const e=wl(t.autonomy_level),n=jt[e]??jt[0];if(!n)return null;const s=(e+1)/jt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${jt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${jt.map((a,i)=>o`
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
            <strong><${P} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function nn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Al({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${nn(t.context_tokens)}</div>
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
  `}function Cl({keeper:t}){var v,u;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,m)=>{const g=a+m/(i-1)*(n-2*a),k=s-a-(p.context_ratio??0)*(s-2*a);return{x:g,y:k,p}}),l=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((u=e[e.length-1])==null?void 0:u.context_ratio)??0)*100,c=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${c}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:m})=>o`
          <circle cx="${p.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Kn=f("");function Tl({keeper:t}){var a,i,r,l;const e=Kn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Kn.value}
        onInput=${d=>{Kn.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${nn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${nn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${nn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Nl({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Rl({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Il({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Pa({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Bn(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Ll({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Bn(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Bn(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Bn(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Dl({keeperName:t}){const[e,n]=Be("Loading internal monologue..."),[s,a]=Be(""),[i,r]=Be([]),[l,d]=Be(!1),c=async()=>{try{const u=await B("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof u=="string"?u:JSON.stringify(u,null,2))}catch(u){n("Failed to load: "+String(u))}};ht(()=>{c()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const u=s;a(""),r(p=>[...p,{role:"You",text:u}]);try{const p=await B("masc_keeper_msg",{name:t,message:u});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),c()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(u=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${u.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${u.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${u.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${u.role}</strong>
                <span style="white-space: pre-wrap;">${u.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${u=>a(u.currentTarget.value)} 
              onKeyDown=${u=>u.key==="Enter"&&!u.shiftKey&&v()}
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
  `}function El(){var e,n,s;const t=sa.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ea()}}
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
            <${at} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ea()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Al} keeper=${t} />

        ${""}
        <${Cl} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${h} title="Field Dictionary">
            <${Tl} keeper=${t} />
          <//>

          ${""}
          <${h} title="Profile">
            <${Pa} traits=${t.traits??[]} label="Traits" />
            <${Pa} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${P} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${h} title="Autonomy">
                <${Sl} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${h} title="TRPG Stats">
                <${Nl} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${h} title="Equipment (${t.inventory.length})">
                <${Rl} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${h} title="Relationships (${Object.keys(t.relationships).length})">
                <${Il} rels=${t.relationships} />
              <//>
            `:null}

          <${h} title="Runtime Signals">
            <${Ll} keeper=${t} />
          <//>

          <${h} title="Memory & Context">
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
        <${Dl} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Pl=0;const Tt=f([]);function y(t,e="success",n=4e3){const s=++Pl;Tt.value=[...Tt.value,{id:s,message:t,type:e}],setTimeout(()=>{Tt.value=Tt.value.filter(a=>a.id!==s)},n)}function Ml(t){Tt.value=Tt.value.filter(e=>e.id!==t)}function Ol(){const t=Tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ml(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const jl="masc_dashboard_agent_name",te=f(null),pn=f(!1),Le=f(""),vn=f([]),De=f([]),qt=f(""),pe=f(!1);function ia(t){te.value=t,oa()}function Ma(){te.value=null,Le.value="",vn.value=[],De.value=[],qt.value=""}function Fl(){const t=te.value;return t?Lt.value.find(e=>e.name===t)??null:null}function Qi(t){return t?kt.value.filter(e=>e.assignee===t):[]}async function oa(){const t=te.value;if(t){pn.value=!0,Le.value="",vn.value=[],De.value=[];try{const e=await Xr(80);vn.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Qi(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Zr(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));De.value=s}catch(e){Le.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pn.value=!1}}}async function Oa(){var s;const t=te.value,e=qt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(jl))==null?void 0:s.trim())||"dashboard";pe.value=!0;try{await Ui(n,`@${t} ${e}`),qt.value="",y(`Mention sent to ${t}`,"success"),oa()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{pe.value=!1}}function zl({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${at} status=${t.status} />
    </div>
  `}function Hl({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ul(){var a,i,r,l;const t=te.value;if(!t)return null;const e=Fl(),n=Qi(t),s=vn.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ma()}}
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
                        <${at} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${P} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{oa()}} disabled=${pn.value}>
              ${pn.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ma}>Close</button>
          </div>
        </div>

        ${Le.value?o`<div class="council-error">${Le.value}</div>`:null}

        <div class="agent-detail-grid">
          <${h} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${zl} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${h} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,c)=>o`<div key=${c} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${h} title="Task History">
          ${De.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${De.value.map(d=>o`<${Hl} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${h} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${qt.value}
              onInput=${d=>{qt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Oa()}}
              disabled=${pe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Oa()}}
              disabled=${pe.value||qt.value.trim()===""}
            >
              ${pe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Mt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Kl({agent:t}){const e=na(t.name,kt.value,ze.value,Jt.value,{currentTask:t.current_task,lastSeen:t.last_seen});return o`
    <div class="agent" onClick=${()=>ia(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${at} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
      ${!t.current_task&&e.activeAssignedCount>0?o`<span class="agent-task">${e.activeAssignedCount} claimed</span>`:null}
      ${e.lastActivityText?o`
            <span class="agent-activity-meta">
              ${e.lastActivityAt?o`<${P} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </span>
          `:null}
    </div>
  `}function Bl(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function ja(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function ql({keeper:t}){var r;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Ji.value.get(t.name),a=Vi.value.has(t.name),i=((r=t.agent)==null?void 0:r.current_task)??"No current task";return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>aa(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${at} status=${t.status} />
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
              ${t.context_tokens!=null?o` (${Bl(t.context_tokens)})`:null}
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
            <${P} timestamp=${t.last_heartbeat} />
          </div>
        `:null}
      </div>
    </div>
  `}function Fa(){var r,l,d,c,v;const t=Dt.value,e=Lt.value,n=Zt.value,s=ea.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${Mt} label="Agents" value=${e.length} />
      <${Mt} label="Active" value=${Wi.value.length} color="#4ade80" />
      <${Mt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Mt} label="Tasks" value=${kt.value.length} />
      <${Mt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${Mt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${h} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ha(a==null?void 0:a.alert_level)}`}>
                ${za(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ge(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${Ge(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ha(i==null?void 0:i.alert_level)}`}>
                ${za(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ge(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${Ge(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${h} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(u=>o`<${Kl} key=${u.name} agent=${u} />`)}
        </div>
      <//>

      <${h} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(u=>o`<${ql} key=${u.name} keeper=${u} />`)}
        </div>
      <//>
    </div>

    ${ie.value?o`
        <${h} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${ie.value.running?"Running":"Stopped"}</span>
            ${ie.value.goal?o`<span>Goal: ${ie.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${h} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Gl(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((c=t.data_quality)==null?void 0:c.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${P} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function Gl(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ge(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function za(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ha(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const He=f(null),mn=f(!1),bt=f(null),E=f(!1),fn=f([]);let Wl=1;function M(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Xi(t){return typeof t=="boolean"?t:void 0}function Jl(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ft(t,e=[]){if(Array.isArray(t))return t;if(!M(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Vl(t){return M(t)?{id:x(t.id),seq:G(t.seq),from:x(t.from)??x(t.from_agent)??"system",content:x(t.content)??"",timestamp:x(t.timestamp)??new Date().toISOString(),type:x(t.type)}:null}function Yl(t){return M(t)?{room_id:x(t.room_id),current_room:x(t.current_room)??x(t.room),project:x(t.project),cluster:x(t.cluster),paused:Xi(t.paused),pause_reason:x(t.pause_reason)??null,paused_by:x(t.paused_by)??null,paused_at:x(t.paused_at)??null}:{}}function Ua(t){if(!M(t))return;const e=Object.entries(t).map(([n,s])=>{const a=x(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Ql(t){if(!M(t))return null;const e=M(t.status)?t.status:void 0,n=M(t.summary)?t.summary:M(e==null?void 0:e.summary)?e.summary:void 0,s=M(t.session)?t.session:M(e==null?void 0:e.session)?e.session:void 0,a=x(t.session_id)??x(n==null?void 0:n.session_id)??x(s==null?void 0:s.session_id);if(!a)return null;const i=Ua(t.report_paths)??Ua(e==null?void 0:e.report_paths),r=Ft(t.recent_events,["events"]).filter(M);return{session_id:a,status:x(t.status)??x(n==null?void 0:n.status)??x(s==null?void 0:s.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:M(t.team_health)?t.team_health:M(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:M(t.communication_metrics)?t.communication_metrics:M(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:M(t.orchestration_state)?t.orchestration_state:M(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:M(t.cascade_metrics)?t.cascade_metrics:M(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Xl(t){if(!M(t))return null;const e=x(t.name);if(!e)return null;const n=M(t.context)?t.context:void 0;return{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:Jl(t.active_goal_ids),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:x(t.model)??x(t.active_model)??x(t.primary_model)}}function Zl(t){if(!M(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function tc(t){const e=M(t)?t:{};return{room:Yl(e.room),sessions:Ft(e.sessions,["items","sessions"]).map(Ql).filter(n=>n!==null),keepers:Ft(e.keepers,["items","keepers"]).map(Xl).filter(n=>n!==null),recent_messages:Ft(e.recent_messages,["messages"]).map(Vl).filter(n=>n!==null),pending_confirms:Ft(e.pending_confirms,["items","confirms"]).map(Zl).filter(n=>n!==null),available_actions:Ft(e.available_actions,["actions"]).filter(M).map(n=>({action_type:x(n.action_type)??"unknown",target_type:x(n.target_type)??"unknown",description:x(n.description),confirm_required:Xi(n.confirm_required)}))}}function We(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ka(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function _n(t){fn.value=[{...t,id:Wl++,at:new Date().toISOString()},...fn.value].slice(0,20)}function Zi(t){return t.confirm_required?We(t.preview)||"Confirmation required":We(t.result)||We(t.executed_action)||We(t.delegated_tool_result)||t.status}async function Yt(){mn.value=!0,bt.value=null;try{const t=await hr();He.value=tc(t)}catch(t){bt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{mn.value=!1}}async function ec(t){E.value=!0,bt.value=null;try{const e=await yr(t);return _n({actor:t.actor,action_type:t.action_type,target_label:Ka(t),outcome:e.confirm_required?"preview":"executed",message:Zi(e),delegated_tool:e.delegated_tool}),await Yt(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw bt.value=n,_n({actor:t.actor,action_type:t.action_type,target_label:Ka(t),outcome:"error",message:n}),e}finally{E.value=!1}}async function nc(t,e){E.value=!0,bt.value=null;try{const n=await br(t,e);return _n({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Zi(n),delegated_tool:n.delegated_tool}),await Yt(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw bt.value=s,_n({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{E.value=!1}}const to="masc_dashboard_agent_name";function sc(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(to))==null?void 0:s.trim())||"dashboard"}const Mn=f(sc()),ve=f(""),Is=f("Operator pause"),me=f(""),gn=f(""),Ls=f("2"),$n=f(""),Gt=f("note"),hn=f(""),yn=f(""),bn=f(""),Ds=f("2"),Es=f("Operator stop request"),Ps=f(""),fe=f("");function ac(t){const e=t.trim()||"dashboard";Mn.value=e,localStorage.setItem(to,e)}function Ba(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ic(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function Et(t){const e=Mn.value.trim()||"dashboard";try{const n=await ec({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?y("Confirmation queued","warning"):y(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return y(s,"error"),null}}async function qa(){const t=ve.value.trim();if(!t)return;await Et({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(ve.value="")}async function oc(){await Et({action_type:"room_pause",target_type:"room",payload:{reason:Is.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function rc(){await Et({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function lc(){const t=me.value.trim();if(!t)return;await Et({action_type:"task_inject",target_type:"room",payload:{title:t,description:gn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ls.value,10)||2},successMessage:"Task injection submitted"})&&(me.value="",gn.value="")}async function cc(){var i;const t=He.value,e=$n.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){y("Select a team session first","warning");return}const n={turn_kind:Gt.value},s=hn.value.trim();s&&(n.message=s),Gt.value==="task"&&(n.task_title=yn.value.trim()||"Operator injected task",n.task_description=bn.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ds.value,10)||2),await Et({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(hn.value="",Gt.value==="task"&&(yn.value="",bn.value=""))}async function uc(){var n;const t=He.value,e=$n.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){y("Select a team session first","warning");return}await Et({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Es.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function dc(){var a;const t=He.value,e=Ps.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=fe.value.trim();if(!e){y("Select a keeper first","warning");return}if(!n)return;await Et({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(fe.value="")}async function pc(t){const e=Mn.value.trim()||"dashboard";try{await nc(e,t),y("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";y(s,"error")}}function vc(){var d;ht(()=>{Yt()},[]);const t=He.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===$n.value)??n[0]??null,l=s.find(c=>c.name===Ps.value)??s[0]??null;return o`
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
            value=${Mn.value}
            onInput=${c=>ac(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Yt()}} disabled=${mn.value||E.value}>
            ${mn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${bt.value?o`
        <section class="ops-banner error">${bt.value}</section>
      `:null}

      ${a.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <div class="ops-confirmation-list">
            ${a.map(c=>o`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?o`<pre class="ops-code-block">${Ba(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{pc(c.confirm_token)}} disabled=${E.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
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
              onInput=${c=>{ve.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&qa()}}
              disabled=${E.value}
            />
            <button class="control-btn" onClick=${()=>{qa()}} disabled=${E.value||ve.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Is.value}
              onInput=${c=>{Is.value=c.target.value}}
              disabled=${E.value}
            />
            <button class="control-btn ghost" onClick=${()=>{oc()}} disabled=${E.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{rc()}} disabled=${E.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${me.value}
            onInput=${c=>{me.value=c.target.value}}
            disabled=${E.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${gn.value}
            onInput=${c=>{gn.value=c.target.value}}
            disabled=${E.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Ls.value}
              onChange=${c=>{Ls.value=c.target.value}}
              disabled=${E.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{lc()}} disabled=${E.value||me.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Recent Messages</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(c=>o`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${c.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var v;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{$n.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(v=c.team_health)!=null&&v.status?String(c.team_health.status):"health n/a"}</span>
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
              value=${Gt.value}
              onChange=${c=>{Gt.value=c.target.value}}
              disabled=${E.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{cc()}} disabled=${E.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${hn.value}
            onInput=${c=>{hn.value=c.target.value}}
            disabled=${E.value||!r}
          ></textarea>
          ${Gt.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${yn.value}
              onInput=${c=>{yn.value=c.target.value}}
              disabled=${E.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${bn.value}
              onInput=${c=>{bn.value=c.target.value}}
              disabled=${E.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ds.value}
              onChange=${c=>{Ds.value=c.target.value}}
              disabled=${E.value||!r}
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
              onInput=${c=>{Es.value=c.target.value}}
              disabled=${E.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{uc()}} disabled=${E.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${s.length===0?o`<div class="ops-empty">No keepers available.</div>`:s.map(c=>o`
              <button
                key=${c.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===c.name?"active":""}"
                onClick=${()=>{Ps.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${ic(c.last_turn_ago_s)}</span>
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
            onInput=${c=>{fe.value=c.target.value}}
            disabled=${E.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{dc()}} disabled=${E.value||!l||fe.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${fn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:fn.value.map(c=>o`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const Ms=f([]),Os=f([]),_e=f(""),kn=f(!1),ge=f(!1),Ee=f(""),xn=f(null),Z=f(null),js=f(!1);async function Fs(){kn.value=!0,Ee.value="";try{const[t,e]=await Promise.all([tl(),el()]);Ms.value=t,Os.value=e}catch(t){Ee.value=t instanceof Error?t.message:"Failed to load council data"}finally{kn.value=!1}}async function Ga(){const t=_e.value.trim();if(t){ge.value=!0;try{const e=await nl(t);_e.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Fs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{ge.value=!1}}}async function mc(t){xn.value=t,js.value=!0,Z.value=null;try{Z.value=await sl(t)}catch(e){Ee.value=e instanceof Error?e.message:"Failed to load debate status",Z.value=null}finally{js.value=!1}}function fc({debate:t}){const e=xn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>mc(t.id)}
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
  `}function _c({session:t}){return o`
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
  `}function gc(){var e;const t=(e=Dt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function $c(){var e,n;ht(()=>{Fs()},[]);const t=((n=(e=Dt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${gc} />
      <${h} title="Council Command" class="section">
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
          <button class="control-btn ghost" onClick=${Fs} disabled=${kn.value}>
            ${kn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ee.value?o`<div class="council-error">${Ee.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${h} title="Debates" class="section">
          <div class="council-list">
            ${Ms.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Ms.value.map(s=>o`<${fc} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${h} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Os.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Os.value.map(s=>o`<${_c} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${h} title=${xn.value?`Debate Detail (${xn.value})`:"Debate Detail"} class="section">
        ${js.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Z.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Z.value.status}</span>
                  <span>Total arguments: ${Z.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Z.value.support_count}</span>
                  <span>Oppose: ${Z.value.oppose_count}</span>
                  <span>Neutral: ${Z.value.neutral_count}</span>
                </div>
                ${Z.value.summary_text?o`<pre class="council-detail">${Z.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function hc({text:t}){if(!t)return null;const e=yc(t);return o`<div class="markdown-content">${e}</div>`}function yc(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const c=e[s].replace("</think>","").trim();c&&r.push(c),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${qn(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${qn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${qn(i.join(`
`))}</p>`)}return n}function qn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const eo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sn=f(null),$e=f([]),Rt=f(!1),Nt=f(null),he=f("");function bc(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const kc=f(bc()),ye=f(!1);async function ra(t){Nt.value=t,sn.value=null,$e.value=[],Rt.value=!0;try{const e=await Sr(t);if(Nt.value!==t)return;sn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},$e.value=e.comments??[]}catch{Nt.value===t&&(sn.value=null,$e.value=[])}finally{Nt.value===t&&(Rt.value=!1)}}async function Wa(t){const e=he.value.trim();if(e){ye.value=!0;try{await Ar(t,kc.value,e),he.value="",y("Comment posted","success"),await ra(t),ut()}catch{y("Failed to post comment","error")}finally{ye.value=!1}}}function xc(){const t=Ne.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${eo.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Ne.value=e.id,ut()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ct.value?"is-active":""}"
          onClick=${()=>{Ct.value=!Ct.value,ut()}}
        >
          ${Ct.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${ut} disabled=${Ie.value}>
          ${Ie.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Gn(){var e;const t=(e=Dt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function no({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function wc(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Ja(t){return t.updated_at!==t.created_at}function Wn(){var n;const t=((n=eo.find(s=>s.id===Ne.value))==null?void 0:n.label)??Ne.value,e=ta.value.length;return o`
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
        <strong>${Ct.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ns.value?o`<${P} timestamp=${Ns.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Sc({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Hi(t.id,n),ut()}catch{y("Failed to vote","error")}};return o`
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
              <${no} flair=${t.flair} />
              ${Ja(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${P} timestamp=${t.created_at} /></span>
            ${Ja(t)?o`<span>Updated <${P} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${wc(t.content)}</div>
      </div>
    </div>
  `}function Ac({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${P} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Cc({postId:t}){return o`
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
  `}function Tc({post:t}){Nt.value!==t.id&&!Rt.value&&ra(t.id);const e=async n=>{try{await Hi(t.id,n),ut()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Dn("board")}>← Back to Board</button>
      <${h} title=${o`${t.title} <${no} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${hc} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${P} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${h} title="Comments (${Rt.value?"...":$e.value.length})">
        ${Rt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Ac} comments=${$e.value} />`}
        <${Cc} postId=${t.id} />
      <//>
    </div>
  `}function Nc(){var a,i;const t=ta.value,e=Ie.value,n=st.value.postId,s=((i=(a=Dt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(Nt.value===n?sn.value:null);return!r&&Nt.value!==n&&!Rt.value&&ra(n),r?o`
          <${Gn} />
          <${Wn} />
          <${Tc} post=${r} />
        `:o`
          <div>
            <${Gn} />
            <${Wn} />
            <button class="back-btn" onClick=${()=>Dn("board")}>← Back to Board</button>
            ${Rt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Gn} />
    <${Wn} />
    <${xc} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":Ct.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Sc} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Rc(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Ic(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Lc(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const so=120,zs=f("all"),Dc={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Ec={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Pc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Mc(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Rc(t),actor:Ic(t),content:Lc(t),timestamp:new Date(t.timestamp).toISOString()}}function wn(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Hs=W(()=>{const t=ze.value.map(Pc),e=Jt.value.map(Mc);return[...t,...e].sort((n,s)=>wn(s.timestamp)-wn(n.timestamp))}),Oc=W(()=>{const t=Hs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),jc=W(()=>{const t=zs.value;return(t==="all"?Hs.value:Hs.value.filter(n=>n.kind===t)).slice(0,so)}),Fc=W(()=>Lt.value.map(t=>({agent:t,motion:na(t.name,kt.value,ze.value,Jt.value,{currentTask:t.current_task,lastSeen:t.last_seen})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:wn(e.motion.lastActivityAt??0)-wn(t.motion.lastActivityAt??0)}));function zc(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function se({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Hc({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${zc(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Ec[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Uc(){const t=Oc.value,e=jc.value,n=e[0],s=Fc.value;return o`
    <div class="stats-grid">
      <${se} label="Visible rows" value=${e.length} />
      <${se} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${se} label="Tracked keeper events" value=${t.keepers} color="#4ade80" />
      <${se} label="Tracked board events" value=${t.board} color="#fbbf24" />
      <${se} label="SSE events" value=${En.value} color="#c084fc" />
    </div>

    <${h} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${zs.value===a?"active":""}"
              onClick=${()=>{zs.value=a}}
            >
              ${Dc[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${yt.value?"":"pill-stale"}">
            ${yt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${P} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${so} rows</span>
          <span>Journal merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for events...</div>`:e.map(a=>o`<${Hc} key=${a.id} row=${a} />`)}
      </div>
    <//>

    <${h} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${P} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function ao({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}const Jn=600*1e3,Kc=1200*1e3,Va=.8;function mt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ot(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Bc(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function qc(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Gc(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Wc(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Jc(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Vc(t){var d,c;const e=na(t.name,kt.value,ze.value,Jt.value,{currentTask:t.current_task,lastSeen:t.last_seen}),n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-mt(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):s>Kc?(i="quiet",r="bad",l=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>Jn?"warn":"ok",l=s>Jn?"Execution looks quiet for too long":"Task and live signal aligned"):s>Jn?(i="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((c=t.current_task)==null?void 0:c.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function Yc(t){const e=Ji.value.get(t.name)??"idle",n=Vi.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=Va)&&(a="warning",i="warn",r=s>=Va?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:Wc(t),note:r}}function ae({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Qc({item:t}){const e=t.kind==="agent"?()=>ia(t.agent.name):()=>aa(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${P} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function Xc({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>ia(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ao} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${at} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Bc(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${P} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${P} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Zc({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>aa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ao} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${at} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${qc(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${P} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Jc(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Gc(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function tu(){const t=[...Lt.value].map(Vc).sort((d,c)=>{const v=Ot(c.tone)-Ot(d.tone);if(v!==0)return v;const u=c.activeTaskCount-d.activeTaskCount;return u!==0?u:mt(c.lastSignalAt)-mt(d.lastSignalAt)}),e=[...Zt.value].map(Yc).sort((d,c)=>{const v=Ot(c.tone)-Ot(d.tone);if(v!==0)return v;const u=(c.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return u!==0?u:mt(c.keeper.last_heartbeat)-mt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,s=t.filter(d=>d.state==="working").length,a=t.filter(d=>d.lastSignalAt&&Date.now()-mt(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),l=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,c)=>{const v=Ot(c.tone)-Ot(d.tone);return v!==0?v:mt(c.timestamp)-mt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${ae} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${ae} label="Working now" value=${s} color="#fbbf24" caption="task or claimed load" />
        <${ae} label="Fresh signals" value=${a} color="#22d3ee" caption="within last 2 minutes" />
        <${ae} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${ae} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${h} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:l.map(d=>o`<${Qc} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${h} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${Zc} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${h} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${Xc} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function Vn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${P} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function eu(){const{todo:t,inProgress:e,done:n}=ea.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Vn} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Vn} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Vn} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function nu(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function Yn({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${nu(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${P} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function su(){const t=ea.value,e=t.inProgress,n=t.todo,s=t.done,a=Wi.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
      <${h} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${Yn} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${h} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${Yn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${h} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${at} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${h} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${Yn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const Sn=f("all"),An=f("all"),Us=W(()=>{let t=Re.value;return Sn.value!=="all"&&(t=t.filter(e=>e.horizon===Sn.value)),An.value!=="all"&&(t=t.filter(e=>e.status===An.value)),t}),au=W(()=>{const t={short:[],mid:[],long:[]};for(const e of Us.value){const n=t[e.horizon];n&&n.push(e)}return t}),iu=W(()=>{const t=Array.from(tt.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function ou(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function la(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function an(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function ru(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ya(t){return t.toFixed(4)}function Qa(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lu({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${an(t.horizon)}">
            ${la(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${ou(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${P} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${at} status=${t.status} />
        <div class="goal-updated">
          <${P} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Xa({label:t,timestamp:e,source:n}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${P} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Qn({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${h} title="${la(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${lu} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function cu(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Sn.value===t?"active":""}"
            onClick=${()=>{Sn.value=t}}
          >
            ${t==="all"?"All":la(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${An.value===t?"active":""}"
            onClick=${()=>{An.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function uu(){const t=Re.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${an("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${an("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${an("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function du({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${at} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ya(t.baseline_metric)}</span>
          <span>Current ${Ya(t.current_metric)}</span>
          <span class=${Qa(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Qa(t)}
          </span>
          <span>Elapsed ${ru(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function pu(){ht(()=>{ce(),ue()},[]);const t=au.value,e=iu.value,n=e.filter(a=>a.status==="running").length,s=Re.value.filter(a=>a.status==="active").length;return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Us.value.length}</div>
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

      <${h} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${ce} disabled=${Ht.value}>
              ${Ht.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${ue} disabled=${Ut.value}>
              ${Ut.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{ce(),ue()}}
              disabled=${Ht.value||Ut.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Xa} label="Goals" timestamp=${qi.value} source="masc_goal_list" />
          <${Xa} label="MDAL loops" timestamp=${Gi.value} source="masc_mdal_status" />
        </div>
      <//>

      <${h} title="Goal Pipeline" class="section">
        <${uu} />
        <${cu} />
      <//>

      ${Ht.value&&Re.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Us.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Qn} horizon="short" items=${t.short??[]} />
              <${Qn} horizon="mid" items=${t.mid??[]} />
              <${Qn} horizon="long" items=${t.long??[]} />
            `}

      <${h} title="MDAL Loops" class="section">
        ${Ut.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0?o`
                <div class="empty-state">
                  No loop snapshot is visible right now. This section only changes when the backend exposes a current MDAL loop.
                </div>
              `:o`
                <div class="planning-loop-list">
                  ${e.map(a=>o`<${du} key=${a.loop_id} loop=${a} />`)}
                </div>
              `}
      <//>
    </div>
  `}const zt=f(""),Xn=f("ability_check"),Zn=f("10"),ts=f("12"),Je=f(""),Ve=f("idle"),ft=f(""),Ye=f("keeper-late"),es=f("player"),ns=f(""),V=f("idle"),ss=f(null),Qe=f(""),as=f(""),is=f("player"),os=f(""),rs=f(""),ls=f(""),be=f("20"),cs=f("20"),us=f(""),Xe=f("idle"),Ks=f(null),io=f("overview"),ds=f("all"),ps=f("all"),vs=f("all"),vu=12e4,On=f(null),Za=f(Date.now());function mu(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function fu(t,e){return e>0?Math.round(t/e*100):0}const _u={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},gu={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ze(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function $u(t){const e=t.trim().toLowerCase();return _u[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function hu(t){const e=t.trim().toLowerCase();return gu[e]??"상황에 따라 선택되는 전술 액션입니다."}function $t(t){return typeof t=="object"&&t!==null}function q(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function it(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Pe(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const yu=new Set(["str","dex","con","int","wis","cha"]);function bu(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!$t(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function ku(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(be.value.trim(),10);Number.isFinite(s)&&s>n&&(be.value=String(n))}function Bs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function xu(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function wu(t){io.value=t}function oo(t){const e=On.value;return e==null||e<=t}function Su(t){const e=On.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Cn(){On.value=null}function ro(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Au(t,e){ro(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(On.value=Date.now()+vu,y("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function on(t){return oo(t)?(y("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function qs(t,e,n){return ro([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Cu({hp:t,max:e}){const n=fu(t,e),s=mu(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Tu({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Nu({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function lo({actor:t}){var d,c,v,u;const e=(d=t.archetype)==null?void 0:d.trim(),n=(c=t.persona)==null?void 0:c.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(u=t.background)==null?void 0:u.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([p,m])=>Number.isFinite(m)).filter(([p])=>!yu.has(p.toLowerCase()));return o`
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
        <${at} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Nu} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Cu} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Tu} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ze(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([p,m])=>o`
                <span class="trpg-custom-stat-chip">${Ze(p)} ${m}</span>
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
                  <span class="trpg-annot-name">${Ze(p)}</span>
                  <span class="trpg-annot-desc">${$u(p)}</span>
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
                  <span class="trpg-annot-name">${Ze(p)}</span>
                  <span class="trpg-annot-desc">${hu(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Ru({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function co({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${xu(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Bs(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${P} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Iu({events:t}){const e="__none__",n=ds.value,s=ps.value,a=vs.value,i=Array.from(new Set(t.map(Bs).map(u=>u.trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),r=Array.from(new Set(t.map(u=>(u.type??"").trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),l=t.some(u=>(u.type??"").trim()===""),d=Array.from(new Set(t.map(u=>(u.phase??"").trim()).filter(u=>u!==""))).sort((u,p)=>u.localeCompare(p)),c=t.some(u=>(u.phase??"").trim()===""),v=t.filter(u=>{if(n!=="all"&&Bs(u)!==n)return!1;const p=(u.type??"").trim(),m=(u.phase??"").trim();if(s===e){if(p!=="")return!1}else if(s!=="all"&&p!==s)return!1;if(a===e){if(m!=="")return!1}else if(a!=="all"&&m!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${u=>{ds.value=u.target.value}}>
          <option value="all">all</option>
          ${i.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${u=>{ps.value=u.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${u=>{vs.value=u.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${d.map(u=>o`<option value=${u}>${u}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ds.value="all",ps.value="all",vs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${co} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Lu({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function uo({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Du({state:t,nowMs:e}){var c;const n=ct.value||((c=t.session)==null?void 0:c.room)||"",s=Ve.value,a=t.party??[];if(!a.find(v=>v.id===zt.value)&&a.length>0){const v=a[0];v&&(zt.value=v.id)}const r=async()=>{var u,p;if(!n){y("Room ID가 비어 있습니다.","error");return}if(!on(e))return;const v=((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(qs("라운드 실행",n,v)){Ve.value="running";try{const m=await Hr(n);Ks.value=m,Ve.value="ok";const g=$t(m.summary)?m.summary:null,k=g?Pe(g,"advanced",!1):!1,C=g?q(g,"progress_reason",""):"";y(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,k?"success":"warning"),dt()}catch(m){Ks.value=null,Ve.value="error";const g=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";y(g,"error")}finally{Cn()}}},l=async()=>{var u,p;if(!n||!on(e))return;const v=((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(qs("턴 강제 진행",n,v))try{await Br(n),y("턴을 다음 단계로 이동했습니다.","success"),dt()}catch{y("턴 이동에 실패했습니다.","error")}finally{Cn()}},d=async()=>{if(!n||!on(e))return;const v=zt.value.trim();if(!v){y("먼저 Actor를 선택하세요.","warning");return}const u=Number.parseInt(Zn.value,10),p=Number.parseInt(ts.value,10);if(Number.isNaN(u)||Number.isNaN(p)){y("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(Je.value,10),g=Je.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Kr({roomId:n,actorId:v,action:Xn.value.trim()||"ability_check",statValue:u,dc:p,rawD20:g}),y("주사위 판정을 기록했습니다.","success"),dt()}catch{y("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{ct.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${zt.value}
            onChange=${v=>{zt.value=v.target.value}}
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
              value=${Xn.value}
              onInput=${v=>{Xn.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Zn.value}
              onInput=${v=>{Zn.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ts.value}
              onInput=${v=>{ts.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Je.value}
              onInput=${v=>{Je.value=v.target.value}}
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
  `}function Eu({state:t}){var a;const e=ct.value||((a=t.session)==null?void 0:a.room)||"",n=Xe.value,s=async()=>{if(!e){y("Room ID가 비어 있습니다.","warning");return}const i=Qe.value.trim(),r=as.value.trim();if(!r&&!i){y("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(be.value.trim(),10),d=Number.parseInt(cs.value.trim(),10),c=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(l)?Math.max(0,Math.min(c,l)):c;let u={};try{u=bu(us.value)}catch(p){y(p instanceof Error?p.message:"능력치 JSON 오류","error");return}Xe.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await qr(e,{actor_id:i||void 0,name:r||void 0,role:is.value,idempotencyKey:p,portrait:rs.value.trim()||void 0,background:ls.value.trim()||void 0,hp:v,max_hp:c,alive:v>0,stats:Object.keys(u).length>0?u:void 0}),g=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const k=os.value.trim();k&&await Gr(e,g,k),zt.value=g,ft.value=g,i||(Qe.value=""),Xe.value="ok",y(`Actor 생성 완료: ${g}`,"success"),await dt()}catch(p){Xe.value="error",y(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${as.value}
            onInput=${i=>{as.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${is.value}
            onChange=${i=>{is.value=i.target.value}}
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
            value=${os.value}
            onInput=${i=>{os.value=i.target.value}}
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
              value=${Qe.value}
              onInput=${i=>{Qe.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${rs.value}
              onInput=${i=>{rs.value=i.target.value}}
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
              value=${cs.value}
              onInput=${i=>{const r=i.target.value;cs.value=r,ku(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ls.value}
              onInput=${i=>{ls.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${us.value}
              onInput=${i=>{us.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Pu({state:t,nowMs:e}){var p;const n=ct.value||((p=t.session)==null?void 0:p.room)||"",s=t.join_gate,a=ss.value,i=$t(a)?a:null,r=(t.party??[]).filter(m=>m.role!=="dm"),l=ft.value.trim(),d=r.some(m=>m.id===l),c=d?l:l?"__manual__":"",v=async()=>{const m=ft.value.trim(),g=Ye.value.trim();if(!n||!m){y("Room/Actor가 필요합니다.","warning");return}V.value="checking";try{const k=await Wr(n,m,g||void 0);ss.value=k,V.value="ok",y("참가 가능 여부를 갱신했습니다.","success")}catch(k){V.value="error";const C=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";y(C,"error")}},u=async()=>{var N,T;const m=ft.value.trim(),g=Ye.value.trim(),k=ns.value.trim();if(!n||!m||!g){y("Room/Actor/Keeper가 필요합니다.","warning");return}if(!on(e))return;const C=((N=t.current_round)==null?void 0:N.phase)??((T=t.session)==null?void 0:T.status)??"unknown";if(qs("Mid-Join 승인 요청",n,C)){V.value="requesting";try{const O=await Jr({room_id:n,actor_id:m,keeper_name:g,role:es.value,...k?{name:k}:{}});ss.value=O;const U=$t(O)?Pe(O,"granted",!1):!1,D=$t(O)?q(O,"reason_code",""):"";U?y("Mid-Join이 승인되었습니다.","success"):y(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),V.value=U?"ok":"error",dt()}catch(O){V.value="error";const U=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";y(U,"error")}finally{Cn()}}};return o`
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
            value=${c}
            onChange=${m=>{const g=m.target.value;if(g==="__manual__"){(d||!l)&&(ft.value="");return}ft.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${c==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ft.value}
                onInput=${m=>{ft.value=m.target.value}}
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
            value=${Ye.value}
            onInput=${m=>{Ye.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${es.value}
            onChange=${m=>{es.value=m.target.value}}
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
            value=${ns.value}
            onInput=${m=>{ns.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${u} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Pe(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${it(i,"effective_score",0)}/${it(i,"required_points",0)}</span>
            ${q(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${q(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function po({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function vo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function mo(){const t=Ks.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=$t(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter($t).slice(-8),i=t.canon_check,r=$t(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],c=n?Pe(n,"advanced",!1):!1,v=n?q(n,"progress_reason",""):"",u=n?q(n,"progress_detail",""):"",p=n?it(n,"player_successes",0):0,m=n?it(n,"player_required_successes",0):0,g=n?Pe(n,"dm_success",!1):!1,k=n?it(n,"timeouts",0):0,C=n?it(n,"unavailable",0):0,N=n?it(n,"reprompts",0):0,T=n?it(n,"npc_attacks",0):0,O=n?it(n,"keeper_timeout_sec",0):0,U=n?it(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${c?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${c?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${u?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${u}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${U}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const Y=q(D,"status","unknown"),xt=q(D,"actor_id","-"),wt=q(D,"role","-"),Q=q(D,"reason",""),rt=q(D,"action_type",""),I=q(D,"reply","");return o`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${xt} (${wt})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${rt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${rt}</div>`:null}
                  ${Q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${I?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${I.slice(0,120)}</div>`:null}
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
  `}function Mu({state:t,nowMs:e}){var r,l,d;const n=ct.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=oo(e),i=Su(e);return o`
    <${h} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Au(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Cn(),y("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Ou({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>wu(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function ju({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${h} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${co} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${h} title="맵" style="margin-top:16px;">
              <${Ru} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${h} title="현재 라운드">
          <${vo} state=${t} />
        <//>

        <${h} title="기여도" style="margin-top:16px;">
          <${po} state=${t} />
        <//>

        <${h} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${lo} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${uo} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Fu({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title=${`이벤트 타임라인 (${e.length})`}>
          <${Iu} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${h} title="최근 라운드 결과">
          <${mo} />
        <//>

        <${h} title="현재 라운드" style="margin-top:16px;">
          <${vo} state=${t} />
        <//>
      </div>
    </div>
  `}function zu({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Mu} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${h} title="조작 패널">
            <${Du} state=${t} nowMs=${e} />
          <//>

          <${h} title="Actor Spawn" style="margin-top:16px;">
            <${Eu} state=${t} />
          <//>

          <${h} title="Mid-Join Gate" style="margin-top:16px;">
            <${Pu} state=${t} nowMs=${e} />
          <//>

          <${h} title="최근 라운드 결과" style="margin-top:16px;">
            <${mo} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${h} title="기여도" style="margin-top:0;">
            <${po} state=${t} />
          <//>

          <${h} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${lo} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${uo} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Hu(){var l,d,c,v,u;const t=Bi.value,e=Ts.value;if(ht(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{Za.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>dt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=io.value,r=Za.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ct.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>dt()}>새로고침</button>
      </div>

      <${Lu} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((u=t.current_round)==null?void 0:u.round_number)??0}</div>
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

      <${Ou} active=${i} />

      ${i==="overview"?o`<${ju} state=${t} />`:i==="timeline"?o`<${Fu} state=${t} />`:o`<${zu} state=${t} nowMs=${r} />`}
    </div>
  `}const ca="masc_dashboard_agent_name";function Uu(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ca);return e??n??"dashboard"}const nt=f(Uu()),ke=f(""),xe=f(""),Tn=f(""),we=f(!1),Kt=f(!1),Se=f(!1),Ae=f(!1),Nn=f(!1),jn=f(!1);function ua(t){const e=t.trim();nt.value=e,e&&localStorage.setItem(ca,e)}function Ku(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Gs(){const t=nt.value.trim();if(t){Se.value=!0;try{const e=await Yr(t),n=Ku(e);n&&ua(n),jn.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Se.value=!1}}}async function Bu(){const t=nt.value.trim();if(t){Ae.value=!0;try{await Ki(t),jn.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{Ae.value=!1}}}async function qu(){const t=nt.value.trim();if(t)try{await Ki(t)}catch{}localStorage.removeItem(ca),ua("dashboard"),jn.value=!1,await Gs()}async function Gu(){const t=nt.value.trim();if(t){Nn.value=!0;try{await Qr(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{Nn.value=!1}}}async function ti(){const t=nt.value.trim(),e=ke.value.trim();if(!(!t||!e)){we.value=!0;try{await Ui(t,e),ke.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{we.value=!1}}}async function Wu(){const t=xe.value.trim(),e=Tn.value.trim()||"Created from dashboard";if(t){Kt.value=!0;try{await Vr(t,e,1),xe.value="",Tn.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{Kt.value=!1}}}function Ju(){return ht(()=>{Gs()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${nt.value}
        onInput=${t=>ua(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${ke.value}
          onInput=${t=>{ke.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&ti()}}
          disabled=${we.value}
        />
        <button
          class="control-btn"
          onClick=${ti}
          disabled=${we.value||ke.value.trim()===""||nt.value.trim()===""}
        >
          ${we.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Gs()}}
          disabled=${Se.value||nt.value.trim()===""}
        >
          ${Se.value?"Joining...":jn.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Bu()}}
          disabled=${Ae.value||nt.value.trim()===""}
        >
          ${Ae.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{qu()}}
          disabled=${Se.value||Ae.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Gu()}}
          disabled=${Nn.value||nt.value.trim()===""}
        >
          ${Nn.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${xe.value}
        onInput=${t=>{xe.value=t.target.value}}
        disabled=${Kt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Tn.value}
        onInput=${t=>{Tn.value=t.target.value}}
        disabled=${Kt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Wu}
        disabled=${Kt.value||xe.value.trim()===""}
      >
        ${Kt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}const fo={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Live monitor for agent status, keeper pressure, and current execution focus",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function Vu(){const t=yt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${En.value} events</span>
    </div>
  `}function Yu(){const t=st.value.tab,e=yt.value,n=ks.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ks.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>Dn(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${fo[t]??"Live operational view"}</p>
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
            <strong>${Lt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Zt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${kt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${En.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Pn(),t==="ops"&&Yt(),t==="board"&&ut(),t==="trpg"&&dt(),t==="goals"&&(ce(),ue())}}
        >
          Refresh Now
        </button>
      </section>

      <${Ju} />
    </aside>
  `}function Qu(){switch(st.value.tab){case"overview":return o`<${Fa} />`;case"ops":return o`<${vc} />`;case"council":return o`<${$c} />`;case"board":return o`<${Nc} />`;case"execution":return o`<${su} />`;case"activity":return o`<${Uc} />`;case"agents":return o`<${tu} />`;case"tasks":return o`<${eu} />`;case"goals":return o`<${pu} />`;case"trpg":return o`<${Hu} />`;default:return o`<${Fa} />`}}function Xu(){ht(()=>{Zo(),Pi(),Pn();const e=yl();return bl(),()=>{lr(),e(),kl()}},[]),ht(()=>{const e=st.value.tab;e==="ops"&&Yt(),e==="board"&&ut(),e==="trpg"&&dt(),e==="goals"&&(ce(),ue())},[st.value.tab]);const t=st.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${fo[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${Vu} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${tr} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Cs.value&&!yt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Qu} />`}
        </main>
        <${Yu} />
      </div>

      <${El} />
      <${Ul} />
      <${Ol} />
    </div>
  `}const ei=document.getElementById("app");ei&&Po(o`<${Xu} />`,ei);
