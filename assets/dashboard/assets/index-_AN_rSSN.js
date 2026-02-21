(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var me,S,Xn,Yn,Z,gn,Qn,Zn,ts,sn,Oe,He,Ft={},es=[],ta=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,$e=Array.isArray;function W(t,e){for(var n in e)t[n]=e[n];return t}function an(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ns(t,e,n){var s,a,o,r={};for(o in e)o=="key"?s=e[o]:o=="ref"?a=e[o]:r[o]=e[o];if(arguments.length>2&&(r.children=arguments.length>3?me.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(o in t.defaultProps)r[o]===void 0&&(r[o]=t.defaultProps[o]);return Qt(t,r,s,a,null)}function Qt(t,e,n,s,a){var o={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Xn,__i:-1,__u:0};return a==null&&S.vnode!=null&&S.vnode(o),o}function zt(t){return t.children}function bt(t,e){this.props=t,this.context=e}function ut(t,e){if(e==null)return t.__?ut(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ut(t):null}function ss(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return ss(t)}}function yn(t){(!t.__d&&(t.__d=!0)&&Z.push(t)&&!ee.__r++||gn!=S.debounceRendering)&&((gn=S.debounceRendering)||Qn)(ee)}function ee(){for(var t,e,n,s,a,o,r,l=1;Z.length;)Z.length>l&&Z.sort(Zn),t=Z.shift(),l=Z.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,o=[],r=[],e.__P&&((n=W({},s)).__v=s.__v+1,S.vnode&&S.vnode(n),on(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,o,a??ut(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,os(o,n,r),s.__e=s.__=null,n.__e!=a&&ss(n)));ee.__r=0}function as(t,e,n,s,a,o,r,l,d,u,v){var c,f,p,C,D,A,k,w=s&&s.__k||es,F=e.length;for(d=ea(n,e,w,d,F),c=0;c<F;c++)(p=n.__k[c])!=null&&(f=p.__i==-1?Ft:w[p.__i]||Ft,p.__i=c,A=on(t,p,f,a,o,r,l,d,u,v),C=p.__e,p.ref&&f.ref!=p.ref&&(f.ref&&rn(f.ref,null,p),v.push(p.ref,p.__c||C,p)),D==null&&C!=null&&(D=C),(k=!!(4&p.__u))||f.__k===p.__k?d=is(p,d,t,k):typeof p.type=="function"&&A!==void 0?d=A:C&&(d=C.nextSibling),p.__u&=-7);return n.__e=D,d}function ea(t,e,n,s,a){var o,r,l,d,u,v=n.length,c=v,f=0;for(t.__k=new Array(a),o=0;o<a;o++)(r=e[o])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[o]=Qt(null,r,null,null,null):$e(r)?r=t.__k[o]=Qt(zt,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[o]=Qt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[o]=r,d=o+f,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=na(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>v?f--:a<v&&f++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?f--:u==d+1?f++:(u>d?f--:f++,r.__u|=4))):t.__k[o]=null;if(c)for(o=0;o<v;o++)(l=n[o])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=ut(l)),ls(l,l));return s}function is(t,e,n,s){var a,o;if(typeof t.type=="function"){for(a=t.__k,o=0;a&&o<a.length;o++)a[o]&&(a[o].__=t,e=is(a[o],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ut(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function na(t,e,n,s){var a,o,r,l=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&l==null||v&&l==u.key&&d==u.type)return n;if(s>(v?1:0)){for(a=n-1,o=n+1;a>=0||o<e.length;)if((u=e[r=a>=0?a--:o++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function bn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||ta.test(e)?n:n+"px"}function Jt(t,e,n,s,a){var o,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||bn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||bn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")o=e!=(e=e.replace(ts,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+o]=n,n?s?n.u=s.u:(n.u=sn,t.addEventListener(e,o?He:Oe,o)):t.removeEventListener(e,o?He:Oe,o);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function xn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=sn++;else if(e.t<n.u)return;return n(S.event?S.event(e):e)}}}function on(t,e,n,s,a,o,r,l,d,u){var v,c,f,p,C,D,A,k,w,F,J,Y,at,ht,Q,E,O,h=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),o=[l=e.__e=n.__e]),(v=S.__b)&&v(e);t:if(typeof h=="function")try{if(k=e.props,w="prototype"in h&&h.prototype.render,F=(v=h.contextType)&&s[v.__c],J=v?F?F.props.value:v.__:s,n.__c?A=(c=e.__c=n.__c).__=c.__E:(w?e.__c=c=new h(k,J):(e.__c=c=new bt(k,J),c.constructor=h,c.render=aa),F&&F.sub(c),c.state||(c.state={}),c.__n=s,f=c.__d=!0,c.__h=[],c._sb=[]),w&&c.__s==null&&(c.__s=c.state),w&&h.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=W({},c.__s)),W(c.__s,h.getDerivedStateFromProps(k,c.__s))),p=c.props,C=c.state,c.__v=e,f)w&&h.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),w&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(w&&h.getDerivedStateFromProps==null&&k!==p&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(k,J),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(k,c.__s,J)===!1){for(e.__v!=n.__v&&(c.props=k,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(H){H&&(H.__=e)}),Y=0;Y<c._sb.length;Y++)c.__h.push(c._sb[Y]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(k,c.__s,J),w&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(p,C,D)})}if(c.context=J,c.props=k,c.__P=t,c.__e=!1,at=S.__r,ht=0,w){for(c.state=c.__s,c.__d=!1,at&&at(e),v=c.render(c.props,c.state,c.context),Q=0;Q<c._sb.length;Q++)c.__h.push(c._sb[Q]);c._sb=[]}else do c.__d=!1,at&&at(e),v=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++ht<25);c.state=c.__s,c.getChildContext!=null&&(s=W(W({},s),c.getChildContext())),w&&!f&&c.getSnapshotBeforeUpdate!=null&&(D=c.getSnapshotBeforeUpdate(p,C)),E=v,v!=null&&v.type===zt&&v.key==null&&(E=rs(v.props.children)),l=as(t,$e(E)?E:[E],e,n,s,a,o,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),A&&(c.__E=c.__=null)}catch(H){if(e.__v=null,d||o!=null)if(H.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;o[o.indexOf(l)]=null,e.__e=l}else{for(O=o.length;O--;)an(o[O]);ze(e)}else e.__e=n.__e,e.__k=n.__k,H.then||ze(e);S.__e(H,e,n)}else o==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=sa(n.__e,e,n,s,a,o,r,d,u);return(v=S.diffed)&&v(e),128&e.__u?void 0:l}function ze(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ze)}function os(t,e,n){for(var s=0;s<n.length;s++)rn(n[s],n[++s],n[++s]);S.__c&&S.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(o){o.call(a)})}catch(o){S.__e(o,a.__v)}})}function rs(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:$e(t)?t.map(rs):W({},t)}function sa(t,e,n,s,a,o,r,l,d){var u,v,c,f,p,C,D,A=n.props||Ft,k=e.props,w=e.type;if(w=="svg"?a="http://www.w3.org/2000/svg":w=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),o!=null){for(u=0;u<o.length;u++)if((p=o[u])&&"setAttribute"in p==!!w&&(w?p.localName==w:p.nodeType==3)){t=p,o[u]=null;break}}if(t==null){if(w==null)return document.createTextNode(k);t=document.createElementNS(a,w,k.is&&k),l&&(S.__m&&S.__m(e,o),l=!1),o=null}if(w==null)A===k||l&&t.data==k||(t.data=k);else{if(o=o&&me.call(t.childNodes),!l&&o!=null)for(A={},u=0;u<t.attributes.length;u++)A[(p=t.attributes[u]).name]=p.value;for(u in A)if(p=A[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=p;else if(!(u in k)){if(u=="value"&&"defaultValue"in k||u=="checked"&&"defaultChecked"in k)continue;Jt(t,u,null,p,a)}}for(u in k)p=k[u],u=="children"?f=p:u=="dangerouslySetInnerHTML"?v=p:u=="value"?C=p:u=="checked"?D=p:l&&typeof p!="function"||A[u]===p||Jt(t,u,p,A[u],a);if(v)l||c&&(v.__html==c.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(c&&(t.innerHTML=""),as(e.type=="template"?t.content:t,$e(f)?f:[f],e,n,s,w=="foreignObject"?"http://www.w3.org/1999/xhtml":a,o,r,o?o[0]:n.__k&&ut(n,0),l,d),o!=null)for(u=o.length;u--;)an(o[u]);l||(u="value",w=="progress"&&C==null?t.removeAttribute("value"):C!=null&&(C!==t[u]||w=="progress"&&!C||w=="option"&&C!=A[u])&&Jt(t,u,C,A[u],a),u="checked",D!=null&&D!=t[u]&&Jt(t,u,D,A[u],a))}return t}function rn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){S.__e(a,n)}}function ls(t,e,n){var s,a;if(S.unmount&&S.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||rn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(o){S.__e(o,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&ls(s[a],e,n||typeof t.type!="function");n||an(t.__e),t.__c=t.__=t.__e=void 0}function aa(t,e,n){return this.constructor(t,n)}function ia(t,e,n){var s,a,o,r;e==document&&(e=document.documentElement),S.__&&S.__(t,e),a=(s=!1)?null:e.__k,o=[],r=[],on(e,t=e.__k=ns(zt,null,[t]),a||Ft,Ft,e.namespaceURI,a?null:e.firstChild?me.call(e.childNodes):null,o,a?a.__e:e.firstChild,s,r),os(o,t,r)}me=es.slice,S={__e:function(t,e,n,s){for(var a,o,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((o=a.constructor)&&o.getDerivedStateFromError!=null&&(a.setState(o.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},Xn=0,Yn=function(t){return t!=null&&t.constructor===void 0},bt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=W({},this.state),typeof t=="function"&&(t=t(W({},n),this.props)),t&&W(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),yn(this))},bt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),yn(this))},bt.prototype.render=zt,Z=[],Qn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Zn=function(t,e){return t.__v.__b-e.__v.__b},ee.__r=0,ts=/(PointerCapture)$|Capture$/i,sn=0,Oe=xn(!1),He=xn(!0);var cs=function(t,e,n,s){var a;e[0]=0;for(var o=1;o<e.length;o++){var r=e[o++],l=e[o]?(e[0]|=r?1:2,n[e[o++]]):e[++o];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++o]]=l:r===6?s[1][e[++o]]+=l+"":r?(a=t.apply(l,cs(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[o-2]=0,e[o]=a)):s.push(l)}return s},kn=new Map;function oa(t){var e=kn.get(this);return e||(e=new Map,kn.set(this,e)),(e=cs(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,o=1,r="",l="",d=[0],u=function(f){o===1&&(f||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,f,r):o===3&&(f||r)?(d.push(3,f,r),o=2):o===2&&r==="..."&&f?d.push(4,f,0):o===2&&r&&!f?d.push(5,0,!0,r):o>=5&&((r||!f&&o===5)&&(d.push(o,0,r,a),o=6),f&&(d.push(o,f,0,a),o=6)),r=""},v=0;v<n.length;v++){v&&(o===1&&u(),u(v));for(var c=0;c<n[v].length;c++)s=n[v][c],o===1?s==="<"?(u(),d=[d],o=3):r+=s:o===4?r==="--"&&s===">"?(o=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),o=1):o&&(s==="="?(o=5,a=r,r=""):s==="/"&&(o<5||n[v][c+1]===">")?(u(),o===3&&(d=d[0]),o=d,(d=d[0]).push(2,0,o),o=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),o=2):r+=s),o===3&&r==="!--"&&(o=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var i=oa.bind(ns),ne,R,xe,wn,Sn=0,us=[],T=S,Cn=T.__b,Tn=T.__r,An=T.diffed,Nn=T.__c,Dn=T.unmount,En=T.__;function ds(t,e){T.__h&&T.__h(R,t,Sn||e),Sn=0;var n=R.__H||(R.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function se(t,e){var n=ds(ne++,3);!T.__s&&vs(n.__H,e)&&(n.__=t,n.u=e,R.__H.__h.push(n))}function ps(t,e){var n=ds(ne++,7);return vs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function ra(){for(var t;t=us.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Zt),t.__H.__h.forEach(Ue),t.__H.__h=[]}catch(e){t.__H.__h=[],T.__e(e,t.__v)}}T.__b=function(t){R=null,Cn&&Cn(t)},T.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),En&&En(t,e)},T.__r=function(t){Tn&&Tn(t),ne=0;var e=(R=t.__c).__H;e&&(xe===R?(e.__h=[],R.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Zt),e.__h.forEach(Ue),e.__h=[],ne=0)),xe=R},T.diffed=function(t){An&&An(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(us.push(e)!==1&&wn===T.requestAnimationFrame||((wn=T.requestAnimationFrame)||la)(ra)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),xe=R=null},T.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Zt),n.__h=n.__h.filter(function(s){return!s.__||Ue(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],T.__e(s,n.__v)}}),Nn&&Nn(t,e)},T.unmount=function(t){Dn&&Dn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{Zt(s)}catch(a){e=a}}),n.__H=void 0,e&&T.__e(e,n.__v))};var Rn=typeof requestAnimationFrame=="function";function la(t){var e,n=function(){clearTimeout(s),Rn&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Rn&&(e=requestAnimationFrame(n))}function Zt(t){var e=R,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),R=e}function Ue(t){var e=R;t.__c=t.__(),R=e}function vs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var ca=Symbol.for("preact-signals");function he(){if(X>1)X--;else{for(var t,e=!1;xt!==void 0;){var n=xt;for(xt=void 0,Be++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ms(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Be=0,X--,e)throw t}}function ua(t){if(X>0)return t();X++;try{return t()}finally{he()}}var x=void 0;function fs(t){var e=x;x=void 0;try{return t()}finally{x=e}}var xt=void 0,X=0,Be=0,ae=0;function _s(t){if(x!==void 0){var e=t.n;if(e===void 0||e.t!==x)return e={i:0,S:t,p:x.s,n:void 0,t:x,e:void 0,x:void 0,r:e},x.s!==void 0&&(x.s.n=e),x.s=e,t.n=e,32&x.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=x.s,e.n=void 0,x.s.n=e,x.s=e),e}}function N(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}N.prototype.brand=ca;N.prototype.h=function(){return!0};N.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:fs(function(){var s;(s=e.W)==null||s.call(e)}))};N.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&fs(function(){var a;(a=e.Z)==null||a.call(e)}))}};N.prototype.subscribe=function(t){var e=this;return Ut(function(){var n=e.value,s=x;x=void 0;try{t(n)}finally{x=s}},{name:"sub"})};N.prototype.valueOf=function(){return this.value};N.prototype.toString=function(){return this.value+""};N.prototype.toJSON=function(){return this.value};N.prototype.peek=function(){var t=x;x=void 0;try{return this.value}finally{x=t}};Object.defineProperty(N.prototype,"value",{get:function(){var t=_s(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Be>100)throw new Error("Cycle detected");this.v=t,this.i++,ae++,X++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{he()}}}});function _(t,e){return new N(t,e)}function ms(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function $s(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function hs(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function nt(t,e){N.call(this,void 0),this.x=t,this.s=void 0,this.g=ae-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}nt.prototype=new N;nt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ae))return!0;if(this.g=ae,this.f|=1,this.i>0&&!ms(this))return this.f&=-2,!0;var t=x;try{$s(this),x=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return x=t,hs(this),this.f&=-2,!0};nt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}N.prototype.S.call(this,t)};nt.prototype.U=function(t){if(this.t!==void 0&&(N.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};nt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(nt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=_s(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function dt(t,e){return new nt(t,e)}function gs(t){var e=t.u;if(t.u=void 0,typeof e=="function"){X++;var n=x;x=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,ln(t),s}finally{x=n,he()}}}function ln(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,gs(t)}function da(t){if(x!==this)throw new Error("Out-of-order effect");hs(this),x=t,this.f&=-2,8&this.f&&ln(this),he()}function vt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}vt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};vt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,gs(this),$s(this),X++;var t=x;return x=this,da.bind(this,t)};vt.prototype.N=function(){2&this.f||(this.f|=2,this.o=xt,xt=this)};vt.prototype.d=function(){this.f|=8,1&this.f||ln(this)};vt.prototype.dispose=function(){this.d()};function Ut(t,e){var n=new vt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var ys,Wt,pa=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,bs=[];Ut(function(){ys=this.N})();function ft(t,e){S[t]=e.bind(null,S[t]||function(){})}function ie(t){if(Wt){var e=Wt;Wt=void 0,e()}Wt=t&&t.S()}function xs(t){var e=this,n=t.data,s=fa(n);s.value=n;var a=ps(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=dt(function(){var p=s.value.value;return p===0?0:p===!0?"":p||""}),v=dt(function(){return!Array.isArray(u.value)&&!Yn(u.value)}),c=Ut(function(){if(this.N=ks,v.value){var p=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=p)}}),f=e.__$u.d;return e.__$u.d=function(){c(),f.call(this)},[v,u]},[]),o=a[0],r=a[1];return o.value?r.peek():r.value}xs.displayName="ReactiveTextNode";Object.defineProperties(N.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:xs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});ft("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var o=s[a];o instanceof N&&(n||(e.__np=n={}),n[a]=o,s[a]=o.peek())}}t(e)});ft("__r",function(t,e){if(t(e),e.type!==zt){ie();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,o){var r;return Ut(function(){r=this},{name:o}),r.c=a,r})(function(){var a;pa&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ie(n)}});ft("__e",function(t,e,n,s){ie(),t(e,n,s)});ft("diffed",function(t,e){ie();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var o=n.U;if(o)for(var r in o){var l=o[r];l!==void 0&&!(r in s)&&(l.d(),o[r]=void 0)}else o={},n.U=o;for(var d in s){var u=o[d],v=s[d];u===void 0?(u=va(n,d,v),o[d]=u):u.o(v,a)}for(var c in s)a[c]=s[c]}}t(e)});function va(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,o=_(n),r=n.peek();return{o:function(l,d){o.value=l,r=l.peek()},d:Ut(function(){this.N=ks;var l=o.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}ft("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var o=s[a];o&&o.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});ft("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});bt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var o=2&this.__$f;if(!(s||o||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function fa(t,e){return ps(function(){return _(t,e)},[])}var _a=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ma(){ua(function(){for(var t;t=bs.shift();)ys.call(t)})}function ks(){bs.push(this)===1&&(S.requestAnimationFrame||_a)(ma)}const $a=["overview","board","activity","agents","tasks","journal","trpg","council"],ws={tab:"overview",params:{},postId:null};function Pn(t){return!!t&&$a.includes(t)}function Ke(t){try{return decodeURIComponent(t)}catch{return t}}function qe(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ha(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ss(t,e){const n=t[0],s=e.tab,a=Pn(n)?n:Pn(s)?s:"overview";let o=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Ke(t[2]):t[0]==="post"&&t[1]&&(o=Ke(t[1]))),{tab:a,params:e,postId:o}}function oe(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ws;const n=Ke(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=qe(a),r=ha(s);return Ss(r,o)}function ga(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ws,params:qe(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=qe(e.replace(/^\?/,""));return Ss(s,a)}function Cs(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const q=_(oe(window.location.hash));window.addEventListener("hashchange",()=>{q.value=oe(window.location.hash)});function ge(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Cs(n)}function ya(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ba(){if(window.location.hash&&window.location.hash!=="#"){q.value=oe(window.location.hash);return}const t=ga(window.location.pathname,window.location.search);if(t){q.value=t;const e=Cs(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",q.value=oe(window.location.hash)}const xa=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function ka(){const t=q.value.tab;return i`
    <div class="main-tab-bar">
      ${xa.map(e=>i`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>ge(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Ln="masc_dashboard_sse_session_id",wa=1e3,Sa=15e3,pt=_(!1),cn=_(0),Ts=_(null),re=_([]);function Ca(){let t=sessionStorage.getItem(Ln);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ln,t)),t}const Ta=200;function z(t,e){const n={agent:t,text:e,timestamp:Date.now()};re.value=[n,...re.value].slice(0,Ta)}let K=null,rt=null,Je=0;function As(){rt&&(clearTimeout(rt),rt=null)}function Aa(){if(rt)return;Je++;const t=Math.min(Je,5),e=Math.min(Sa,wa*Math.pow(2,t));rt=setTimeout(()=>{rt=null,Ns()},e)}function Ns(){As(),K&&(K.close(),K=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Ca());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);K=o,o.onopen=()=>{K===o&&(Je=0,pt.value=!0)},o.onerror=()=>{K===o&&(pt.value=!1,o.close(),K=null,Aa())},o.onmessage=r=>{try{const l=JSON.parse(r.data);cn.value++,Ts.value=l,Na(l)}catch{}}}function Na(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":z(n,"Joined");break;case"agent_left":z(n,"Left");break;case"broadcast":z(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":z(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":z(n,"New post");break;case"board_comment":z(n,"New comment");break;case"keeper_heartbeat":z(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":z(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":z(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":z(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:z(n,e)}}function Da(){As(),K&&(K.close(),K=null),pt.value=!1}function Ds(){return new URLSearchParams(window.location.search)}function Es(){const t=Ds(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Rs(){return{...Es(),"Content-Type":"application/json"}}const Ea=15e3,Ps=3e4,Ra=6e4;async function un(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw o}finally{clearTimeout(a)}}function Pa(){var e,n;const t=Ds();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Bt(t){const e=await un(t,{headers:Es()},Ea);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Kt(t,e){const n=await un(t,{method:"POST",headers:Rs(),body:JSON.stringify(e)},Ps);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function La(t,e,n,s=Ps){const a=await un(t,{method:"POST",headers:{...Rs(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function ja(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Ma(t){var e,n,s,a,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function j(t,e){const n=await La("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ra),s=ja(n);return Ma(s)}function Ls(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function Ia(t="compact"){return Bt(`/api/v1/dashboard?mode=${t}`)}function Fa(){return Bt("/api/v1/board")}function Oa(t){return Bt(`/api/v1/board/${t}`)}function js(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:Pa()})}function Ha(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function P(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function L(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function jn(t,e=!1){return typeof t=="boolean"?t:e}function ke(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(P(e)){const n=$(e.name,"").trim(),s=$(e.id,"").trim(),a=$(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function za(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function M(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}function Ua(t,e){if(t!=="dice.rolled")return;const n=L(e.raw_d20,0),s=L(e.total,0),a=L(e.bonus,0),o=$(e.action,"roll"),r=L(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Ba(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ka(t,e,n){const s=e||$(n.actor_id,"");switch(t){case"turn.action.proposed":{const a=$(n.proposed_action,$(n.reply,""));return a?`${s||"actor"}: ${a}`:"Action proposed"}case"turn.action.resolved":{const a=$(n.reply,$(n.result,""));return a?`Resolved: ${a}`:"Action resolved"}case"narration.posted":return $(n.reply,$(n.content,$(n.text,"Narration")));case"dice.rolled":{const a=$(n.action,"roll"),o=L(n.total,0),r=L(n.dc,0),l=$(n.label,""),d=s||"actor",u=r>0?` vs DC ${r}`:"",v=l?` (${l})`:"";return`${d} ${a}: ${o}${u}${v}`}case"turn.started":return`Turn ${L(n.turn,1)} started`;case"phase.changed":return`Phase: ${$(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(n.name,s||"unknown")}`;case"actor.claimed":return`${$(n.keeper_name,$(n.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${$(n.keeper_name,$(n.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${L(n.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${L(n.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||$(n.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||$(n.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(n.reason_code,"unknown")}`;case"memory.signal":return $(n.summary_en,$(n.summary_ko,"Memory signal"));case"combat.attack":return $(n.summary,$(n.result,"Attack resolved"));case"combat.defense":return $(n.summary,$(n.result,"Defense resolved"));case"session.outcome":return $(n.summary,$(n.outcome,"Session ended"));default:{const a=Ba(n);return a?`${t}: ${a}`:t}}}function qa(t){const e=P(t)?t:{},n=$(e.type,"event"),s=typeof e.actor_id=="string"?e.actor_id:"",a=P(e.payload)?e.payload:{};return{type:n,actor:s||$(a.actor_id,""),content:Ka(n,s,a),dice_roll:Ua(n,a),timestamp:$(e.ts,new Date().toISOString())}}function Ja(t,e,n){var ht,Q;const s=$(t.room_id,"")||n||"default",a=P(t.state)?t.state:{},o=P(a.party)?a.party:{},r=P(a.actor_control)?a.actor_control:{},l=P(a.join_gate)?a.join_gate:{},d=P(a.contribution_ledger)?a.contribution_ledger:{},v=Object.entries(o).map(([E,O])=>{const h=P(O)?O:{},H=M(h,"max_hp",void 0,10),mn=M(h,"hp",void 0,H),Gs=M(h,"max_mp",void 0,0),Vs=M(h,"mp",void 0,0),Xs=M(h,"level",void 0,1),Ys=M(h,"xp",void 0,0),Qs=jn(h.alive,mn>0),$n=r[E],hn=typeof $n=="string"?$n:void 0,Zs=za(h.role,E,hn);return{id:E,name:$(h.name,E),role:Zs,keeper:hn,archetype:$(h.archetype,""),persona:$(h.persona,""),traits:ke(h.traits),skills:ke(h.skills),status:Qs?"active":"dead",stats:{hp:mn,max_hp:H,mp:Vs,max_mp:Gs,level:Xs,xp:Ys,strength:M(h,"strength","str",10),dexterity:M(h,"dexterity","dex",10),constitution:M(h,"constitution","con",10),intelligence:M(h,"intelligence","int",10),wisdom:M(h,"wisdom","wis",10),charisma:M(h,"charisma","cha",10)}}}).filter(E=>E.status!=="dead"),c={phase_open:jn(l.phase_open,!0),min_points:L(l.min_points,3),window:$(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},f=Object.entries(d).map(([E,O])=>{const h=P(O)?O:{};return{actor_id:E,score:L(h.score,0),last_reason:$(h.last_reason,"")||null,reasons:ke(h.reasons)}}),p=e.map(qa),C=L(a.turn,1),D=$(a.phase,"round"),A=$(a.map,""),k=P(a.world)?a.world:{},w=A||$(k.ascii_map,$(k.map,"")),F=p.filter((E,O)=>{const h=e[O];if(!P(h))return!1;const H=P(h.payload)?h.payload:{};return L(H.turn,-1)===C}),J=(F.length>0?F:p).slice(-12),Y=$(a.status,"active");return{session:{id:s,room:s,status:Y==="ended"?"ended":Y==="paused"?"paused":"active",round:C,actors:v,created_at:((ht=p[0])==null?void 0:ht.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:D,events:J,timestamp:((Q=p[p.length-1])==null?void 0:Q.timestamp)??new Date().toISOString()},map:w||void 0,join_gate:c,contribution_ledger:f,party:v,story_log:p,history:[]}}async function Wa(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Bt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ga(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Bt(`/api/v1/trpg/state${e}`),Wa(t)]);return Ja(n,s,t)}function Va(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function Xa(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ya(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function Qa(t,e){const n=Xa();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function Za(t,e,n){const s=await j("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function ti(t){const e=await j("trpg.mid_join.request",t);return JSON.parse(e)}async function Ms(t,e){await j("masc_broadcast",{agent_name:t,message:e})}async function ei(t,e,n=1){await j("masc_add_task",{title:t,description:e,priority:n})}async function ni(t){return j("masc_join",{agent_name:t})}async function Is(t){await j("masc_leave",{agent_name:t})}async function si(t){await j("masc_heartbeat",{agent_name:t})}async function ai(t=40){return(await j("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ii(t,e=20){return j("masc_task_history",{task_id:t,limit:e})}async function oi(){const t=await j("masc_debates",{});return Ls(t)}async function ri(){const t=await j("masc_sessions",{});return Ls(t)}async function li(t){const e=await j("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function ci(t){return j("masc_debate_status",{debate_id:t})}const _t=_([]),qt=_([]),Fs=_([]),mt=_([]),dn=_(null),yt=_(null),We=_(new Map),Os=_([]),Mn=_("hot"),Hs=_(null),lt=_(""),Ge=_(!1),Ve=_(!1),Xe=_(!1),ui=dt(()=>_t.value.filter(t=>t.status==="active"||t.status==="idle")),zs=dt(()=>{const t=qt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function di(t){var a;const e=t.metrics_series;if(!e||e.length===0){const o=((a=t.status)==null?void 0:a.toLowerCase())??"";return o==="offline"||o==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const pi=dt(()=>{const t=new Map;for(const e of mt.value)t.set(e.name,di(e));return t}),vi=12e4,fi=dt(()=>{const t=Date.now(),e=new Set,n=We.value;for(const s of mt.value){const a=n.get(s.name);a!=null&&t-a>vi&&e.add(s.name)}return e}),le={},_i=5e3;function Ye(){delete le.compact,delete le.full}function U(t){return typeof t=="object"&&t!==null}function m(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function kt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Us(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function mi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function $i(t){if(!U(t))return null;const e=m(t.name);return e?{name:e,status:Us(t.status),current_task:m(t.current_task)??null,last_seen:m(t.last_seen),emoji:m(t.emoji),koreanName:m(t.koreanName)??m(t.korean_name),model:m(t.model),traits:kt(t.traits),interests:kt(t.interests),activityLevel:g(t.activityLevel)??g(t.activity_level),primaryValue:m(t.primaryValue)??m(t.primary_value)}:null}function hi(t){if(!U(t))return null;const e=m(t.id),n=m(t.title);return!e||!n?null:{id:e,title:n,status:mi(t.status),priority:g(t.priority),assignee:m(t.assignee),description:m(t.description),created_at:m(t.created_at),updated_at:m(t.updated_at)}}function gi(t){if(!U(t))return null;const e=m(t.from)??m(t.from_agent)??"system",n=m(t.content)??"",s=m(t.timestamp)??new Date().toISOString();return{id:m(t.id),seq:g(t.seq),from:e,content:n,timestamp:s,type:m(t.type)}}function yi(t){return Array.isArray(t)?t.map(e=>{if(!U(e))return null;const n=g(e.ts_unix);if(n==null)return null;const s=U(e.handoff)?e.handoff:null;return{ts:n,context_ratio:g(e.context_ratio)??0,context_tokens:g(e.context_tokens)??0,context_max:g(e.context_max)??0,latency_ms:g(e.latency_ms)??0,generation:g(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:g(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:g(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?g(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function bi(t){return(Array.isArray(t)?t:U(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!U(n))return null;const s=U(n.agent)?n.agent:null,a=U(n.context)?n.context:null,o=U(n.metrics_window)?n.metrics_window:void 0,r=m(n.name);if(!r)return null;const l=g(n.context_ratio)??g(a==null?void 0:a.context_ratio),d=m(n.status)??m(s==null?void 0:s.status)??"offline",u=Us(d),v=m(n.model)??m(n.active_model)??m(n.primary_model),c=kt(n.skill_secondary),f=a?{source:m(a.source),context_ratio:g(a.context_ratio),context_tokens:g(a.context_tokens),context_max:g(a.context_max),message_count:g(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,p=s?{name:m(s.name),status:m(s.status),current_task:m(s.current_task)??null,last_seen:m(s.last_seen)}:void 0,C=yi(n.metrics_series);return{name:r,emoji:m(n.emoji),koreanName:m(n.koreanName)??m(n.korean_name),agent_name:m(n.agent_name),trace_id:m(n.trace_id),model:v,primary_model:m(n.primary_model),active_model:m(n.active_model),next_model_hint:m(n.next_model_hint)??null,status:u,last_heartbeat:m(n.last_heartbeat)??m(s==null?void 0:s.last_seen),generation:g(n.generation),turn_count:g(n.turn_count)??g(n.total_turns),context_ratio:l,context_tokens:g(n.context_tokens)??g(a==null?void 0:a.context_tokens),context_max:g(n.context_max)??g(a==null?void 0:a.context_max),context_source:m(n.context_source)??m(a==null?void 0:a.source),context:f,traits:kt(n.traits),interests:kt(n.interests),primaryValue:m(n.primaryValue)??m(n.primary_value),activityLevel:g(n.activityLevel)??g(n.activity_level),memory_recent_note:m(n.memory_recent_note)??null,conversation_tail_count:g(n.conversation_tail_count),k2k_count:g(n.k2k_count),handoff_count_total:g(n.handoff_count_total)??g(n.trace_history_count),compaction_count:g(n.compaction_count),last_compaction_saved_tokens:g(n.last_compaction_saved_tokens),skill_primary:m(n.skill_primary)??null,skill_secondary:c,skill_reason:m(n.skill_reason)??null,metrics_series:C.length>0?C:void 0,metrics_window:o,agent:p}}).filter(n=>n!==null)}async function ye(t="full"){var s,a,o;const e=Date.now(),n=le[t];if(!(n&&e-n.time<_i)){Ge.value=!0;try{const r=await Ia(t);le[t]={data:r,time:e},_t.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map($i).filter(l=>l!==null),qt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(hi).filter(l=>l!==null),Fs.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(gi).filter(l=>l!==null),mt.value=bi(r.keepers),dn.value=U(r.status)?r.status:null,yt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{Ge.value=!1}}}async function st(){Ve.value=!0;try{const t=await Fa();Os.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Ve.value=!1}}async function et(){var t;Xe.value=!0;try{const e=lt.value||((t=dn.value)==null?void 0:t.room)||"default";lt.value||(lt.value=e);const n=await Ga(e);Hs.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Xe.value=!1}}let we=null,Se=null;function xi(){return Ts.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(We.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),We.value=n}Ye(),we||(we=setTimeout(()=>{ye(),we=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Se||(Se=setTimeout(()=>{st(),Se=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ye()}})}let wt=null;function ki(){wt||(wt=setInterval(()=>{Ye(),ye()},1e4))}function wi(){wt&&(clearInterval(wt),wt=null)}function b({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function G({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Si(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function V({timestamp:t}){const e=Si(t);return i`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const pn=_(null);function Bs(t){pn.value=t}function In(){pn.value=null}function te(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Ci({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${te(t.context_tokens)}</div>
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
  `}function Ti({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const f=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,p=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${p}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,r=e.map((f,p)=>{const C=a+p/(o-1)*(n-2*a),D=s-a-(f.context_ratio??0)*(s-2*a);return{x:C,y:D,p:f}}),l=r.map(({x:f,y:p})=>`${f.toFixed(1)},${p.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p:f})=>f.is_compaction).map(({x:f,y:p})=>i`
          <circle cx="${f.toFixed(1)}" cy="${p.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ce=_("");function Ai({keeper:t}){var a,o,r,l;const e=Ce.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ce.value}
        onInput=${d=>{Ce.value=d.target.value}}
      />
      ${s.map(d=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?i`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?i`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?i`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${te(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${te(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${te(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Ni({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>i`
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
  `}function Di({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Ei({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Fn({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Te(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Ri({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Te(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Te(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Te(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Pi(){var e,n,s;const t=pn.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&In()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?i`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${G} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>In()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ci} keeper=${t} />

        ${""}
        <${Ti} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Ai} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Fn} traits=${t.traits??[]} label="Traits" />
            <${Fn} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${V} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?i`
              <${b} title="TRPG Stats">
                <${Ni} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${b} title="Equipment (${t.inventory.length})">
                <${Di} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${Ei} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${Ri} keeper=${t} />
          <//>

          <${b} title="Memory & Context">
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
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
      </div>
    </div>
  `:null}let Li=0;const tt=_([]);function y(t,e="success",n=4e3){const s=++Li;tt.value=[...tt.value,{id:s,message:t,type:e}],setTimeout(()=>{tt.value=tt.value.filter(a=>a.id!==s)},n)}function ji(t){tt.value=tt.value.filter(e=>e.id!==t)}function Mi(){const t=tt.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>ji(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Ii="masc_dashboard_agent_name",$t=_(null),ce=_(!1),Ot=_(""),ue=_([]),Ht=_([]),ct=_(""),St=_(!1);function Ks(t){$t.value=t,vn()}function On(){$t.value=null,Ot.value="",ue.value=[],Ht.value=[],ct.value=""}function Fi(){const t=$t.value;return t?_t.value.find(e=>e.name===t)??null:null}function qs(t){return t?qt.value.filter(e=>e.assignee===t):[]}async function vn(){const t=$t.value;if(t){ce.value=!0,Ot.value="",ue.value=[],Ht.value=[];try{const e=await ai(80);ue.value=e.filter(a=>a.includes(t)).slice(0,20);const n=qs(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await ii(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Ht.value=s}catch(e){Ot.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ce.value=!1}}}async function Hn(){var s;const t=$t.value,e=ct.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Ii))==null?void 0:s.trim())||"dashboard";St.value=!0;try{await Ms(n,`@${t} ${e}`),ct.value="",y(`Mention sent to ${t}`,"success"),vn()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";y(o,"error")}finally{St.value=!1}}function Oi({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${G} status=${t.status} />
    </div>
  `}function Hi({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function zi(){var a,o,r,l;const t=$t.value;if(!t)return null;const e=Fi(),n=qs(t),s=ue.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&On()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?i`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?i`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?i`
                        <${G} status=${e.status} />
                        ${e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?i`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:i`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?i`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(d=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${V} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{vn()}} disabled=${ce.value}>
              ${ce.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${On}>Close</button>
          </div>
        </div>

        ${Ot.value?i`<div class="council-error">${Ot.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(d=>i`<${Oi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${s.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${s.map((d,u)=>i`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${Ht.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Ht.value.map(d=>i`<${Hi} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${ct.value}
              onInput=${d=>{ct.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Hn()}}
              disabled=${St.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Hn()}}
              disabled=${St.value||ct.value.trim()===""}
            >
              ${St.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function it({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Ui({agent:t}){return i`
    <div class="agent" onClick=${()=>Ks(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${G} status=${t.status} />
      ${t.current_task?i`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Bi(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ki(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function zn(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function qi({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=pi.value.get(t.name),a=fi.value.has(t.name);return i`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Bs(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
          ${s?i`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?i`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?i`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?i`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?i`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${zn(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${zn(e)}">
              ${n}%
              ${t.context_tokens!=null?i` (${Bi(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?i`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?i`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?i`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?i`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?i`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?i`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${V} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?i`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(o=>i`<span class="keeper-trait-chip">${o}</span>`)}
            ${t.traits.length>3?i`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?i`
          <div class="keeper-note-preview">${Ki(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Un(){const t=dn.value,e=_t.value,n=mt.value,s=zs.value;return i`
    <div class="stats-grid">
      <${it} label="Agents" value=${e.length} />
      <${it} label="Active" value=${ui.value.length} color="#4ade80" />
      <${it} label="Keepers" value=${n.length} color="#22d3ee" />
      <${it} label="Tasks" value=${qt.value.length} />
      <${it} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${it} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?i`<div class="empty-state">No agents connected</div>`:e.map(a=>i`<${Ui} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?i`<div class="empty-state">No keepers active</div>`:n.map(a=>i`<${qi} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${yt.value?i`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${yt.value.running?"Running":"Stopped"}</span>
            ${yt.value.goal?i`<span>Goal: ${yt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?i`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?i`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?i`<span>Project: ${t.project}</span>`:null}
            ${t.version?i`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Ji(t.uptime_seconds??0)}</span>
            ${t.paused?i`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?i`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?i`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Ji(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const Qe=_([]),Ze=_([]),Ct=_(""),de=_(!1),Tt=_(!1),pe=_(""),ve=_(null),At=_(""),tn=_(!1);async function en(){de.value=!0,pe.value="";try{const[t,e]=await Promise.all([oi(),ri()]);Qe.value=t,Ze.value=e}catch(t){pe.value=t instanceof Error?t.message:"Failed to load council data"}finally{de.value=!1}}async function Bn(){const t=Ct.value.trim();if(t){Tt.value=!0;try{const e=await li(t);Ct.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await en()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{Tt.value=!1}}}async function Wi(t){ve.value=t,tn.value=!0,At.value="";try{At.value=await ci(t)}catch(e){At.value=e instanceof Error?e.message:"Failed to load debate status"}finally{tn.value=!1}}function Gi({debate:t}){const e=ve.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Wi(t.id)}
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
  `}function Vi({session:t}){return i`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Xi(){return se(()=>{en()},[]),i`
    <div>
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Ct.value}
            onInput=${t=>{Ct.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Bn()}}
            disabled=${Tt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Bn}
            disabled=${Tt.value||Ct.value.trim()===""}
          >
            ${Tt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${en} disabled=${de.value}>
            ${de.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${pe.value?i`<div class="council-error">${pe.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${Qe.value.length===0?i`<div class="empty-state">No debates yet</div>`:Qe.value.map(t=>i`<${Gi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Ze.value.length===0?i`<div class="empty-state">No active sessions</div>`:Ze.value.map(t=>i`<${Vi} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${b} title=${ve.value?`Debate Detail (${ve.value})`:"Debate Detail"} class="section">
        ${tn.value?i`<div class="loading-indicator">Loading debate detail...</div>`:At.value?i`<pre class="council-detail">${At.value}</pre>`:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Yi({text:t}){if(!t)return null;const e=Qi(t);return i`<div class="markdown-content">${e}</div>`}function Qi(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ae(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Ae(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),s++}o.length>0&&n.push(i`<p>${Ae(o.join(`
`))}</p>`)}return n}function Ae(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Zi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Nt=_([]),Dt=_(!1),Et=_(""),to=_("dashboard-user"),Rt=_(!1);async function Js(t){Dt.value=!0,Nt.value=[];try{const e=await Oa(t);Nt.value=e.comments??[]}catch{}finally{Dt.value=!1}}async function Kn(t){const e=Et.value.trim();if(e){Rt.value=!0;try{await Ha(t,to.value,e),Et.value="",y("Comment posted","success"),await Js(t),st()}catch{y("Failed to post comment","error")}finally{Rt.value=!1}}}function eo(){const t=Mn.value;return i`
    <div class="board-controls">
      ${Zi.map(e=>i`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Mn.value=e.id,st()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Ws({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function no({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await js(t.id,n),st()}catch{y("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>ya(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ws} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${V} timestamp=${t.created_at} />
          ${t.comment_count>0?i`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function so({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${V} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function ao({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Et.value}
        onInput=${e=>{Et.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Kn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Rt.value}
      />
      <button
        onClick=${()=>Kn(t)}
        disabled=${Rt.value||Et.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Rt.value?"...":"Post"}
      </button>
    </div>
  `}function io({post:t}){Nt.value.length===0&&!Dt.value&&Js(t.id);const e=async n=>{try{await js(t.id,n),st()}catch{y("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ge("board")}>← Back to Board</button>
      <${b} title=${i`${t.title} <${Ws} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Yi} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${V} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${Dt.value?"...":Nt.value.length})">
        ${Dt.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${so} comments=${Nt.value} />`}
        <${ao} postId=${t.id} />
      <//>
    </div>
  `}function oo(){const t=Os.value,e=Ve.value,n=q.value.postId;if(n){const s=t.find(a=>a.id===n);return s?i`<${io} post=${s} />`:i`
          <div>
            <button class="back-btn" onClick=${()=>ge("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return i`
    <${eo} />
    ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`<div class="empty-state">No posts yet</div>`:i`<div class="board-post-list">
            ${t.map(s=>i`<${no} key=${s.id} post=${s} />`)}
          </div>`}
  `}function ro(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function lo(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function qn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function co({row:t}){return i`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${V} timestamp=${t.timestamp} /></span>
    </div>
  `}function uo(){const t=Fs.value.map(ro),e=re.value.map(lo),n=[...t,...e].sort((s,a)=>qn(a.timestamp)-qn(s.timestamp)).slice(0,80);return i`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?i`<div class="empty-state">No recent activity</div>`:n.map(s=>i`<${co} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function po({agent:t}){return i`
    <button class="agent-card ${t.status}" onClick=${()=>Ks(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?i`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${G} status=${t.status} />
      </div>
      ${t.current_task?i`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?i`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function vo({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return i`
    <div class="live-agent keeper-card" onClick=${()=>Bs(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
          ${t.model?i`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?i`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?i`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?i`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?i`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?i`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function fo(){const t=_t.value,e=mt.value;return i`
    <div>
      ${e.length>0?i`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>i`<${vo} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?i`<div class="empty-state">No agents registered</div>`:i`
            <div class="agent-grid">
              ${t.map(n=>i`<${po} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ne({task:t}){return i`
    <div class="task-row">
      <${G} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?i`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?i`<${V} timestamp=${t.created_at} />`:null}
    </div>
  `}function _o(){const{todo:t,inProgress:e,done:n}=zs.value;return i`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?i`<div class="empty-state">No tasks in progress</div>`:e.map(s=>i`<${Ne} key=${s.id} task=${s} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?i`<div class="empty-state">No pending tasks</div>`:t.map(s=>i`<${Ne} key=${s.id} task=${s} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?i`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(s=>i`<${Ne} key=${s.id} task=${s} />`)}
            ${n.length>20?i`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function mo({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return i`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function $o(){const t=re.value;return i`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?i`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>i`<${mo} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const gt=_(""),De=_("ability_check"),Ee=_("10"),Re=_("12"),Gt=_(""),Vt=_("idle"),Xt=_(""),Yt=_("keeper-late"),Pe=_("player"),Le=_(""),I=_("idle"),je=_(null);function ho(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function go(t,e){return e>0?Math.round(t/e*100):0}const yo={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},bo={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Me(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function xo(t){const e=t.trim().toLowerCase();return yo[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function ko(t){const e=t.trim().toLowerCase();return bo[e]??"상황에 따라 선택되는 전술 액션입니다."}function Ie(t){return typeof t=="object"&&t!==null}function Fe(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Jn(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Wn(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function wo({hp:t,max:e}){const n=go(t,e),s=ho(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function So({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Co({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function To({actor:t}){var o,r;const e=(o=t.archetype)==null?void 0:o.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return i`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${G} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Co} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${wo} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${So} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Me(e)}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(l=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Me(l)}</span>
                  <span class="trpg-annot-desc">${xo(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(l=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Me(l)}</span>
                  <span class="trpg-annot-desc">${ko(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Ao({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function No({events:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No story events yet</div>`:i`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return i`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?i`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?i`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${V} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Do({state:t}){const e=t.history??[];return e.length===0?null:i`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>i`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Eo({state:t}){var d;const e=lt.value||((d=t.session)==null?void 0:d.room)||"",n=Vt.value,s=t.party??[];if(!s.find(u=>u.id===gt.value)&&s.length>0){const u=s[0];u&&(gt.value=u.id)}const o=async()=>{if(!e){y("No room set","error");return}Vt.value="running";try{await Va(e),Vt.value="ok",y("Round executed","success"),et()}catch{Vt.value="error",y("Round failed","error")}},r=async()=>{if(e)try{await Qa(e),y("Turn advanced","success"),et()}catch{y("Advance failed","error")}},l=async()=>{if(!e)return;const u=gt.value.trim();if(!u){y("Select actor first","warning");return}const v=Number.parseInt(Ee.value,10),c=Number.parseInt(Re.value,10);if(Number.isNaN(v)||Number.isNaN(c)){y("Stat/DC must be numbers","warning");return}const f=Number.parseInt(Gt.value,10),p=Gt.value.trim()===""||Number.isNaN(f)?void 0:f;try{await Ya({roomId:e,actorId:u,action:De.value.trim()||"ability_check",statValue:v,dc:c,rawD20:p}),y("Dice rolled","success"),et()}catch{y("Dice roll failed","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${u=>{lt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${gt.value}
            onChange=${u=>{gt.value=u.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(u=>i`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${De.value}
              onInput=${u=>{De.value=u.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${Ee.value}
              onInput=${u=>{Ee.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${Re.value}
              onInput=${u=>{Re.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${Gt.value}
              onInput=${u=>{Gt.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&l()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${l}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${o}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${r}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?i`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function Ro({state:t}){var l;const e=lt.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=je.value,a=Ie(s)?s:null,o=async()=>{const d=Xt.value.trim(),u=Yt.value.trim();if(!e||!d){y("Room/Actor is required","warning");return}I.value="checking";try{const v=await Za(e,d,u||void 0);je.value=v,I.value="ok",y("Eligibility updated","success")}catch(v){I.value="error";const c=v instanceof Error?v.message:"Eligibility check failed";y(c,"error")}},r=async()=>{const d=Xt.value.trim(),u=Yt.value.trim(),v=Le.value.trim();if(!e||!d||!u){y("Room/Actor/Keeper is required","warning");return}I.value="requesting";try{const c=await ti({room_id:e,actor_id:d,keeper_name:u,role:Pe.value,...v?{name:v}:{}});je.value=c;const f=Ie(c)?Wn(c,"granted",!1):!1,p=Ie(c)?Fe(c,"reason_code",""):"";f?y("Mid-join granted","success"):y(`Mid-join rejected${p?`: ${p}`:""}`,"warning"),I.value=f?"ok":"error",et()}catch(c){I.value="error";const f=c instanceof Error?c.message:"Mid-join request failed";y(f,"error")}};return i`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${n!=null&&n.phase_open?"OPEN":"CLOSED"}</strong>
        ${n!=null&&n.window?i`<span style="margin-left:8px;">(${n.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(n==null?void 0:n.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            type="text"
            value=${Xt.value}
            onInput=${d=>{Xt.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            type="text"
            value=${Yt.value}
            onInput=${d=>{Yt.value=d.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Pe.value}
            onChange=${d=>{Pe.value=d.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            type="text"
            value=${Le.value}
            onInput=${d=>{Le.value=d.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${o} disabled=${I.value==="checking"||I.value==="requesting"}>
              ${I.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${r} disabled=${I.value==="checking"||I.value==="requesting"}>
              ${I.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Wn(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Jn(a,"effective_score",0)}/${Jn(a,"required_points",0)}</span>
            ${Fe(a,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${Fe(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Po({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Lo({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function jo(){var a,o;const t=Hs.value;if(Xe.value&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>et()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[];return i`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((a=t.session)==null?void 0:a.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((o=t.current_round)==null?void 0:o.round_number)??0}</div>
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

      ${""}
      <${Lo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${s.length})">
            <${No} events=${s} />
          <//>

          ${""}
          ${t.map?i`
              <${b} title="Map" style="margin-top:16px;">
                <${Ao} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${Eo} state=${t} />
          <//>

          ${""}
          <${b} title="Mid-Join Gate" style="margin-top:16px;">
            <${Ro} state=${t} />
          <//>

          ${""}
          <${b} title="Contribution" style="margin-top:16px;">
            <${Po} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>i`<${To} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?i`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${Do} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const fn="masc_dashboard_agent_name";function Mo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(fn);return e??n??"dashboard"}const B=_(Mo()),Pt=_(""),Lt=_(""),fe=_(""),jt=_(!1),ot=_(!1),Mt=_(!1),It=_(!1),_e=_(!1),be=_(!1);function _n(t){const e=t.trim();B.value=e,e&&localStorage.setItem(fn,e)}function Io(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function nn(){const t=B.value.trim();if(t){Mt.value=!0;try{const e=await ni(t),n=Io(e);n&&_n(n),be.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Mt.value=!1}}}async function Fo(){const t=B.value.trim();if(t){It.value=!0;try{await Is(t),be.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{It.value=!1}}}async function Oo(){const t=B.value.trim();if(t)try{await Is(t)}catch{}localStorage.removeItem(fn),_n("dashboard"),be.value=!1,await nn()}async function Ho(){const t=B.value.trim();if(t){_e.value=!0;try{await si(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{_e.value=!1}}}async function Gn(){const t=B.value.trim(),e=Pt.value.trim();if(!(!t||!e)){jt.value=!0;try{await Ms(t,e),Pt.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{jt.value=!1}}}async function zo(){const t=Lt.value.trim(),e=fe.value.trim()||"Created from dashboard";if(t){ot.value=!0;try{await ei(t,e,1),Lt.value="",fe.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{ot.value=!1}}}function Uo(){return se(()=>{nn()},[]),i`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${B.value}
        onInput=${t=>_n(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Pt.value}
          onInput=${t=>{Pt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Gn()}}
          disabled=${jt.value}
        />
        <button
          class="control-btn"
          onClick=${Gn}
          disabled=${jt.value||Pt.value.trim()===""||B.value.trim()===""}
        >
          ${jt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{nn()}}
          disabled=${Mt.value||B.value.trim()===""}
        >
          ${Mt.value?"Joining...":be.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Fo()}}
          disabled=${It.value||B.value.trim()===""}
        >
          ${It.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Oo()}}
          disabled=${Mt.value||It.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ho()}}
          disabled=${_e.value||B.value.trim()===""}
        >
          ${_e.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Lt.value}
        onInput=${t=>{Lt.value=t.target.value}}
        disabled=${ot.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${fe.value}
        onInput=${t=>{fe.value=t.target.value}}
        disabled=${ot.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${zo}
        disabled=${ot.value||Lt.value.trim()===""}
      >
        ${ot.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function Bo(){const t=pt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${cn.value} events</span>
    </div>
  `}const Ko=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function qo(){const t=q.value.tab,e=pt.value;return i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Ko.map(n=>i`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>ge(n.id)}
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
            <strong>${_t.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${mt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${qt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${cn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ye(),t==="board"&&st(),t==="trpg"&&et()}}
        >
          Refresh Now
        </button>
      </section>

      <${Uo} />
    </aside>
  `}function Jo(){switch(q.value.tab){case"overview":return i`<${Un} />`;case"council":return i`<${Xi} />`;case"board":return i`<${oo} />`;case"activity":return i`<${uo} />`;case"agents":return i`<${fo} />`;case"tasks":return i`<${_o} />`;case"journal":return i`<${$o} />`;case"trpg":return i`<${jo} />`;default:return i`<${Un} />`}}function Wo(){return se(()=>{ba(),Ns(),ye();const t=xi();return ki(),()=>{Da(),t(),wi()}},[]),se(()=>{const t=q.value.tab;t==="board"&&st(),t==="trpg"&&et()},[q.value.tab]),i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Real-time multi-agent operations console</p>
        </div>
        <div class="header-right">
          <${Bo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${ka} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Ge.value&&!pt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Jo} />`}
        </main>
        <${qo} />
      </div>

      <${Pi} />
      <${zi} />
      <${Mi} />
    </div>
  `}const Vn=document.getElementById("app");Vn&&ia(i`<${Wo} />`,Vn);
