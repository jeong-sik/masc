var Fo=Object.defineProperty;var zo=(t,e,n)=>e in t?Fo(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ot=(t,e,n)=>zo(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var jn,I,ui,di,Ct,xa,pi,vi,mi,sa,ks,xs,Ne={},fi=[],Uo=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Fn=Array.isArray;function ut(t,e){for(var n in e)t[n]=e[n];return t}function aa(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function _i(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?jn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return sn(t,r,s,a,null)}function sn(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ui,__i:-1,__u:0};return a==null&&I.vnode!=null&&I.vnode(i),i}function Oe(t){return t.children}function oe(t,e){this.props=t,this.context=e}function Yt(t,e){if(e==null)return t.__?Yt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Yt(t):null}function gi(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return gi(t)}}function wa(t){(!t.__d&&(t.__d=!0)&&Ct.push(t)&&!un.__r++||xa!=I.debounceRendering)&&((xa=I.debounceRendering)||pi)(un)}function un(){for(var t,e,n,s,a,i,r,l=1;Ct.length;)Ct.length>l&&Ct.sort(vi),t=Ct.shift(),l=Ct.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=ut({},s)).__v=s.__v+1,I.vnode&&I.vnode(n),ia(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??Yt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,yi(i,n,r),s.__e=s.__=null,n.__e!=a&&gi(n)));un.__r=0}function $i(t,e,n,s,a,i,r,l,d,u,v){var c,p,f,g,k,C,T,N=s&&s.__k||fi,O=e.length;for(d=Ho(n,e,N,d,O),c=0;c<O;c++)(f=n.__k[c])!=null&&(p=f.__i==-1?Ne:N[f.__i]||Ne,f.__i=c,C=ia(t,f,p,a,i,r,l,d,u,v),g=f.__e,f.ref&&p.ref!=f.ref&&(p.ref&&oa(p.ref,null,f),v.push(f.ref,f.__c||g,f)),k==null&&g!=null&&(k=g),(T=!!(4&f.__u))||p.__k===f.__k?d=hi(f,d,t,T):typeof f.type=="function"&&C!==void 0?d=C:g&&(d=g.nextSibling),f.__u&=-7);return n.__e=k,d}function Ho(t,e,n,s,a){var i,r,l,d,u,v=n.length,c=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=sn(null,r,null,null,null):Fn(r)?r=t.__k[i]=sn(Oe,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=sn(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=qo(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=Yt(l)),ki(l,l));return s}function hi(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=hi(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=Yt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function qo(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&l==null||v&&l==u.key&&d==u.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function Sa(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Uo.test(e)?n:n+"px"}function Be(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Sa(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Sa(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(mi,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=sa,t.addEventListener(e,i?xs:ks,i)):t.removeEventListener(e,i?xs:ks,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Aa(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=sa++;else if(e.t<n.u)return;return n(I.event?I.event(e):e)}}}function ia(t,e,n,s,a,i,r,l,d,u){var v,c,p,f,g,k,C,T,N,O,H,D,Q,St,At,X,lt,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=I.__b)&&v(e);t:if(typeof R=="function")try{if(T=e.props,N="prototype"in R&&R.prototype.render,O=(v=R.contextType)&&s[v.__c],H=v?O?O.props.value:v.__:s,n.__c?C=(c=e.__c=n.__c).__=c.__E:(N?e.__c=c=new R(T,H):(e.__c=c=new oe(T,H),c.constructor=R,c.render=Bo),O&&O.sub(c),c.state||(c.state={}),c.__n=s,p=c.__d=!0,c.__h=[],c._sb=[]),N&&c.__s==null&&(c.__s=c.state),N&&R.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=ut({},c.__s)),ut(c.__s,R.getDerivedStateFromProps(T,c.__s))),f=c.props,g=c.state,c.__v=e,p)N&&R.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),N&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(N&&R.getDerivedStateFromProps==null&&T!==f&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(T,H),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(T,c.__s,H)===!1){for(e.__v!=n.__v&&(c.props=T,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),D=0;D<c._sb.length;D++)c.__h.push(c._sb[D]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(T,c.__s,H),N&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(f,g,k)})}if(c.context=H,c.props=T,c.__P=t,c.__e=!1,Q=I.__r,St=0,N){for(c.state=c.__s,c.__d=!1,Q&&Q(e),v=c.render(c.props,c.state,c.context),At=0;At<c._sb.length;At++)c.__h.push(c._sb[At]);c._sb=[]}else do c.__d=!1,Q&&Q(e),v=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++St<25);c.state=c.__s,c.getChildContext!=null&&(s=ut(ut({},s),c.getChildContext())),N&&!p&&c.getSnapshotBeforeUpdate!=null&&(k=c.getSnapshotBeforeUpdate(f,g)),X=v,v!=null&&v.type===Oe&&v.key==null&&(X=bi(v.props.children)),l=$i(t,Fn(X)?X:[X],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),C&&(c.__E=c.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(lt=i.length;lt--;)aa(i[lt]);ws(e)}else e.__e=n.__e,e.__k=n.__k,z.then||ws(e);I.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Ko(n.__e,e,n,s,a,i,r,d,u);return(v=I.diffed)&&v(e),128&e.__u?void 0:l}function ws(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ws)}function yi(t,e,n){for(var s=0;s<n.length;s++)oa(n[s],n[++s],n[++s]);I.__c&&I.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){I.__e(i,a.__v)}})}function bi(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Fn(t)?t.map(bi):ut({},t)}function Ko(t,e,n,s,a,i,r,l,d){var u,v,c,p,f,g,k,C=n.props||Ne,T=e.props,N=e.type;if(N=="svg"?a="http://www.w3.org/2000/svg":N=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((f=i[u])&&"setAttribute"in f==!!N&&(N?f.localName==N:f.nodeType==3)){t=f,i[u]=null;break}}if(t==null){if(N==null)return document.createTextNode(T);t=document.createElementNS(a,N,T.is&&T),l&&(I.__m&&I.__m(e,i),l=!1),i=null}if(N==null)C===T||l&&t.data==T||(t.data=T);else{if(i=i&&jn.call(t.childNodes),!l&&i!=null)for(C={},u=0;u<t.attributes.length;u++)C[(f=t.attributes[u]).name]=f.value;for(u in C)if(f=C[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=f;else if(!(u in T)){if(u=="value"&&"defaultValue"in T||u=="checked"&&"defaultChecked"in T)continue;Be(t,u,null,f,a)}}for(u in T)f=T[u],u=="children"?p=f:u=="dangerouslySetInnerHTML"?v=f:u=="value"?g=f:u=="checked"?k=f:l&&typeof f!="function"||C[u]===f||Be(t,u,f,C[u],a);if(v)l||c&&(v.__html==c.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(c&&(t.innerHTML=""),$i(e.type=="template"?t.content:t,Fn(p)?p:[p],e,n,s,N=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&Yt(n,0),l,d),i!=null)for(u=i.length;u--;)aa(i[u]);l||(u="value",N=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[u]||N=="progress"&&!g||N=="option"&&g!=C[u])&&Be(t,u,g,C[u],a),u="checked",k!=null&&k!=t[u]&&Be(t,u,k,C[u],a))}return t}function oa(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){I.__e(a,n)}}function ki(t,e,n){var s,a;if(I.unmount&&I.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||oa(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){I.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&ki(s[a],e,n||typeof t.type!="function");n||aa(t.__e),t.__c=t.__=t.__e=void 0}function Bo(t,e,n){return this.constructor(t,n)}function Go(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),I.__&&I.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],ia(e,t=e.__k=_i(Oe,null,[t]),a||Ne,Ne,e.namespaceURI,a?null:e.firstChild?jn.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),yi(i,t,r)}jn=fi.slice,I={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},ui=0,di=function(t){return t!=null&&t.constructor===void 0},oe.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=ut({},this.state),typeof t=="function"&&(t=t(ut({},n),this.props)),t&&ut(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),wa(this))},oe.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),wa(this))},oe.prototype.render=Oe,Ct=[],pi=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,vi=function(t,e){return t.__v.__b-e.__v.__b},un.__r=0,mi=/(PointerCapture)$|Capture$/i,sa=0,ks=Aa(!1),xs=Aa(!0);var xi=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,xi(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Ca=new Map;function Jo(t){var e=Ca.get(this);return e||(e=new Map,Ca.set(this,e)),(e=xi(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&u(),u(v));for(var c=0;c<n[v].length;c++)s=n[v][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Jo.bind(_i),Te,j,Gn,Na,Ss=0,wi=[],F=I,Ta=F.__b,La=F.__r,Ra=F.diffed,Ia=F.__c,Da=F.unmount,Ma=F.__;function ra(t,e){F.__h&&F.__h(j,t,Ss||e),Ss=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Ge(t){return Ss=1,Wo(Ci,t)}function Wo(t,e,n){var s=ra(Te++,2);if(s.t=t,!s.__c&&(s.__=[Ci(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,l);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=j,!j.__f)){var a=function(l,d,u){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,u);var c=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var f=p.__[0];p.__=p.__N,p.__N=void 0,f!==p.__[0]&&(c=!0)}}),i&&i.call(this,l,d,u)||c};j.__f=!0;var i=j.shouldComponentUpdate,r=j.componentWillUpdate;j.componentWillUpdate=function(l,d,u){if(this.__e){var v=i;i=void 0,a(l,d,u),i=v}r&&r.call(this,l,d,u)},j.shouldComponentUpdate=a}return s.__N||s.__}function mt(t,e){var n=ra(Te++,3);!F.__s&&Ai(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function Si(t,e){var n=ra(Te++,7);return Ai(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Vo(){for(var t;t=wi.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(an),t.__H.__h.forEach(As),t.__H.__h=[]}catch(e){t.__H.__h=[],F.__e(e,t.__v)}}F.__b=function(t){j=null,Ta&&Ta(t)},F.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Ma&&Ma(t,e)},F.__r=function(t){La&&La(t),Te=0;var e=(j=t.__c).__H;e&&(Gn===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(an),e.__h.forEach(As),e.__h=[],Te=0)),Gn=j},F.diffed=function(t){Ra&&Ra(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(wi.push(e)!==1&&Na===F.requestAnimationFrame||((Na=F.requestAnimationFrame)||Yo)(Vo)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Gn=j=null},F.__c=function(t,e){e.some(function(n){try{n.__h.forEach(an),n.__h=n.__h.filter(function(s){return!s.__||As(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],F.__e(s,n.__v)}}),Ia&&Ia(t,e)},F.unmount=function(t){Da&&Da(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{an(s)}catch(a){e=a}}),n.__H=void 0,e&&F.__e(e,n.__v))};var Ea=typeof requestAnimationFrame=="function";function Yo(t){var e,n=function(){clearTimeout(s),Ea&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Ea&&(e=requestAnimationFrame(n))}function an(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function As(t){var e=j;t.__c=t.__(),j=e}function Ai(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Ci(t,e){return typeof e=="function"?e(t):e}var Qo=Symbol.for("preact-signals");function zn(){if(ht>1)ht--;else{for(var t,e=!1;re!==void 0;){var n=re;for(re=void 0,Cs++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Li(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Cs=0,ht--,e)throw t}}function Xo(t){if(ht>0)return t();ht++;try{return t()}finally{zn()}}var L=void 0;function Ni(t){var e=L;L=void 0;try{return t()}finally{L=e}}var re=void 0,ht=0,Cs=0,dn=0;function Ti(t){if(L!==void 0){var e=t.n;if(e===void 0||e.t!==L)return e={i:0,S:t,p:L.s,n:void 0,t:L,e:void 0,x:void 0,r:e},L.s!==void 0&&(L.s.n=e),L.s=e,t.n=e,32&L.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=L.s,e.n=void 0,L.s.n=e,L.s=e),e}}function U(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}U.prototype.brand=Qo;U.prototype.h=function(){return!0};U.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ni(function(){var s;(s=e.W)==null||s.call(e)}))};U.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ni(function(){var a;(a=e.Z)==null||a.call(e)}))}};U.prototype.subscribe=function(t){var e=this;return je(function(){var n=e.value,s=L;L=void 0;try{t(n)}finally{L=s}},{name:"sub"})};U.prototype.valueOf=function(){return this.value};U.prototype.toString=function(){return this.value+""};U.prototype.toJSON=function(){return this.value};U.prototype.peek=function(){var t=L;L=void 0;try{return this.value}finally{L=t}};Object.defineProperty(U.prototype,"value",{get:function(){var t=Ti(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Cs>100)throw new Error("Cycle detected");this.v=t,this.i++,dn++,ht++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{zn()}}}});function m(t,e){return new U(t,e)}function Li(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ri(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Ii(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function It(t,e){U.call(this,void 0),this.x=t,this.s=void 0,this.g=dn-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}It.prototype=new U;It.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===dn))return!0;if(this.g=dn,this.f|=1,this.i>0&&!Li(this))return this.f&=-2,!0;var t=L;try{Ri(this),L=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return L=t,Ii(this),this.f&=-2,!0};It.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}U.prototype.S.call(this,t)};It.prototype.U=function(t){if(this.t!==void 0&&(U.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};It.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(It.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ti(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function J(t,e){return new It(t,e)}function Di(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ht++;var n=L;L=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,la(t),s}finally{L=n,zn()}}}function la(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Di(t)}function Zo(t){if(L!==this)throw new Error("Out-of-order effect");Ii(this),L=t,this.f&=-2,8&this.f&&la(this),zn()}function te(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}te.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};te.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Di(this),Ri(this),ht++;var t=L;return L=this,Zo.bind(this,t)};te.prototype.N=function(){2&this.f||(this.f|=2,this.o=re,re=this)};te.prototype.d=function(){this.f|=8,1&this.f||la(this)};te.prototype.dispose=function(){this.d()};function je(t,e){var n=new te(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Mi,Je,tr=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ei=[];je(function(){Mi=this.N})();function ee(t,e){I[t]=e.bind(null,I[t]||function(){})}function pn(t){if(Je){var e=Je;Je=void 0,e()}Je=t&&t.S()}function Pi(t){var e=this,n=t.data,s=nr(n);s.value=n;var a=Si(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=J(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),v=J(function(){return!Array.isArray(u.value)&&!di(u.value)}),c=je(function(){if(this.N=Oi,v.value){var f=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=f)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[v,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Pi.displayName="ReactiveTextNode";Object.defineProperties(U.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Pi},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});ee("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof U&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});ee("__r",function(t,e){if(t(e),e.type!==Oe){pn();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return je(function(){r=this},{name:i}),r.c=a,r})(function(){var a;tr&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),pn(n)}});ee("__e",function(t,e,n,s){pn(),t(e,n,s)});ee("diffed",function(t,e){pn();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],v=s[d];u===void 0?(u=er(n,d,v),i[d]=u):u.o(v,a)}for(var c in s)a[c]=s[c]}}t(e)});function er(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=m(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:je(function(){this.N=Oi;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}ee("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});ee("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});oe.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function nr(t,e){return Si(function(){return m(t,e)},[])}var sr=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ar(){Xo(function(){for(var t;t=Ei.shift();)Mi.call(t)})}function Oi(){Ei.push(this)===1&&(I.requestAnimationFrame||sr)(ar)}const ir=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],ji={tab:"overview",params:{},postId:null},or={journal:"activity",mdal:"goals"};function Pa(t){return!!t&&ir.includes(t)}function Oa(t){if(t)return or[t]??t}function Ns(t){try{return decodeURIComponent(t)}catch{return t}}function Ts(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function rr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Fi(t,e){const n=Oa(t[0]),s=Oa(e.tab),a=Pa(n)?n:Pa(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ns(t[2]):t[0]==="post"&&t[1]&&(i=Ns(t[1]))),{tab:a,params:e,postId:i}}function vn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ji;const n=Ns(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Ts(a),r=rr(s);return Fi(r,i)}function lr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ji,params:Ts(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ts(e.replace(/^\?/,""));return Fi(s,a)}function zi(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const st=m(vn(window.location.hash));window.addEventListener("hashchange",()=>{st.value=vn(window.location.hash)});function Un(t,e){const n={tab:t,params:{},postId:null};window.location.hash=zi(n)}function cr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ur(){if(window.location.hash&&window.location.hash!=="#"){st.value=vn(window.location.hash);return}const t=lr(window.location.pathname,window.location.search);if(t){st.value=t;const e=zi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",st.value=vn(window.location.hash)}const Ls=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function dr(){const t=st.value.tab;return o`
    <div class="main-tab-bar">
      ${Ls.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Un(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ja="masc_dashboard_sse_session_id",pr=1e3,vr=15e3,bt=m(!1),Hn=m(0),Ui=m(null),Qt=m([]);function mr(){let t=sessionStorage.getItem(ja);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ja,t)),t}const fr=200;function _r(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};Qt.value=[a,...Qt.value].slice(0,fr)}function Rs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Fa(t,e){const n=Rs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Z(t,e,n,s,a={}){_r(t,e,n,{eventType:s,...a})}let ot=null,Jt=null,Is=0;function Hi(){Jt&&(clearTimeout(Jt),Jt=null)}function gr(){if(Jt)return;Is++;const t=Math.min(Is,5),e=Math.min(vr,pr*Math.pow(2,t));Jt=setTimeout(()=>{Jt=null,qi()},e)}function qi(){Hi(),ot&&(ot.close(),ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",mr());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);ot=i,i.onopen=()=>{ot===i&&(Is=0,bt.value=!0)},i.onerror=()=>{ot===i&&(bt.value=!1,i.close(),ot=null,gr())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Hn.value++,Ui.value=l,$r(l)}catch{}}}function $r(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Z(n,"Joined","system","agent_joined");break;case"agent_left":Z(n,"Left","system","agent_left");break;case"broadcast":Z(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Z(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Z(n,Fa("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Rs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Z(n,Fa("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Rs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Z(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Z(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Z(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Z(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Z(n,e,"system","unknown")}}function hr(){Hi(),ot&&(ot.close(),ot=null),bt.value=!1}function Ki(){return new URLSearchParams(window.location.search)}function Bi(){const t=Ki(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Gi(){return{...Bi(),"Content-Type":"application/json"}}const yr=15e3,Ji=3e4,br=6e4,za=new Set([408,425,429,500,502,503,504]);class Fe extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ot(this,"method");Ot(this,"path");Ot(this,"status");Ot(this,"statusText");Ot(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ca(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Fe({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function kr(){var e,n;const t=Ki();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ft(t){const e=await ca(t,{headers:Bi()},yr);if(!e.ok)throw new Fe({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function xr(t){return new Promise(e=>setTimeout(e,t))}function wr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Sr(t){if(t instanceof Fe)return t.timeout||typeof t.status=="number"&&za.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=wr(t.message);return e!==null&&za.has(e)}async function ze(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Sr(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await xr(i),s+=1}}async function _t(t,e,n){const s=await ca(t,{method:"POST",headers:{...Gi(),...n??{}},body:JSON.stringify(e)},Ji);if(!s.ok)throw new Fe({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function Ar(t,e,n,s=Ji){const a=await ca(t,{method:"POST",headers:{...Gi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Fe({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Cr(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Nr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function K(t,e){const n=await Ar("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},br),s=Cr(n);return Nr(s)}function Tr(t="compact"){return ft(`/api/v1/dashboard?mode=${t}`)}function Lr(){return ft("/api/v1/operator")}function Wi(t){return _t("/api/v1/operator/action",t)}function Rr(t,e){return _t("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Xt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ir(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Vi(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=w(t.score,0),i=w(t.votes_up,0),r=w(t.votes_down,0),l=w(t.votes,a||i-r),d=w(t.comment_count,w(t.reply_count,0)),u=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(S(g)){const C=_(g.name,"").trim();if(C)return C}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||Xt(t.created_at),c=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Xt(t.updated_at):v),f=_(t.title,"").trim()||Ir(s);return{id:e,author:n,title:f,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:v,updated_at:c,flair:u,hearth_count:w(t.hearth_count,0)}}function Dr(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:Xt(t.created_at)}}async function Mr(t,e){return ze("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit","100");const s=n.toString(),a=await ft(`/api/v1/board${s?`?${s}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(Vi).filter(r=>r!==null):[]}})}async function Er(t){return ze("fetchBoardPost",async()=>{const e=await ft(`/api/v1/board/${t}?format=flat`),n=S(e.post)?e.post:e,s=Vi(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Dr).filter(r=>r!==null);return{...s,comments:i}})}function Yi(t,e){return _t("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:kr()})}function Pr(t,e,n){return _t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Or(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function q(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function Ua(t){const e=Or(q(t.outcome,t.result,t.result_code));if(!e)return;const n=q(t.reason,t.reason_code,t.description,t.detail),s=q(t.summary,t.summary_ko,t.summary_en,t.note),a=q(t.details,t.details_text,t.text,t.note),i=q(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=q(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=q(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(p=>{if(typeof p=="string")return p.trim();if(S(p)){const f=_(p.summary,"").trim();if(f)return f;const g=_(p.text,"").trim();if(g)return g;const k=_(p.type,"").trim();return k||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const c=w(t.turn,Number.NaN);if(Number.isFinite(c))return c;const p=w(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const f=w(t.current_turn,Number.NaN);if(Number.isFinite(f))return f;const g=w(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=q(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:u,phase:v||void 0}}function jr(t,e){const n=S(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>S(r)?_(r.type,"")==="session.outcome":!1),i=S(n.session_outcome)?n.session_outcome:{};if(S(i)&&Object.keys(i).length>0){const r=Ua(i);if(r)return r}if(S(a))return Ua(S(a.payload)?a.payload:{})}function S(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function w(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function $t(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ds(t,e=!1){return typeof t=="boolean"?t:e}function se(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(S(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Fr(t){const e={};if(!S(t)&&!Array.isArray(t))return e;if(S(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!S(n))continue;const s=q(n.to,n.target,n.actor_id,n.name,n.id),a=q(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function zr(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function W(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Ur=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Hr(t){const e=S(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Ur.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function qr(t,e){if(t!=="dice.rolled")return;const n=w(e.raw_d20,0),s=w(e.total,0),a=w(e.bonus,0),i=_(e.action,"roll"),r=w(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Kr(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Br(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Gr(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=w(s.total,0),l=w(s.dc,0),d=_(s.label,""),u=a||"actor",v=l>0?` vs DC ${l}`:"",c=d?` (${d})`:"";return`${u} ${i}: ${r}${v}${c}`}case"turn.started":return`Turn ${w(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,S(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${w(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${w(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=S(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),d=Ds(i.guardrail_applied,!1),u=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return u;const v=r&&l?`${r}->${l}`:l||r;return`${u} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Kr(s);return i?`${t}: ${i}`:t}}}function Jr(t,e){const n=S(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(S(n.payload)?n.payload.actor_name:"",""),r=S(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),u=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:u||Br(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:Gr(s,a,i,r),dice_roll:qr(s,r),timestamp:l}}function Wr(t,e,n){var X,lt;const s=_(t.room_id,"")||n||"default",a=S(t.state)?t.state:{},i=S(a.party)?a.party:{},r=S(a.actor_control)?a.actor_control:{},l=S(a.join_gate)?a.join_gate:{},d=S(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([R,z])=>{const $=S(z)?z:{},Ke=W($,"max_hp",void 0,10),ya=W($,"hp",void 0,Ke),Co=W($,"max_mp",void 0,0),No=W($,"mp",void 0,0),To=W($,"level",void 0,1),Lo=W($,"xp",void 0,0),Ro=Ds($.alive,ya>0),ba=r[R],ka=typeof ba=="string"?ba:void 0,Io=zr($.role,R,ka),Do=$t($.generation),Mo=q($.joined_at,$.joinedAt,$.started_at,$.startedAt),Eo=q($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),Po=q($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Oo=q($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),jo=q($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:R,name:_($.name,R),role:Io,keeper:ka,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:se($.traits),skills:se($.skills),stats_raw:Hr($),status:Ro?"active":"dead",generation:Do,joined_at:Mo||void 0,claimed_at:Eo||void 0,last_seen:Po||void 0,scene:Oo||void 0,location:jo||void 0,inventory:se($.inventory),notes:se($.notes),relationships:Fr($.relationships),stats:{hp:ya,max_hp:Ke,mp:No,max_mp:Co,level:To,xp:Lo,strength:W($,"strength","str",10),dexterity:W($,"dexterity","dex",10),constitution:W($,"constitution","con",10),intelligence:W($,"intelligence","int",10),wisdom:W($,"wisdom","wis",10),charisma:W($,"charisma","cha",10)}}}),v=u.filter(R=>R.status!=="dead"),c=jr(t,e),p={phase_open:Ds(l.phase_open,!0),min_points:w(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},f=Object.entries(d).map(([R,z])=>{const $=S(z)?z:{};return{actor_id:R,score:w($.score,0),last_reason:_($.last_reason,"")||null,reasons:se($.reasons)}}),g=u.reduce((R,z)=>(R[z.id]=z.name,R),{}),k=e.map(R=>Jr(R,g)),C=w(a.turn,1),T=_(a.phase,"round"),N=_(a.map,""),O=S(a.world)?a.world:{},H=N||_(O.ascii_map,_(O.map,"")),D=k.filter((R,z)=>{const $=e[z];if(!S($))return!1;const Ke=S($.payload)?$.payload:{};return w(Ke.turn,-1)===C}),Q=(D.length>0?D:k).slice(-12),St=_(a.status,"active");return{session:{id:s,room:s,status:St==="ended"?"ended":St==="paused"?"paused":"active",round:C,actors:v,created_at:((X=k[0])==null?void 0:X.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:T,events:Q,timestamp:((lt=k[k.length-1])==null?void 0:lt.timestamp)??new Date().toISOString()},map:H||void 0,join_gate:p,contribution_ledger:f,outcome:c,party:v,story_log:k,history:[]}}async function Vr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ft(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Yr(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ft(`/api/v1/trpg/state${e}`),Vr(t)]);return Wr(n,s,t)}function Qr(t){return _t("/api/v1/trpg/rounds/run",{room_id:t})}function Xr(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Zr(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),_t("/api/v1/trpg/dice/roll",e)}function tl(t,e){const n=Xr();return _t("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function el(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),_t("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function nl(t,e,n){return _t("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function sl(t,e,n){const s=await K("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function al(t){const e=await K("trpg.mid_join.request",t);return JSON.parse(e)}async function Qi(t,e){await K("masc_broadcast",{agent_name:t,message:e})}async function il(t,e,n=1){await K("masc_add_task",{title:t,description:e,priority:n})}async function ol(t){return K("masc_join",{agent_name:t})}async function Xi(t){await K("masc_leave",{agent_name:t})}async function rl(t){await K("masc_heartbeat",{agent_name:t})}async function ll(t=40){return(await K("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function cl(t,e=20){return K("masc_task_history",{task_id:t,limit:e})}async function ul(){return ze("fetchDebates",async()=>{const t=await ft("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:w(e.argument_count,0),created_at:Xt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function dl(){return ze("fetchCouncilSessions",async()=>{const t=await ft("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:w(e.votes,0),quorum:w(e.quorum,0),state:_(e.state,"open"),created_at:Xt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function pl(t){const e=await K("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function vl(t){return ze("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ft(`/api/v1/council/debates/${e}/summary`);if(!S(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:w(n.support_count,0),oppose_count:w(n.oppose_count,0),neutral_count:w(n.neutral_count,0),total_arguments:w(n.total_arguments,0),created_at:Xt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function ml(t,e,n){return K("masc_keeper_msg",{name:t,message:e})}function fl(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function _l(t){return S(t)?{iteration:$t(t.iteration)??0,metric_before:w(t.metric_before,0),metric_after:w(t.metric_after,0),delta:w(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:$t(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function gl(t){if(!S(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(_l).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:fl(t.status),current_iteration:$t(t.iteration)??$t(t.current_iteration)??0,max_iterations:$t(t.max_iterations)??0,baseline_metric:w(t.baseline_metric,0),current_metric:w(t.current_metric,w(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:$t(t.stagnation_streak)??0,stagnation_limit:$t(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds,0),history:n}}async function $l(){try{const t=await K("masc_mdal_status",{}),e=JSON.parse(t);if(S(e)&&_(e.error,"").trim()!=="")return{state:"idle"};const n=gl(e);return n?{state:"ready",loop:n}:{state:"error"}}catch{return{state:"error"}}}async function hl(){try{const t=await K("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Dt=m([]),xt=m([]),Ue=m([]),Mt=m([]),wt=m(null),ie=m(null),Ms=m(new Map),ua=m([]),Le=m("hot"),Nt=m(!0),Zi=m(null),dt=m(""),Re=m([]),qt=m(!1),et=m(new Map),Es=m(!1),Ie=m(!1),Ps=m(!1),Kt=m(!1),yl=m(null),Os=m(null),to=m(null),eo=m(null),no=J(()=>Dt.value.filter(t=>t.status==="active"||t.status==="idle")),da=J(()=>{const t=xt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function bl(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const kl=J(()=>{const t=new Map;for(const e of Mt.value)t.set(e.name,bl(e));return t}),xl=12e4,wl=J(()=>{const t=Date.now(),e=new Set,n=Ms.value;for(const s of Mt.value){const a=n.get(s.name);a!=null&&t-a>xl&&e.add(s.name)}return e}),mn={},Sl=5e3;function fn(){delete mn.compact,delete mn.full}function nt(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function le(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function so(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Al(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Cl(t){if(!nt(t))return null;const e=b(t.name);return e?{name:e,status:so(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:le(t.traits),interests:le(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Nl(t){if(!nt(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Al(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Tl(t){if(!nt(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",s=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:s,type:b(t.type)}}function Ll(t){return Array.isArray(t)?t.map(e=>{if(!nt(e))return null;const n=A(e.ts_unix);if(n==null)return null;const s=nt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?A(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Rl(t){return(Array.isArray(t)?t:nt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!nt(n))return null;const s=nt(n.agent)?n.agent:null,a=nt(n.context)?n.context:null,i=nt(n.metrics_window)?n.metrics_window:void 0,r=b(n.name);if(!r)return null;const l=A(n.context_ratio)??A(a==null?void 0:a.context_ratio),d=b(n.status)??b(s==null?void 0:s.status)??"offline",u=so(d),v=b(n.model)??b(n.active_model)??b(n.primary_model),c=le(n.skill_secondary),p=a?{source:b(a.source),context_ratio:A(a.context_ratio),context_tokens:A(a.context_tokens),context_max:A(a.context_max),message_count:A(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,f=s?{name:b(s.name),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen)}:void 0,g=Ll(n.metrics_series);return{name:r,emoji:b(n.emoji),koreanName:b(n.koreanName)??b(n.korean_name),agent_name:b(n.agent_name),trace_id:b(n.trace_id),model:v,primary_model:b(n.primary_model),active_model:b(n.active_model),next_model_hint:b(n.next_model_hint)??null,status:u,last_heartbeat:b(n.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:A(n.generation),turn_count:A(n.turn_count)??A(n.total_turns),context_ratio:l,context_tokens:A(n.context_tokens)??A(a==null?void 0:a.context_tokens),context_max:A(n.context_max)??A(a==null?void 0:a.context_max),context_source:b(n.context_source)??b(a==null?void 0:a.source),context:p,traits:le(n.traits),interests:le(n.interests),primaryValue:b(n.primaryValue)??b(n.primary_value),activityLevel:A(n.activityLevel)??A(n.activity_level),memory_recent_note:b(n.memory_recent_note)??null,conversation_tail_count:A(n.conversation_tail_count),k2k_count:A(n.k2k_count),handoff_count_total:A(n.handoff_count_total)??A(n.trace_history_count),compaction_count:A(n.compaction_count),last_compaction_saved_tokens:A(n.last_compaction_saved_tokens),skill_primary:b(n.skill_primary)??null,skill_secondary:c,skill_reason:b(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:f}}).filter(n=>n!==null)}async function He(t="full"){var s,a,i;const e=Date.now(),n=mn[t];if(!(n&&e-n.time<Sl)){Es.value=!0;try{const r=await Tr(t);mn[t]={data:r,time:e},Dt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Cl).filter(l=>l!==null),xt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Nl).filter(l=>l!==null),Ue.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Tl).filter(l=>l!==null),Mt.value=Rl(r.keepers),wt.value=nt(r.status)?r.status:null,ie.value=r.perpetual??null,yl.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Es.value=!1}}}async function pt(){Ie.value=!0;try{const t=await Mr(Le.value,{excludeSystem:Nt.value});ua.value=t.posts??[],Os.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Ie.value=!1}}async function vt(){var t;Ps.value=!0;try{const e=dt.value||((t=wt.value)==null?void 0:t.room)||"default";dt.value||(dt.value=e);const n=await Yr(e);Zi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ps.value=!1}}async function ce(){qt.value=!0;try{const t=await hl();Re.value=Array.isArray(t)?t:[],to.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{qt.value=!1}}async function ue(){const t=++Vn;Kt.value=!0;try{const e=await $l();if(t!==Vn||e.state==="error")return;if(eo.value=new Date().toISOString(),e.state==="idle"){const i=new Map(et.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});et.value=i;return}const n=e.loop,s=new Map(et.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),et.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===Vn&&(Kt.value=!1)}}let Jn=null,Wn=null,Vn=0;function Il(){return Ui.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ms.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ms.value=n}if(fn(),Jn||(Jn=setTimeout(()=>{He(),Jn=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Wn||(Wn=setTimeout(()=>{pt(),Wn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&fn(),e.type==="mdal_started"&&e.loop_id){const n=new Map(et.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),et.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(et.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),et.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(et.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),et.value=n}}})}let de=null;function Dl(){de||(de=setInterval(()=>{fn(),He()},1e4))}function Ml(){de&&(clearInterval(de),de=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function at({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function El(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function P({timestamp:t}){const e=El(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function We(t){return(t??"").trim().toLowerCase()}function jt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ha(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function pa(t,e,n,s){const a=We(t),i=e.filter(v=>We(v.assignee)===a&&(v.status==="claimed"||v.status==="in_progress")).length,r=n.filter(v=>We(v.from)===a).sort((v,c)=>jt(c.timestamp)-jt(v.timestamp))[0],l=s.filter(v=>We(v.agent)===a).sort((v,c)=>jt(c.timestamp)-jt(v.timestamp))[0],d=r?jt(r.timestamp):0,u=l?jt(l.timestamp):0;return d===0&&u===0?{activeAssignedCount:i,lastActivityAt:null,lastActivityText:i>0?`${i} claimed tasks`:null}:d>=u&&r?{activeAssignedCount:i,lastActivityAt:r.timestamp,lastActivityText:Ha(r.content)}:{activeAssignedCount:i,lastActivityAt:l?new Date(l.timestamp).toISOString():null,lastActivityText:l?Ha(l.text):null}}const va=m(null);function ao(t){va.value=t}function qa(){va.value=null}const zt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Pl(t){if(!t)return 0;const e=zt.findIndex(n=>n.level===t);return e>=0?e:0}function Ol({keeper:t}){const e=Pl(t.autonomy_level),n=zt[e]??zt[0];if(!n)return null;const s=(e+1)/zt.length*100;return o`
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
            <strong><${P} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function on(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function jl({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${on(t.context_tokens)}</div>
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
  `}function Fl({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,f=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,f)=>{const g=a+f/(i-1)*(n-2*a),k=s-a-(p.context_ratio??0)*(s-2*a);return{x:g,y:k,p}}),l=r.map(({x:p,y:f})=>`${p.toFixed(1)},${f.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:f})=>o`
          <circle cx="${p.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Yn=m("");function zl({keeper:t}){var a,i,r,l;const e=Yn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Yn.value}
        onInput=${d=>{Yn.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${on(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${on(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${on(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Ul({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Hl({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ql({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ka({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Qn(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Kl({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Qn(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Qn(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Qn(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Bl({keeperName:t}){const[e,n]=Ge("Loading internal monologue..."),[s,a]=Ge(""),[i,r]=Ge([]),[l,d]=Ge(!1),u=async()=>{try{const c=await K("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};mt(()=>{u()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const c=s;a(""),r(p=>[...p,{role:"You",text:c}]);try{const p=await K("masc_keeper_msg",{name:t,message:c});r(f=>[...f,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(f=>[...f,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
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
  `}function Gl(){var e,n,s;const t=va.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&qa()}}
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
            onClick=${()=>qa()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${jl} keeper=${t} />

        ${""}
        <${Fl} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${zl} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${Ka} traits=${t.traits??[]} label="Traits" />
            <${Ka} traits=${t.interests??[]} label="Interests" />
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
              <${y} title="Autonomy">
                <${Ol} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${Ul} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${Hl} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${ql} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${Kl} keeper=${t} />
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
        <${Bl} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Jl=0;const Tt=m([]);function h(t,e="success",n=4e3){const s=++Jl;Tt.value=[...Tt.value,{id:s,message:t,type:e}],setTimeout(()=>{Tt.value=Tt.value.filter(a=>a.id!==s)},n)}function Wl(t){Tt.value=Tt.value.filter(e=>e.id!==t)}function Vl(){const t=Tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Wl(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Yl="masc_dashboard_agent_name",ne=m(null),_n=m(!1),De=m(""),gn=m([]),Me=m([]),Wt=m(""),pe=m(!1);function io(t){ne.value=t,ma()}function Ba(){ne.value=null,De.value="",gn.value=[],Me.value=[],Wt.value=""}function Ql(){const t=ne.value;return t?Dt.value.find(e=>e.name===t)??null:null}function oo(t){return t?xt.value.filter(e=>e.assignee===t):[]}async function ma(){const t=ne.value;if(t){_n.value=!0,De.value="",gn.value=[],Me.value=[];try{const e=await ll(80);gn.value=e.filter(a=>a.includes(t)).slice(0,20);const n=oo(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await cl(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Me.value=s}catch(e){De.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{_n.value=!1}}}async function Ga(){var s;const t=ne.value,e=Wt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Yl))==null?void 0:s.trim())||"dashboard";pe.value=!0;try{await Qi(n,`@${t} ${e}`),Wt.value="",h(`Mention sent to ${t}`,"success"),ma()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";h(i,"error")}finally{pe.value=!1}}function Xl({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${at} status=${t.status} />
    </div>
  `}function Zl({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function tc(){var a,i,r,l;const t=ne.value;if(!t)return null;const e=Ql(),n=oo(t),s=gn.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ba()}}
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
            <button class="control-btn ghost" onClick=${()=>{ma()}} disabled=${_n.value}>
              ${_n.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ba}>Close</button>
          </div>
        </div>

        ${De.value?o`<div class="council-error">${De.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Xl} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${Me.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Me.value.map(d=>o`<${Zl} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Wt.value}
              onInput=${d=>{Wt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Ga()}}
              disabled=${pe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ga()}}
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
  `}function ec({agent:t}){const e=pa(t.name,xt.value,Ue.value,Qt.value);return o`
    <div class="agent" onClick=${()=>io(t.name)} style="cursor: pointer">
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
  `}function nc(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ja(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function sc({keeper:t}){var r;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=kl.value.get(t.name),a=wl.value.has(t.name),i=((r=t.agent)==null?void 0:r.current_task)??"No current task";return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>ao(t)} style="cursor: pointer">
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
              <div class="keeper-ctx-fill ${Ja(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Ja(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${nc(t.context_tokens)})`:null}
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
  `}function $n(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function js(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function ac(t){return t?t.enabled?t.quiet_active?`Quiet hours ${$n(t.quiet_start)}-${$n(t.quiet_end)} KST are active. Scheduled ticks may appear asleep until the window ends.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${js(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${js(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function ic({lodge:t}){var s,a,i;const e=((a=(s=t==null?void 0:t.last_tick_result)==null?void 0:s.acted_names)==null?void 0:a.join(", "))||"none",n=((i=t==null?void 0:t.active_self_heartbeats)==null?void 0:i.length)??0;return o`
    <${y} title="Lodge Runtime" class="section">
      <div class=${`lodge-banner ${t!=null&&t.enabled?"is-enabled":"is-disabled"}`}>
        <div class="lodge-banner-meta">
          <span class=${`pill lodge-banner-pill ${t!=null&&t.enabled?"is-on":"is-off"}`}>
            ${t!=null&&t.enabled?"enabled":"disabled"}
          </span>
          <span class="pill">every ${js(t==null?void 0:t.interval_s)}</span>
          <span class="pill">quiet ${$n(t==null?void 0:t.quiet_start)}-${$n(t==null?void 0:t.quiet_end)} KST</span>
          <span class="pill">${t!=null&&t.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${t!=null&&t.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${t!=null&&t.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>
        <div class="lodge-banner-copy">${ac(t)}</div>
        <div class="lodge-banner-copy">
          Last tick: ${(t==null?void 0:t.last_tick_ago)??"never"} · Last acted: ${e} · Self-heartbeats: ${n}
        </div>
      </div>
    <//>
  `}function Wa(){var r,l,d,u,v;const t=wt.value,e=Dt.value,n=Mt.value,s=da.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${Ft} label="Agents" value=${e.length} />
      <${Ft} label="Active" value=${no.value.length} color="#4ade80" />
      <${Ft} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Ft} label="Tasks" value=${xt.value.length} />
      <${Ft} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${Ft} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <${ic} lodge=${t==null?void 0:t.lodge} />

    ${a||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ya(a==null?void 0:a.alert_level)}`}>
                ${Va(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ve(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${Ve(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ya(i==null?void 0:i.alert_level)}`}>
                ${Va(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ve(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${Ve(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(c=>o`<${ec} key=${c.name} agent=${c} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(c=>o`<${sc} key=${c.name} keeper=${c} />`)}
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
            <span>Uptime: ${oc(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${P} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function oc(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ve(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function Va(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ya(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const qe=m(null),hn=m(!1),kt=m(null),M=m(!1),yn=m([]);let rc=1;function E(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ro(t){return typeof t=="boolean"?t:void 0}function lc(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ut(t,e=[]){if(Array.isArray(t))return t;if(!E(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function cc(t){return E(t)?{id:x(t.id),seq:G(t.seq),from:x(t.from)??x(t.from_agent)??"system",content:x(t.content)??"",timestamp:x(t.timestamp)??new Date().toISOString(),type:x(t.type)}:null}function uc(t){return E(t)?{room_id:x(t.room_id),current_room:x(t.current_room)??x(t.room),project:x(t.project),cluster:x(t.cluster),paused:ro(t.paused),pause_reason:x(t.pause_reason)??null,paused_by:x(t.paused_by)??null,paused_at:x(t.paused_at)??null}:{}}function Qa(t){if(!E(t))return;const e=Object.entries(t).map(([n,s])=>{const a=x(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function dc(t){if(!E(t))return null;const e=E(t.status)?t.status:void 0,n=E(t.summary)?t.summary:E(e==null?void 0:e.summary)?e.summary:void 0,s=E(t.session)?t.session:E(e==null?void 0:e.session)?e.session:void 0,a=x(t.session_id)??x(n==null?void 0:n.session_id)??x(s==null?void 0:s.session_id);if(!a)return null;const i=Qa(t.report_paths)??Qa(e==null?void 0:e.report_paths),r=Ut(t.recent_events,["events"]).filter(E);return{session_id:a,status:x(t.status)??x(n==null?void 0:n.status)??x(s==null?void 0:s.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:E(t.team_health)?t.team_health:E(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:E(t.communication_metrics)?t.communication_metrics:E(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:E(t.orchestration_state)?t.orchestration_state:E(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:E(t.cascade_metrics)?t.cascade_metrics:E(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function pc(t){if(!E(t))return null;const e=x(t.name);if(!e)return null;const n=E(t.context)?t.context:void 0;return{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:lc(t.active_goal_ids),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:x(t.model)??x(t.active_model)??x(t.primary_model)}}function vc(t){if(!E(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function mc(t){const e=E(t)?t:{};return{room:uc(e.room),sessions:Ut(e.sessions,["items","sessions"]).map(dc).filter(n=>n!==null),keepers:Ut(e.keepers,["items","keepers"]).map(pc).filter(n=>n!==null),recent_messages:Ut(e.recent_messages,["messages"]).map(cc).filter(n=>n!==null),pending_confirms:Ut(e.pending_confirms,["items","confirms"]).map(vc).filter(n=>n!==null),available_actions:Ut(e.available_actions,["actions"]).filter(E).map(n=>({action_type:x(n.action_type)??"unknown",target_type:x(n.target_type)??"unknown",description:x(n.description),confirm_required:ro(n.confirm_required)}))}}function Ye(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Xa(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function bn(t){yn.value=[{...t,id:rc++,at:new Date().toISOString()},...yn.value].slice(0,20)}function lo(t){return t.confirm_required?Ye(t.preview)||"Confirmation required":Ye(t.result)||Ye(t.executed_action)||Ye(t.delegated_tool_result)||t.status}async function Zt(){hn.value=!0,kt.value=null;try{const t=await Lr();qe.value=mc(t)}catch(t){kt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{hn.value=!1}}async function fc(t){M.value=!0,kt.value=null;try{const e=await Wi(t);return bn({actor:t.actor,action_type:t.action_type,target_label:Xa(t),outcome:e.confirm_required?"preview":"executed",message:lo(e),delegated_tool:e.delegated_tool}),await Zt(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw kt.value=n,bn({actor:t.actor,action_type:t.action_type,target_label:Xa(t),outcome:"error",message:n}),e}finally{M.value=!1}}async function _c(t,e){M.value=!0,kt.value=null;try{const n=await Rr(t,e);return bn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:lo(n),delegated_tool:n.delegated_tool}),await Zt(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw kt.value=s,bn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{M.value=!1}}const co="masc_dashboard_agent_name";function gc(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(co))==null?void 0:s.trim())||"dashboard"}const qn=m(gc()),ve=m(""),Fs=m("Operator pause"),me=m(""),kn=m(""),zs=m("2"),xn=m(""),Vt=m("note"),wn=m(""),Sn=m(""),An=m(""),Us=m("2"),Hs=m("Operator stop request"),qs=m(""),fe=m("");function $c(t){const e=t.trim()||"dashboard";qn.value=e,localStorage.setItem(co,e)}function Za(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function hc(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function Et(t){const e=qn.value.trim()||"dashboard";try{const n=await fc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?h("Confirmation queued","warning"):h(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return h(s,"error"),null}}async function ti(){const t=ve.value.trim();if(!t)return;await Et({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(ve.value="")}async function yc(){await Et({action_type:"room_pause",target_type:"room",payload:{reason:Fs.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function bc(){await Et({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function kc(){const t=me.value.trim();if(!t)return;await Et({action_type:"task_inject",target_type:"room",payload:{title:t,description:kn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(zs.value,10)||2},successMessage:"Task injection submitted"})&&(me.value="",kn.value="")}async function xc(){var i;const t=qe.value,e=xn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){h("Select a team session first","warning");return}const n={turn_kind:Vt.value},s=wn.value.trim();s&&(n.message=s),Vt.value==="task"&&(n.task_title=Sn.value.trim()||"Operator injected task",n.task_description=An.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Us.value,10)||2),await Et({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(wn.value="",Vt.value==="task"&&(Sn.value="",An.value=""))}async function wc(){var n;const t=qe.value,e=xn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){h("Select a team session first","warning");return}await Et({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Hs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Sc(){var a;const t=qe.value,e=qs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=fe.value.trim();if(!e){h("Select a keeper first","warning");return}if(!n)return;await Et({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(fe.value="")}async function Ac(t){const e=qn.value.trim()||"dashboard";try{await _c(e,t),h("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";h(s,"error")}}function Cc(){var d;mt(()=>{Zt()},[]);const t=qe.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(u=>u.session_id===xn.value)??n[0]??null,l=s.find(u=>u.name===qs.value)??s[0]??null;return o`
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
            value=${qn.value}
            onInput=${u=>$c(u.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Zt()}} disabled=${hn.value||M.value}>
            ${hn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${kt.value?o`
        <section class="ops-banner error">${kt.value}</section>
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
                ${u.preview?o`<pre class="ops-code-block">${Za(u.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Ac(u.confirm_token)}} disabled=${M.value}>
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
              onKeyDown=${u=>{u.key==="Enter"&&ti()}}
              disabled=${M.value}
            />
            <button class="control-btn" onClick=${()=>{ti()}} disabled=${M.value||ve.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Fs.value}
              onInput=${u=>{Fs.value=u.target.value}}
              disabled=${M.value}
            />
            <button class="control-btn ghost" onClick=${()=>{yc()}} disabled=${M.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{bc()}} disabled=${M.value}>
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
            disabled=${M.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${kn.value}
            onInput=${u=>{kn.value=u.target.value}}
            disabled=${M.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${zs.value}
              onChange=${u=>{zs.value=u.target.value}}
              disabled=${M.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{kc()}} disabled=${M.value||me.value.trim()===""}>
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
                <pre class="ops-code-block compact">${Za(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Vt.value}
              onChange=${u=>{Vt.value=u.target.value}}
              disabled=${M.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{xc()}} disabled=${M.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${wn.value}
            onInput=${u=>{wn.value=u.target.value}}
            disabled=${M.value||!r}
          ></textarea>
          ${Vt.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${Sn.value}
              onInput=${u=>{Sn.value=u.target.value}}
              disabled=${M.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${An.value}
              onInput=${u=>{An.value=u.target.value}}
              disabled=${M.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Us.value}
              onChange=${u=>{Us.value=u.target.value}}
              disabled=${M.value||!r}
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
              value=${Hs.value}
              onInput=${u=>{Hs.value=u.target.value}}
              disabled=${M.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{wc()}} disabled=${M.value||!r}>
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
                onClick=${()=>{qs.value=u.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.name}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${u.model??"model n/a"}</span>
                  <span>${typeof u.context_ratio=="number"?`${Math.round(u.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${hc(u.last_turn_ago_s)}</span>
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
            disabled=${M.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{Sc()}} disabled=${M.value||!l||fe.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${yn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:yn.value.map(u=>o`
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
  `}const Ks=m([]),Bs=m([]),_e=m(""),Cn=m(!1),ge=m(!1),Ee=m(""),Nn=m(null),tt=m(null),Gs=m(!1);async function Js(){Cn.value=!0,Ee.value="";try{const[t,e]=await Promise.all([ul(),dl()]);Ks.value=t,Bs.value=e}catch(t){Ee.value=t instanceof Error?t.message:"Failed to load council data"}finally{Cn.value=!1}}async function ei(){const t=_e.value.trim();if(t){ge.value=!0;try{const e=await pl(t);_e.value="",h(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Js()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";h(n,"error")}finally{ge.value=!1}}}async function Nc(t){Nn.value=t,Gs.value=!0,tt.value=null;try{tt.value=await vl(t)}catch(e){Ee.value=e instanceof Error?e.message:"Failed to load debate status",tt.value=null}finally{Gs.value=!1}}function Tc({debate:t}){const e=Nn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Nc(t.id)}
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
  `}function Lc({session:t}){return o`
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
  `}function Rc(){var e;const t=(e=wt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ic(){var e,n;mt(()=>{Js()},[]);const t=((n=(e=wt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Rc} />
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${_e.value}
            onInput=${s=>{_e.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&ei()}}
            disabled=${ge.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ei}
            disabled=${ge.value||_e.value.trim()===""}
          >
            ${ge.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Js} disabled=${Cn.value}>
            ${Cn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Ee.value?o`<div class="council-error">${Ee.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${Ks.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Ks.value.map(s=>o`<${Tc} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Bs.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Bs.value.map(s=>o`<${Lc} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Nn.value?`Debate Detail (${Nn.value})`:"Debate Detail"} class="section">
        ${Gs.value?o`<div class="loading-indicator">Loading debate detail...</div>`:tt.value?o`
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
  `}function Dc({text:t}){if(!t)return null;const e=Mc(t);return o`<div class="markdown-content">${e}</div>`}function Mc(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Xn(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Xn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Xn(i.join(`
`))}</p>`)}return n}function Xn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const uo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],rn=m(null),$e=m([]),Rt=m(!1),Lt=m(null),he=m("");function Ec(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Pc=m(Ec()),ye=m(!1);async function fa(t){Lt.value=t,rn.value=null,$e.value=[],Rt.value=!0;try{const e=await Er(t);if(Lt.value!==t)return;rn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},$e.value=e.comments??[]}catch{Lt.value===t&&(rn.value=null,$e.value=[])}finally{Lt.value===t&&(Rt.value=!1)}}async function ni(t){const e=he.value.trim();if(e){ye.value=!0;try{await Pr(t,Pc.value,e),he.value="",h("Comment posted","success"),await fa(t),pt()}catch{h("Failed to post comment","error")}finally{ye.value=!1}}}function Oc(){const t=Le.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${uo.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Le.value=e.id,pt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Nt.value?"is-active":""}"
          onClick=${()=>{Nt.value=!Nt.value,pt()}}
        >
          ${Nt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${pt} disabled=${Ie.value}>
          ${Ie.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Zn(){var e;const t=(e=wt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function po({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function jc(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function si(t){return t.updated_at!==t.created_at}function ts(){var n;const t=((n=uo.find(s=>s.id===Le.value))==null?void 0:n.label)??Le.value,e=ua.value.length;return o`
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
        <strong>${Os.value?o`<${P} timestamp=${Os.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Fc({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Yi(t.id,n),pt()}catch{h("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>cr(t.id)}>
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
              <${po} flair=${t.flair} />
              ${si(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${P} timestamp=${t.created_at} /></span>
            ${si(t)?o`<span>Updated <${P} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${jc(t.content)}</div>
      </div>
    </div>
  `}function zc({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${P} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Uc({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${he.value}
        onInput=${e=>{he.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ni(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${ye.value}
      />
      <button
        onClick=${()=>ni(t)}
        disabled=${ye.value||he.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${ye.value?"...":"Post"}
      </button>
    </div>
  `}function Hc({post:t}){Lt.value!==t.id&&!Rt.value&&fa(t.id);const e=async n=>{try{await Yi(t.id,n),pt()}catch{h("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Un("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${po} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Dc} text=${t.content} />
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

      <${y} title="Comments (${Rt.value?"...":$e.value.length})">
        ${Rt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${zc} comments=${$e.value} />`}
        <${Uc} postId=${t.id} />
      <//>
    </div>
  `}function qc(){var a,i;const t=ua.value,e=Ie.value,n=st.value.postId,s=((i=(a=wt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(Lt.value===n?rn.value:null);return!r&&Lt.value!==n&&!Rt.value&&fa(n),r?o`
          <${Zn} />
          <${ts} />
          <${Hc} post=${r} />
        `:o`
          <div>
            <${Zn} />
            <${ts} />
            <button class="back-btn" onClick=${()=>Un("board")}>← Back to Board</button>
            ${Rt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Zn} />
    <${ts} />
    <${Oc} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":Nt.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Fc} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Kc(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Bc(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Gc(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const vo=120,Ws=m("all"),Jc={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Wc={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Vc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Yc(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Kc(t),actor:Bc(t),content:Gc(t),timestamp:new Date(t.timestamp).toISOString()}}function Tn(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Vs=J(()=>{const t=Ue.value.map(Vc),e=Qt.value.map(Yc);return[...t,...e].sort((n,s)=>Tn(s.timestamp)-Tn(n.timestamp))}),Qc=J(()=>{const t=Vs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Xc=J(()=>{const t=Ws.value;return(t==="all"?Vs.value:Vs.value.filter(n=>n.kind===t)).slice(0,vo)}),Zc=J(()=>Dt.value.map(t=>({agent:t,motion:pa(t.name,xt.value,Ue.value,Qt.value)})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:Tn(e.motion.lastActivityAt??0)-Tn(t.motion.lastActivityAt??0)}));function tu(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function ae({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function eu({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${tu(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Wc[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function nu(){const t=Qc.value,e=Xc.value,n=e[0],s=Zc.value;return o`
    <div class="stats-grid">
      <${ae} label="Visible rows" value=${e.length} />
      <${ae} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${ae} label="Tracked keeper events" value=${t.keepers} color="#4ade80" />
      <${ae} label="Tracked board events" value=${t.board} color="#fbbf24" />
      <${ae} label="SSE events" value=${Hn.value} color="#c084fc" />
    </div>

    <${y} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${Ws.value===a?"active":""}"
              onClick=${()=>{Ws.value=a}}
            >
              ${Jc[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${bt.value?"":"pill-stale"}">
            ${bt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${P} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${vo} rows</span>
          <span>Journal merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for events...</div>`:e.map(a=>o`<${eu} key=${a.id} row=${a} />`)}
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
                    ${i.lastActivityAt?o` · <${P} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function mo({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}function su({agent:t}){const e=pa(t.name,xt.value,Ue.value,Qt.value);return o`
    <button class="agent-card ${t.status}" onClick=${()=>io(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${mo} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:e.activeAssignedCount>0?o`<div class="agent-task">${e.activeAssignedCount} claimed tasks</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
      ${e.lastActivityText?o`
            <div class="agent-activity-meta">
              ${e.lastActivityAt?o`<${P} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </div>
          `:null}
    </button>
  `}function au(t){return typeof t.context_ratio!="number"||Number.isNaN(t.context_ratio)?"—":`${Math.round(t.context_ratio*100)}%`}function iu(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??"No active focus"}function ou(t){return[`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`,`Compactions ${t.compaction_count??0}`].join(" · ")}function ru({keeper:t}){return o`
    <div class="live-agent keeper-card" onClick=${()=>ao(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${mo} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Context</span>
            <strong class="keeper-core-value">${au(t)}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Generation</span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Heartbeat</span>
            <strong class="keeper-core-value">
              ${t.last_heartbeat?o`<${P} timestamp=${t.last_heartbeat} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Model</span>
            <strong class="keeper-core-value">${t.model??"—"}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Focus</span>
            <strong class="keeper-core-value keeper-core-text">${iu(t)}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Continuity</span>
            <strong class="keeper-core-value">${ou(t)}</strong>
          </div>
        </div>
      </div>
    </div>
  `}function lu(){const t=Dt.value,e=Mt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${ru} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${su} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function es({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${P} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function cu(){const{todo:t,inProgress:e,done:n}=da.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${es} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${es} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${es} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function uu(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function ns({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${uu(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${P} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function du(){const t=da.value,e=t.inProgress,n=t.todo,s=t.done,a=no.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
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
                  <${at} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${ns} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const Ln=m("all"),Rn=m("all"),Ys=J(()=>{let t=Re.value;return Ln.value!=="all"&&(t=t.filter(e=>e.horizon===Ln.value)),Rn.value!=="all"&&(t=t.filter(e=>e.status===Rn.value)),t}),pu=J(()=>{const t={short:[],mid:[],long:[]};for(const e of Ys.value){const n=t[e.horizon];n&&n.push(e)}return t}),vu=J(()=>{const t=Array.from(et.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function mu(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function _a(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ln(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function fu(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function ai(t){return t.toFixed(4)}function ii(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function _u({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ln(t.horizon)}">
            ${_a(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${mu(t.priority)}</span>
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
  `}function oi({label:t,timestamp:e,source:n}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${P} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ss({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${y} title="${_a(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${_u} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function gu(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ln.value===t?"active":""}"
            onClick=${()=>{Ln.value=t}}
          >
            ${t==="all"?"All":_a(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Rn.value===t?"active":""}"
            onClick=${()=>{Rn.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function $u(){const t=Re.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ln("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ln("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ln("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function hu({loop:t}){const e=t.history[0];return o`
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
          <span>Baseline ${ai(t.baseline_metric)}</span>
          <span>Current ${ai(t.current_metric)}</span>
          <span class=${ii(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${ii(t)}
          </span>
          <span>Elapsed ${fu(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function yu(){mt(()=>{ce(),ue()},[]);const t=pu.value,e=vu.value,n=e.filter(a=>a.status==="running").length,s=Re.value.filter(a=>a.status==="active").length;return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ys.value.length}</div>
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
            <button class="control-btn ghost" onClick=${ce} disabled=${qt.value}>
              ${qt.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${ue} disabled=${Kt.value}>
              ${Kt.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{ce(),ue()}}
              disabled=${qt.value||Kt.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${oi} label="Goals" timestamp=${to.value} source="masc_goal_list" />
          <${oi} label="MDAL loops" timestamp=${eo.value} source="masc_mdal_status" />
        </div>
      <//>

      <${y} title="Goal Pipeline" class="section">
        <${$u} />
        <${gu} />
      <//>

      ${qt.value&&Re.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ys.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${ss} horizon="short" items=${t.short??[]} />
              <${ss} horizon="mid" items=${t.mid??[]} />
              <${ss} horizon="long" items=${t.long??[]} />
            `}

      <${y} title="MDAL Loops" class="section">
        ${Kt.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0?o`
                <div class="empty-state">
                  No loop snapshot is visible right now. This section only changes when the backend exposes a current MDAL loop.
                </div>
              `:o`
                <div class="planning-loop-list">
                  ${e.map(a=>o`<${hu} key=${a.loop_id} loop=${a} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Ht=m(""),as=m("ability_check"),is=m("10"),os=m("12"),Qe=m(""),Xe=m("idle"),gt=m(""),Ze=m("keeper-late"),rs=m("player"),ls=m(""),V=m("idle"),cs=m(null),tn=m(""),us=m(""),ds=m("player"),ps=m(""),vs=m(""),ms=m(""),be=m("20"),fs=m("20"),_s=m(""),en=m("idle"),Qs=m(null),fo=m("overview"),gs=m("all"),$s=m("all"),hs=m("all"),bu=12e4,Kn=m(null),ri=m(Date.now());function ku(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function xu(t,e){return e>0?Math.round(t/e*100):0}const wu={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Su={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function nn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Au(t){const e=t.trim().toLowerCase();return wu[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Cu(t){const e=t.trim().toLowerCase();return Su[e]??"상황에 따라 선택되는 전술 액션입니다."}function yt(t){return typeof t=="object"&&t!==null}function B(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function it(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Pe(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Nu=new Set(["str","dex","con","int","wis","cha"]);function Tu(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!yt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function Lu(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(be.value.trim(),10);Number.isFinite(s)&&s>n&&(be.value=String(n))}function Xs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Ru(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Iu(t){fo.value=t}function _o(t){const e=Kn.value;return e==null||e<=t}function Du(t){const e=Kn.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function In(){Kn.value=null}function go(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Mu(t,e){go(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Kn.value=Date.now()+bu,h("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function cn(t){return _o(t)?(h("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Zs(t,e,n){return go([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Eu({hp:t,max:e}){const n=xu(t,e),s=ku(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Pu({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ou({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function $o({actor:t}){var d,u,v,c;const e=(d=t.archetype)==null?void 0:d.trim(),n=(u=t.persona)==null?void 0:u.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(c=t.background)==null?void 0:c.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([p,f])=>Number.isFinite(f)).filter(([p])=>!Nu.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const f=p.target;f&&(f.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${at} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Ou} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Eu} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Pu} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${nn(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([p,f])=>o`
                <span class="trpg-custom-stat-chip">${nn(p)} ${f}</span>
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
                  <span class="trpg-annot-name">${nn(p)}</span>
                  <span class="trpg-annot-desc">${Au(p)}</span>
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
                  <span class="trpg-annot-name">${nn(p)}</span>
                  <span class="trpg-annot-desc">${Cu(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function ju({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function ho({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Ru(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Xs(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${P} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Fu({events:t}){const e="__none__",n=gs.value,s=$s.value,a=hs.value,i=Array.from(new Set(t.map(Xs).map(c=>c.trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),l=t.some(c=>(c.type??"").trim()===""),d=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),u=t.some(c=>(c.phase??"").trim()===""),v=t.filter(c=>{if(n!=="all"&&Xs(c)!==n)return!1;const p=(c.type??"").trim(),f=(c.phase??"").trim();if(s===e){if(p!=="")return!1}else if(s!=="all"&&p!==s)return!1;if(a===e){if(f!=="")return!1}else if(a!=="all"&&f!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{gs.value=c.target.value}}>
          <option value="all">all</option>
          ${i.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${c=>{$s.value=c.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${c=>{hs.value=c.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${d.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{gs.value="all",$s.value="all",hs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${ho} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function zu({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function yo({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Uu({state:t,nowMs:e}){var u;const n=dt.value||((u=t.session)==null?void 0:u.room)||"",s=Xe.value,a=t.party??[];if(!a.find(v=>v.id===Ht.value)&&a.length>0){const v=a[0];v&&(Ht.value=v.id)}const r=async()=>{var c,p;if(!n){h("Room ID가 비어 있습니다.","error");return}if(!cn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Zs("라운드 실행",n,v)){Xe.value="running";try{const f=await Qr(n);Qs.value=f,Xe.value="ok";const g=yt(f.summary)?f.summary:null,k=g?Pe(g,"advanced",!1):!1,C=g?B(g,"progress_reason",""):"";h(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,k?"success":"warning"),vt()}catch(f){Qs.value=null,Xe.value="error";const g=f instanceof Error?f.message:"라운드 실행에 실패했습니다.";h(g,"error")}finally{In()}}},l=async()=>{var c,p;if(!n||!cn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Zs("턴 강제 진행",n,v))try{await tl(n),h("턴을 다음 단계로 이동했습니다.","success"),vt()}catch{h("턴 이동에 실패했습니다.","error")}finally{In()}},d=async()=>{if(!n||!cn(e))return;const v=Ht.value.trim();if(!v){h("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(is.value,10),p=Number.parseInt(os.value,10);if(Number.isNaN(c)||Number.isNaN(p)){h("stat/dc는 숫자여야 합니다.","warning");return}const f=Number.parseInt(Qe.value,10),g=Qe.value.trim()===""||Number.isNaN(f)?void 0:f;try{await Zr({roomId:n,actorId:v,action:as.value.trim()||"ability_check",statValue:c,dc:p,rawD20:g}),h("주사위 판정을 기록했습니다.","success"),vt()}catch{h("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{dt.value=v.target.value}}
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
              value=${as.value}
              onInput=${v=>{as.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${is.value}
              onInput=${v=>{is.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${os.value}
              onInput=${v=>{os.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Qe.value}
              onInput=${v=>{Qe.value=v.target.value}}
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
  `}function Hu({state:t}){var a;const e=dt.value||((a=t.session)==null?void 0:a.room)||"",n=en.value,s=async()=>{if(!e){h("Room ID가 비어 있습니다.","warning");return}const i=tn.value.trim(),r=us.value.trim();if(!r&&!i){h("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(be.value.trim(),10),d=Number.parseInt(fs.value.trim(),10),u=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(l)?Math.max(0,Math.min(u,l)):u;let c={};try{c=Tu(_s.value)}catch(p){h(p instanceof Error?p.message:"능력치 JSON 오류","error");return}en.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,f=await el(e,{actor_id:i||void 0,name:r||void 0,role:ds.value,idempotencyKey:p,portrait:vs.value.trim()||void 0,background:ms.value.trim()||void 0,hp:v,max_hp:u,alive:v>0,stats:Object.keys(c).length>0?c:void 0}),g=typeof f.actor_id=="string"?f.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const k=ps.value.trim();k&&await nl(e,g,k),Ht.value=g,gt.value=g,i||(tn.value=""),en.value="ok",h(`Actor 생성 완료: ${g}`,"success"),await vt()}catch(p){en.value="error",h(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${us.value}
            onInput=${i=>{us.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ds.value}
            onChange=${i=>{ds.value=i.target.value}}
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
            value=${ps.value}
            onInput=${i=>{ps.value=i.target.value}}
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
              value=${tn.value}
              onInput=${i=>{tn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${vs.value}
              onInput=${i=>{vs.value=i.target.value}}
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
              value=${fs.value}
              onInput=${i=>{const r=i.target.value;fs.value=r,Lu(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ms.value}
              onInput=${i=>{ms.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${_s.value}
              onInput=${i=>{_s.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function qu({state:t,nowMs:e}){var p;const n=dt.value||((p=t.session)==null?void 0:p.room)||"",s=t.join_gate,a=cs.value,i=yt(a)?a:null,r=(t.party??[]).filter(f=>f.role!=="dm"),l=gt.value.trim(),d=r.some(f=>f.id===l),u=d?l:l?"__manual__":"",v=async()=>{const f=gt.value.trim(),g=Ze.value.trim();if(!n||!f){h("Room/Actor가 필요합니다.","warning");return}V.value="checking";try{const k=await sl(n,f,g||void 0);cs.value=k,V.value="ok",h("참가 가능 여부를 갱신했습니다.","success")}catch(k){V.value="error";const C=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";h(C,"error")}},c=async()=>{var T,N;const f=gt.value.trim(),g=Ze.value.trim(),k=ls.value.trim();if(!n||!f||!g){h("Room/Actor/Keeper가 필요합니다.","warning");return}if(!cn(e))return;const C=((T=t.current_round)==null?void 0:T.phase)??((N=t.session)==null?void 0:N.status)??"unknown";if(Zs("Mid-Join 승인 요청",n,C)){V.value="requesting";try{const O=await al({room_id:n,actor_id:f,keeper_name:g,role:rs.value,...k?{name:k}:{}});cs.value=O;const H=yt(O)?Pe(O,"granted",!1):!1,D=yt(O)?B(O,"reason_code",""):"";H?h("Mid-Join이 승인되었습니다.","success"):h(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),V.value=H?"ok":"error",vt()}catch(O){V.value="error";const H=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";h(H,"error")}finally{In()}}};return o`
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
            onChange=${f=>{const g=f.target.value;if(g==="__manual__"){(d||!l)&&(gt.value="");return}gt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(f=>o`
              <option value=${f.id}>${f.name} (${f.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${u==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${gt.value}
                onInput=${f=>{gt.value=f.target.value}}
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
            value=${Ze.value}
            onInput=${f=>{Ze.value=f.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${rs.value}
            onChange=${f=>{rs.value=f.target.value}}
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
            value=${ls.value}
            onInput=${f=>{ls.value=f.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Pe(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${it(i,"effective_score",0)}/${it(i,"required_points",0)}</span>
            ${B(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${B(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function bo({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ko({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function xo(){const t=Qs.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=yt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(yt).slice(-8),i=t.canon_check,r=yt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],u=n?Pe(n,"advanced",!1):!1,v=n?B(n,"progress_reason",""):"",c=n?B(n,"progress_detail",""):"",p=n?it(n,"player_successes",0):0,f=n?it(n,"player_required_successes",0):0,g=n?Pe(n,"dm_success",!1):!1,k=n?it(n,"timeouts",0):0,C=n?it(n,"unavailable",0):0,T=n?it(n,"reprompts",0):0,N=n?it(n,"npc_attacks",0):0,O=n?it(n,"keeper_timeout_sec",0):0,H=n?it(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${f}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${H}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const Q=B(D,"status","unknown"),St=B(D,"actor_id","-"),At=B(D,"role","-"),X=B(D,"reason",""),lt=B(D,"action_type",""),R=B(D,"reply","");return o`
                <div class="trpg-round-item ${Q.includes("fallback")||Q.includes("timeout")?"failed":"active"}">
                  <span>${St} (${At})</span>
                  <span style="margin-left:auto; font-size:11px;">${Q}</span>
                  ${lt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${lt}</div>`:null}
                  ${X?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${X}</div>`:null}
                  ${R?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${R.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${B(r,"status","unknown")}</strong>
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
  `}function Ku({state:t,nowMs:e}){var r,l,d;const n=dt.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=_o(e),i=Du(e);return o`
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
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Mu(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{In(),h("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Bu({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Iu(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Gu({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${ho} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${ju} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${ko} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${bo} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${$o} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${yo} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Ju({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${Fu} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${xo} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${ko} state=${t} />
        <//>
      </div>
    </div>
  `}function Wu({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Ku} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${Uu} state=${t} nowMs=${e} />
          <//>

          <${y} title="Actor Spawn" style="margin-top:16px;">
            <${Hu} state=${t} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${qu} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${xo} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${bo} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${$o} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${yo} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Vu(){var l,d,u,v,c;const t=Zi.value,e=Ps.value;if(mt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{ri.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>vt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=fo.value,r=ri.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${dt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((u=t.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>vt()}>새로고침</button>
      </div>

      <${zu} outcome=${a} />

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

      <${Bu} active=${i} />

      ${i==="overview"?o`<${Gu} state=${t} />`:i==="timeline"?o`<${Ju} state=${t} />`:o`<${Wu} state=${t} nowMs=${r} />`}
    </div>
  `}const ga="masc_dashboard_agent_name";function Yu(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ga);return e??n??"dashboard"}const Y=m(Yu()),ke=m(""),xe=m(""),Dn=m(""),ct=m(""),we=m(""),ta=m(null),wo=m(null),Mn=m(null),Se=m(!1),Bt=m(!1),Ae=m(!1),Ce=m(!1),En=m(!1),Gt=m(!1),Pn=m(!1),Bn=m(!1);function $a(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function rt(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Qu(t){return typeof t=="boolean"?t:void 0}function ys(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Xu(t){return Array.isArray(t)?t.map(e=>rt(e)).filter(e=>!!e):[]}function Zu(t){if(!$a(t))return null;const e=rt(t.name);return e?{name:e,trigger:rt(t.trigger),outcome:rt(t.outcome),summary:rt(t.summary),reason:rt(t.reason)}:null}function bs(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!$a(s))continue;const a=rt(s.name);if(!a)continue;const i=rt(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function td(t){return $a(t)?{hour:ys(t.hour),checked:ys(t.checked)??0,acted:ys(t.acted)??0,acted_names:Xu(t.acted_names),activity_report:rt(t.activity_report),quiet_hours_overridden:Qu(t.quiet_hours_overridden),skipped_reason:rt(t.skipped_reason),acted_rows:bs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:bs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:bs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Zu).filter(e=>e!==null):[]}:null}function On(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ea(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function So(t){return!t||t.length===0?"none":t.join(", ")}function ed(t){return t?t.enabled?t.quiet_active?`Quiet hours ${On(t.quiet_start)}-${On(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ea(t.interval_s)}, but no tick has run yet in this runtime.`:`Lodge ticks every ${ea(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Pt(){fn();try{await He()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function ha(t){const e=t.trim();Y.value=e,e&&localStorage.setItem(ga,e)}function nd(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function na(){const t=Y.value.trim();if(t){Ae.value=!0;try{const e=await ol(t),n=nd(e);n&&ha(n),Bn.value=!0,await Pt(),h(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";h(n,"error")}finally{Ae.value=!1}}}async function sd(){const t=Y.value.trim();if(t){Ce.value=!0;try{await Xi(t),Bn.value=!1,await Pt(),h(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";h(n,"error")}finally{Ce.value=!1}}}async function ad(){const t=Y.value.trim();if(t)try{await Xi(t)}catch{}localStorage.removeItem(ga),ha("dashboard"),Bn.value=!1,await na()}async function id(){const t=Y.value.trim();if(t){En.value=!0;try{await rl(t),await Pt(),h("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";h(n,"error")}finally{En.value=!1}}}async function li(){const t=Y.value.trim(),e=ke.value.trim();if(!(!t||!e)){Se.value=!0;try{await Qi(t,e),ke.value="",await Pt(),h("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";h(s,"error")}finally{Se.value=!1}}}async function od(){const t=xe.value.trim(),e=Dn.value.trim()||"Created from dashboard";if(t){Bt.value=!0;try{await il(t,e,1),xe.value="",Dn.value="",await Pt(),h("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";h(s,"error")}finally{Bt.value=!1}}}async function rd(){const t=ct.value.trim(),e=we.value.trim();if(!t){h("Select a keeper first","warning");return}if(e){Gt.value=!0;try{const n=await ml(t,e);ta.value={keeper:t,prompt:e,reply:n.trim()||"(empty reply)",isError:!1,at:new Date().toISOString()},we.value="",await Pt(),h(`Reply received from ${t}`,"success")}catch(n){const s=n instanceof Error?n.message:`Failed to send direct message to ${t}`;ta.value={keeper:t,prompt:e,reply:s,isError:!0,at:new Date().toISOString()},h(s,"error")}finally{Gt.value=!1}}}async function ld(){const t=Y.value.trim()||"dashboard";Pn.value=!0,Mn.value=null;try{const e=await Wi({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=td(e.result);wo.value=n,await Pt(),n!=null&&n.skipped_reason?h(n.skipped_reason,"warning"):h(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Mn.value=n,h(n,"error")}finally{Pn.value=!1}}function cd(){const t=ta.value;return t?o`
    <div class=${`control-transcript ${t.isError?"is-error":"is-success"}`}>
      <div class="control-transcript-meta">
        <span>Keeper: ${t.keeper}</span>
        <span>${new Date(t.at).toLocaleTimeString()}</span>
      </div>
      <div class="control-transcript-label">Prompt</div>
      <pre class="control-transcript-text">${t.prompt}</pre>
      <div class="control-transcript-label">${t.isError?"Error":"Reply"}</div>
      <pre class="control-transcript-text">${t.reply}</pre>
    </div>
  `:o`<div class="control-status-copy">No direct keeper response yet.</div>`}function ud({runtime:t}){var a,i;const e=wo.value??(t==null?void 0:t.last_tick_result)??null;if(Mn.value)return o`<div class="control-result-box is-error">${Mn.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((a=e.skipped_rows)==null?void 0:a.slice(0,3))??[],s=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">
        Last acted: ${So(e.acted_names)}
      </div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${s.length>0?o`
            <div class="control-result-list">
              ${s.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function dd(){var n,s;const t=Mt.value.map(a=>a.name),e=((n=wt.value)==null?void 0:n.lodge)??null;return mt(()=>{na()},[]),mt(()=>{const a=t[0]??"";if(!ct.value&&a){ct.value=a;return}ct.value&&!t.includes(ct.value)&&(ct.value=a)},[t.join("|")]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${Y.value}
          onInput=${a=>ha(a.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{na()}}
            disabled=${Ae.value||Y.value.trim()===""}
          >
            ${Ae.value?"Joining...":Bn.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{sd()}}
            disabled=${Ce.value||Y.value.trim()===""}
          >
            ${Ce.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{ad()}}
            disabled=${Ae.value||Ce.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{id()}}
            disabled=${En.value||Y.value.trim()===""}
          >
            ${En.value?"Pinging...":"Heartbeat"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${ke.value}
            onInput=${a=>{ke.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&li()}}
            disabled=${Se.value}
          />
          <button
            class="control-btn"
            onClick=${li}
            disabled=${Se.value||ke.value.trim()===""||Y.value.trim()===""}
          >
            ${Se.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${ct.value}
          onInput=${a=>{ct.value=a.target.value}}
          disabled=${t.length===0||Gt.value}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(a=>o`<option value=${a}>${a}</option>`)}
        </select>

        <textarea
          class="control-textarea"
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
          value=${we.value}
          onInput=${a=>{we.value=a.target.value}}
          disabled=${t.length===0||Gt.value}
        ></textarea>

        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{rd()}}
            disabled=${Gt.value||we.value.trim()===""||ct.value.trim()===""}
          >
            ${Gt.value?"Waiting...":"Send Direct Message"}
          </button>
        </div>

        <${cd} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${ed(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ea(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${On(e==null?void 0:e.quiet_start)}-${On(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${So((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{ld()}}
            disabled=${Pn.value}
          >
            ${Pn.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${ud} runtime=${e} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${xe.value}
          onInput=${a=>{xe.value=a.target.value}}
          disabled=${Bt.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Dn.value}
          onInput=${a=>{Dn.value=a.target.value}}
          disabled=${Bt.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${od}
          disabled=${Bt.value||xe.value.trim()===""}
        >
          ${Bt.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Ao={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Operational directory for agents and keepers",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function pd(){const t=bt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Hn.value} events</span>
    </div>
  `}function vd(){const t=st.value.tab,e=bt.value,n=Ls.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Ls.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>Un(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${Ao[t]??"Live operational view"}</p>
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
            <strong>${Mt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${xt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Hn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{He(),t==="ops"&&Zt(),t==="board"&&pt(),t==="trpg"&&vt(),t==="goals"&&(ce(),ue())}}
        >
          Refresh Now
        </button>
      </section>

      <${dd} />
    </aside>
  `}function md(){switch(st.value.tab){case"overview":return o`<${Wa} />`;case"ops":return o`<${Cc} />`;case"council":return o`<${Ic} />`;case"board":return o`<${qc} />`;case"execution":return o`<${du} />`;case"activity":return o`<${nu} />`;case"agents":return o`<${lu} />`;case"tasks":return o`<${cu} />`;case"goals":return o`<${yu} />`;case"trpg":return o`<${Vu} />`;default:return o`<${Wa} />`}}function fd(){mt(()=>{ur(),qi(),He();const e=Il();return Dl(),()=>{hr(),e(),Ml()}},[]),mt(()=>{const e=st.value.tab;e==="ops"&&Zt(),e==="board"&&pt(),e==="trpg"&&vt(),e==="goals"&&(ce(),ue())},[st.value.tab]);const t=st.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${Ao[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${pd} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${dr} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Es.value&&!bt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${md} />`}
        </main>
        <${vd} />
      </div>

      <${Gl} />
      <${tc} />
      <${Vl} />
    </div>
  `}const ci=document.getElementById("app");ci&&Go(o`<${fd} />`,ci);
