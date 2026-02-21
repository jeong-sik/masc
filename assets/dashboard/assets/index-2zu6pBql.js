(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var ve,k,Fn,Hn,Z,cn,On,zn,Un,Je,De,Pe,jt={},Bn=[],Fa=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,fe=Array.isArray;function K(t,e){for(var n in e)t[n]=e[n];return t}function qe(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Kn(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?ve.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return qt(t,r,a,s,null)}function qt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Fn,__i:-1,__u:0};return s==null&&k.vnode!=null&&k.vnode(i),i}function Ot(t){return t.children}function gt(t,e){this.props=t,this.context=e}function lt(t,e){if(e==null)return t.__?lt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?lt(t):null}function Wn(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Wn(t)}}function un(t){(!t.__d&&(t.__d=!0)&&Z.push(t)&&!Yt.__r++||cn!=k.debounceRendering)&&((cn=k.debounceRendering)||On)(Yt)}function Yt(){for(var t,e,n,a,s,i,r,l=1;Z.length;)Z.length>l&&Z.sort(zn),t=Z.shift(),l=Z.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=K({},a)).__v=a.__v+1,k.vnode&&k.vnode(n),Xe(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??lt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Jn(i,n,r),a.__e=a.__=null,n.__e!=s&&Wn(n)));Yt.__r=0}function Vn(t,e,n,a,s,i,r,l,d,u,_){var c,p,v,S,D,T,C,y=a&&a.__k||Bn,M=e.length;for(d=Ha(n,e,y,d,M),c=0;c<M;c++)(v=n.__k[c])!=null&&(p=v.__i==-1?jt:y[v.__i]||jt,v.__i=c,T=Xe(t,v,p,s,i,r,l,d,u,_),S=v.__e,v.ref&&p.ref!=v.ref&&(p.ref&&Qe(p.ref,null,v),_.push(v.ref,v.__c||S,v)),D==null&&S!=null&&(D=S),(C=!!(4&v.__u))||p.__k===v.__k?d=Gn(v,d,t,C):typeof v.type=="function"&&T!==void 0?d=T:S&&(d=S.nextSibling),v.__u&=-7);return n.__e=D,d}function Ha(t,e,n,a,s){var i,r,l,d,u,_=n.length,c=_,p=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=qt(null,r,null,null,null):fe(r)?r=t.__k[i]=qt(Ot,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=qt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=Oa(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(s>_?p--:s<_&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<_;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==a&&(a=lt(l)),Xn(l,l));return a}function Gn(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Gn(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=lt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Oa(t,e,n,a){var s,i,r,l=t.key,d=t.type,u=e[n],_=u!=null&&(2&u.__u)==0;if(u===null&&l==null||_&&l==u.key&&d==u.type)return n;if(a>(_?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((u=e[r=s>=0?s--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function dn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Fa.test(e)?n:n+"px"}function Wt(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||dn(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||dn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Un,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Je,t.addEventListener(e,i?Pe:De,i)):t.removeEventListener(e,i?Pe:De,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function pn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Je++;else if(e.t<n.u)return;return n(k.event?k.event(e):e)}}}function Xe(t,e,n,a,s,i,r,l,d,u){var _,c,p,v,S,D,T,C,y,M,E,B,b,X,Q,Y,mt,L=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(_=k.__b)&&_(e);t:if(typeof L=="function")try{if(C=e.props,y="prototype"in L&&L.prototype.render,M=(_=L.contextType)&&a[_.__c],E=_?M?M.props.value:_.__:a,n.__c?T=(c=e.__c=n.__c).__=c.__E:(y?e.__c=c=new L(C,E):(e.__c=c=new gt(C,E),c.constructor=L,c.render=Ua),M&&M.sub(c),c.state||(c.state={}),c.__n=a,p=c.__d=!0,c.__h=[],c._sb=[]),y&&c.__s==null&&(c.__s=c.state),y&&L.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=K({},c.__s)),K(c.__s,L.getDerivedStateFromProps(C,c.__s))),v=c.props,S=c.state,c.__v=e,p)y&&L.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),y&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(y&&L.getDerivedStateFromProps==null&&C!==v&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(C,E),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(C,c.__s,E)===!1){for(e.__v!=n.__v&&(c.props=C,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(J){J&&(J.__=e)}),B=0;B<c._sb.length;B++)c.__h.push(c._sb[B]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(C,c.__s,E),y&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(v,S,D)})}if(c.context=E,c.props=C,c.__P=t,c.__e=!1,b=k.__r,X=0,y){for(c.state=c.__s,c.__d=!1,b&&b(e),_=c.render(c.props,c.state,c.context),Q=0;Q<c._sb.length;Q++)c.__h.push(c._sb[Q]);c._sb=[]}else do c.__d=!1,b&&b(e),_=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++X<25);c.state=c.__s,c.getChildContext!=null&&(a=K(K({},a),c.getChildContext())),y&&!p&&c.getSnapshotBeforeUpdate!=null&&(D=c.getSnapshotBeforeUpdate(v,S)),Y=_,_!=null&&_.type===Ot&&_.key==null&&(Y=qn(_.props.children)),l=Vn(t,fe(Y)?Y:[Y],e,n,a,s,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),T&&(c.__E=c.__=null)}catch(J){if(e.__v=null,d||i!=null)if(J.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(mt=i.length;mt--;)qe(i[mt]);Ee(e)}else e.__e=n.__e,e.__k=n.__k,J.then||Ee(e);k.__e(J,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=za(n.__e,e,n,a,s,i,r,d,u);return(_=k.diffed)&&_(e),128&e.__u?void 0:l}function Ee(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Ee)}function Jn(t,e,n){for(var a=0;a<n.length;a++)Qe(n[a],n[++a],n[++a]);k.__c&&k.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){k.__e(i,s.__v)}})}function qn(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:fe(t)?t.map(qn):K({},t)}function za(t,e,n,a,s,i,r,l,d){var u,_,c,p,v,S,D,T=n.props||jt,C=e.props,y=e.type;if(y=="svg"?s="http://www.w3.org/2000/svg":y=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((v=i[u])&&"setAttribute"in v==!!y&&(y?v.localName==y:v.nodeType==3)){t=v,i[u]=null;break}}if(t==null){if(y==null)return document.createTextNode(C);t=document.createElementNS(s,y,C.is&&C),l&&(k.__m&&k.__m(e,i),l=!1),i=null}if(y==null)T===C||l&&t.data==C||(t.data=C);else{if(i=i&&ve.call(t.childNodes),!l&&i!=null)for(T={},u=0;u<t.attributes.length;u++)T[(v=t.attributes[u]).name]=v.value;for(u in T)if(v=T[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=v;else if(!(u in C)){if(u=="value"&&"defaultValue"in C||u=="checked"&&"defaultChecked"in C)continue;Wt(t,u,null,v,s)}}for(u in C)v=C[u],u=="children"?p=v:u=="dangerouslySetInnerHTML"?_=v:u=="value"?S=v:u=="checked"?D=v:l&&typeof v!="function"||T[u]===v||Wt(t,u,v,T[u],s);if(_)l||c&&(_.__html==c.__html||_.__html==t.innerHTML)||(t.innerHTML=_.__html),e.__k=[];else if(c&&(t.innerHTML=""),Vn(e.type=="template"?t.content:t,fe(p)?p:[p],e,n,a,y=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&lt(n,0),l,d),i!=null)for(u=i.length;u--;)qe(i[u]);l||(u="value",y=="progress"&&S==null?t.removeAttribute("value"):S!=null&&(S!==t[u]||y=="progress"&&!S||y=="option"&&S!=T[u])&&Wt(t,u,S,T[u],s),u="checked",D!=null&&D!=t[u]&&Wt(t,u,D,T[u],s))}return t}function Qe(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){k.__e(s,n)}}function Xn(t,e,n){var a,s;if(k.unmount&&k.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Qe(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){k.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Xn(a[s],e,n||typeof t.type!="function");n||qe(t.__e),t.__c=t.__=t.__e=void 0}function Ua(t,e,n){return this.constructor(t,n)}function Ba(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),k.__&&k.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Xe(e,t=e.__k=Kn(Ot,null,[t]),s||jt,jt,e.namespaceURI,s?null:e.firstChild?ve.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Jn(i,t,r)}ve=Bn.slice,k={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(l){t=l}throw t}},Fn=0,Hn=function(t){return t!=null&&t.constructor===void 0},gt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=K({},this.state),typeof t=="function"&&(t=t(K({},n),this.props)),t&&K(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),un(this))},gt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),un(this))},gt.prototype.render=Ot,Z=[],On=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,zn=function(t,e){return t.__v.__b-e.__v.__b},Yt.__r=0,Un=/(PointerCapture)$|Capture$/i,Je=0,De=pn(!1),Pe=pn(!0);var Qn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=l:r===4?a[1]=Object.assign(a[1]||{},l):r===5?(a[1]=a[1]||{})[e[++i]]=l:r===6?a[1][e[++i]]+=l+"":r?(s=t.apply(l,Qn(t,l,n,["",null])),a.push(s),l[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(l)}return a},vn=new Map;function Ka(t){var e=vn.get(this);return e||(e=new Map,vn.set(this,e)),(e=Qn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,s),i=6),p&&(d.push(i,p,0,s),i=6)),r=""},_=0;_<n.length;_++){_&&(i===1&&u(),u(_));for(var c=0;c<n[_].length;c++)a=n[_][c],i===1?a==="<"?(u(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:l?a===l?l="":r+=a:a==='"'||a==="'"?l=a:a===">"?(u(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[_][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(u(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Ka.bind(Kn),Zt,P,ge,fn,_n=0,Yn=[],A=k,mn=A.__b,hn=A.__r,$n=A.diffed,gn=A.__c,yn=A.unmount,bn=A.__;function Zn(t,e){A.__h&&A.__h(P,t,_n||e),_n=0;var n=P.__H||(P.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function te(t,e){var n=Zn(Zt++,3);!A.__s&&ea(n.__H,e)&&(n.__=t,n.u=e,P.__H.__h.push(n))}function ta(t,e){var n=Zn(Zt++,7);return ea(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Wa(){for(var t;t=Yn.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Xt),t.__H.__h.forEach(Le),t.__H.__h=[]}catch(e){t.__H.__h=[],A.__e(e,t.__v)}}A.__b=function(t){P=null,mn&&mn(t)},A.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),bn&&bn(t,e)},A.__r=function(t){hn&&hn(t),Zt=0;var e=(P=t.__c).__H;e&&(ge===P?(e.__h=[],P.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Xt),e.__h.forEach(Le),e.__h=[],Zt=0)),ge=P},A.diffed=function(t){$n&&$n(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Yn.push(e)!==1&&fn===A.requestAnimationFrame||((fn=A.requestAnimationFrame)||Va)(Wa)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ge=P=null},A.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Xt),n.__h=n.__h.filter(function(a){return!a.__||Le(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],A.__e(a,n.__v)}}),gn&&gn(t,e)},A.unmount=function(t){yn&&yn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Xt(a)}catch(s){e=s}}),n.__H=void 0,e&&A.__e(e,n.__v))};var xn=typeof requestAnimationFrame=="function";function Va(t){var e,n=function(){clearTimeout(a),xn&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);xn&&(e=requestAnimationFrame(n))}function Xt(t){var e=P,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),P=e}function Le(t){var e=P;t.__c=t.__(),P=e}function ea(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var Ga=Symbol.for("preact-signals");function _e(){if(q>1)q--;else{for(var t,e=!1;yt!==void 0;){var n=yt;for(yt=void 0,Re++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&sa(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Re=0,q--,e)throw t}}function Ja(t){if(q>0)return t();q++;try{return t()}finally{_e()}}var g=void 0;function na(t){var e=g;g=void 0;try{return t()}finally{g=e}}var yt=void 0,q=0,Re=0,ee=0;function aa(t){if(g!==void 0){var e=t.n;if(e===void 0||e.t!==g)return e={i:0,S:t,p:g.s,n:void 0,t:g,e:void 0,x:void 0,r:e},g.s!==void 0&&(g.s.n=e),g.s=e,t.n=e,32&g.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=g.s,e.n=void 0,g.s.n=e,g.s=e),e}}function N(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}N.prototype.brand=Ga;N.prototype.h=function(){return!0};N.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:na(function(){var a;(a=e.W)==null||a.call(e)}))};N.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&na(function(){var s;(s=e.Z)==null||s.call(e)}))}};N.prototype.subscribe=function(t){var e=this;return zt(function(){var n=e.value,a=g;g=void 0;try{t(n)}finally{g=a}},{name:"sub"})};N.prototype.valueOf=function(){return this.value};N.prototype.toString=function(){return this.value+""};N.prototype.toJSON=function(){return this.value};N.prototype.peek=function(){var t=g;g=void 0;try{return this.value}finally{g=t}};Object.defineProperty(N.prototype,"value",{get:function(){var t=aa(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Re>100)throw new Error("Cycle detected");this.v=t,this.i++,ee++,q++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{_e()}}}});function f(t,e){return new N(t,e)}function sa(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function ia(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function oa(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function et(t,e){N.call(this,void 0),this.x=t,this.s=void 0,this.g=ee-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}et.prototype=new N;et.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ee))return!0;if(this.g=ee,this.f|=1,this.i>0&&!sa(this))return this.f&=-2,!0;var t=g;try{ia(this),g=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return g=t,oa(this),this.f&=-2,!0};et.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}N.prototype.S.call(this,t)};et.prototype.U=function(t){if(this.t!==void 0&&(N.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};et.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(et.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=aa(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ct(t,e){return new et(t,e)}function ra(t){var e=t.u;if(t.u=void 0,typeof e=="function"){q++;var n=g;g=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Ye(t),a}finally{g=n,_e()}}}function Ye(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,ra(t)}function qa(t){if(g!==this)throw new Error("Out-of-order effect");oa(this),g=t,this.f&=-2,8&this.f&&Ye(this),_e()}function dt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}dt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};dt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,ra(this),ia(this),q++;var t=g;return g=this,qa.bind(this,t)};dt.prototype.N=function(){2&this.f||(this.f|=2,this.o=yt,yt=this)};dt.prototype.d=function(){this.f|=8,1&this.f||Ye(this)};dt.prototype.dispose=function(){this.d()};function zt(t,e){var n=new dt(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var la,Vt,Xa=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,ca=[];zt(function(){la=this.N})();function pt(t,e){k[t]=e.bind(null,k[t]||function(){})}function ne(t){if(Vt){var e=Vt;Vt=void 0,e()}Vt=t&&t.S()}function ua(t){var e=this,n=t.data,a=Ya(n);a.value=n;var s=ta(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=ct(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),_=ct(function(){return!Array.isArray(u.value)&&!Hn(u.value)}),c=zt(function(){if(this.N=da,_.value){var v=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=v)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[_,u]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}ua.displayName="ReactiveTextNode";Object.defineProperties(N.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:ua},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});pt("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof N&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});pt("__r",function(t,e){if(t(e),e.type!==Ot){ne();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return zt(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Xa&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ne(n)}});pt("__e",function(t,e,n,a){ne(),t(e,n,a)});pt("diffed",function(t,e){ne();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in a)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var u=i[d],_=a[d];u===void 0?(u=Qa(n,d,_),i[d]=u):u.o(_,s)}for(var c in a)s[c]=a[c]}}t(e)});function Qa(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:zt(function(){this.N=da;var l=i.value.value;r!==l?(r=void 0,s?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}pt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});pt("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});gt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Ya(t,e){return ta(function(){return f(t,e)},[])}var Za=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ts(){Ja(function(){for(var t;t=ca.shift();)la.call(t)})}function da(){ca.push(this)===1&&(k.requestAnimationFrame||Za)(ts)}const es=["overview","board","activity","agents","tasks","journal","trpg","council"],pa={tab:"overview",params:{},postId:null};function kn(t){return!!t&&es.includes(t)}function Me(t){try{return decodeURIComponent(t)}catch{return t}}function Ie(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function ns(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function va(t,e){const n=t[0],a=e.tab,s=kn(n)?n:kn(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Me(t[2]):t[0]==="post"&&t[1]&&(i=Me(t[1]))),{tab:s,params:e,postId:i}}function ae(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return pa;const n=Me(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),s=n.slice(l+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Ie(s),r=ns(a);return va(r,i)}function as(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...pa,params:Ie(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Ie(e.replace(/^\?/,""));return va(a,s)}function fa(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const U=f(ae(window.location.hash));window.addEventListener("hashchange",()=>{U.value=ae(window.location.hash)});function me(t,e){const n={tab:t,params:{},postId:null};window.location.hash=fa(n)}function ss(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function is(){if(window.location.hash&&window.location.hash!=="#"){U.value=ae(window.location.hash);return}const t=as(window.location.pathname,window.location.search);if(t){U.value=t;const e=fa(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",U.value=ae(window.location.hash)}const os=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function rs(){const t=U.value.tab;return o`
    <div class="main-tab-bar">
      ${os.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>me(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const wn="masc_dashboard_sse_session_id",ls=1e3,cs=15e3,ut=f(!1),Ze=f(0),_a=f(null),se=f([]);function us(){let t=sessionStorage.getItem(wn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(wn,t)),t}const ds=200;function I(t,e){const n={agent:t,text:e,timestamp:Date.now()};se.value=[n,...se.value].slice(0,ds)}let O=null,it=null,je=0;function ma(){it&&(clearTimeout(it),it=null)}function ps(){if(it)return;je++;const t=Math.min(je,5),e=Math.min(cs,ls*Math.pow(2,t));it=setTimeout(()=>{it=null,ha()},e)}function ha(){ma(),O&&(O.close(),O=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",us());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);O=i,i.onopen=()=>{O===i&&(je=0,ut.value=!0)},i.onerror=()=>{O===i&&(ut.value=!1,i.close(),O=null,ps())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Ze.value++,_a.value=l,vs(l)}catch{}}}function vs(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":I(n,"Joined");break;case"agent_left":I(n,"Left");break;case"broadcast":I(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":I(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":I(n,"New post");break;case"board_comment":I(n,"New comment");break;case"keeper_heartbeat":I(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":I(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":I(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":I(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:I(n,e)}}function fs(){ma(),O&&(O.close(),O=null),ut.value=!1}function $a(){return new URLSearchParams(window.location.search)}function ga(){const t=$a(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function ya(){return{...ga(),"Content-Type":"application/json"}}const _s=15e3,ba=3e4,ms=6e4;async function tn(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(s)}}function hs(){var e,n;const t=$a();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Ut(t){const e=await tn(t,{headers:ga()},_s);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Bt(t,e){const n=await tn(t,{method:"POST",headers:ya(),body:JSON.stringify(e)},ba);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function $s(t,e,n,a=ba){const s=await tn(t,{method:"POST",headers:{...ya(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Error(`POST ${t}: ${s.status} ${s.statusText}`);return s.text()}function gs(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ys(t){var e,n,a,s,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function H(t,e){const n=await $s("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ms),a=gs(n);return ys(a)}function xa(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function bs(t="compact"){return Ut(`/api/v1/dashboard?mode=${t}`)}function xs(){return Ut("/api/v1/board")}function ks(t){return Ut(`/api/v1/board/${t}`)}function ka(t,e){return Bt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:hs()})}function ws(t,e,n){return Bt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function z(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function W(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ss(t,e=!1){return typeof t=="boolean"?t:e}function Sn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(z(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Cs(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function R(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}function Ts(t,e){if(t!=="dice.rolled")return;const n=W(e.raw_d20,0),a=W(e.total,0),s=W(e.bonus,0),i=h(e.action,"roll"),r=W(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function As(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ns(t,e,n){const a=e||h(n.actor_id,"");switch(t){case"turn.action.proposed":{const s=h(n.proposed_action,h(n.reply,""));return s?`${a||"actor"}: ${s}`:"Action proposed"}case"turn.action.resolved":{const s=h(n.reply,h(n.result,""));return s?`Resolved: ${s}`:"Action resolved"}case"narration.posted":return h(n.reply,h(n.content,h(n.text,"Narration")));case"dice.rolled":{const s=h(n.action,"roll"),i=W(n.total,0),r=W(n.dc,0),l=h(n.label,""),d=a||"actor",u=r>0?` vs DC ${r}`:"",_=l?` (${l})`:"";return`${d} ${s}: ${i}${u}${_}`}case"turn.started":return`Turn ${W(n.turn,1)} started`;case"phase.changed":return`Phase: ${h(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(n.name,a||"unknown")}`;case"actor.claimed":return`${h(n.keeper,"keeper")} claimed ${a||"actor"}`;case"actor.released":return`${h(n.keeper,"keeper")} released ${a||"actor"}`;case"combat.attack":return h(n.summary,h(n.result,"Attack resolved"));case"combat.defense":return h(n.summary,h(n.result,"Defense resolved"));case"session.outcome":return h(n.summary,h(n.outcome,"Session ended"));default:{const s=As(n);return s?`${t}: ${s}`:t}}}function Ds(t){const e=z(t)?t:{},n=h(e.type,"event"),a=typeof e.actor_id=="string"?e.actor_id:"",s=z(e.payload)?e.payload:{};return{type:n,actor:a||h(s.actor_id,""),content:Ns(n,a,s),dice_roll:Ts(n,s),timestamp:h(e.ts,new Date().toISOString())}}function Ps(t,e,n){var y,M;const a=h(t.room_id,"")||n||"default",s=z(t.state)?t.state:{},i=z(s.party)?s.party:{},r=z(s.actor_control)?s.actor_control:{},l=Object.entries(i).map(([E,B])=>{const b=z(B)?B:{},X=R(b,"max_hp",void 0,10),Q=R(b,"hp",void 0,X),Y=R(b,"max_mp",void 0,0),mt=R(b,"mp",void 0,0),L=R(b,"level",void 0,1),J=R(b,"xp",void 0,0),Ia=Ss(b.alive,Q>0),rn=r[E],ln=typeof rn=="string"?rn:void 0,ja=Cs(b.role,E,ln);return{id:E,name:h(b.name,E),role:ja,keeper:ln,archetype:h(b.archetype,""),persona:h(b.persona,""),traits:Sn(b.traits),skills:Sn(b.skills),status:Ia?"active":"dead",stats:{hp:Q,max_hp:X,mp:mt,max_mp:Y,level:L,xp:J,strength:R(b,"strength","str",10),dexterity:R(b,"dexterity","dex",10),constitution:R(b,"constitution","con",10),intelligence:R(b,"intelligence","int",10),wisdom:R(b,"wisdom","wis",10),charisma:R(b,"charisma","cha",10)}}}),d=e.map(Ds),u=W(s.turn,1),_=h(s.phase,"round"),c=h(s.map,""),p=z(s.world)?s.world:{},v=c||h(p.ascii_map,h(p.map,"")),S=d.filter((E,B)=>{const b=e[B];if(!z(b))return!1;const X=z(b.payload)?b.payload:{};return W(X.turn,-1)===u}),D=(S.length>0?S:d).slice(-12),T=h(s.status,"active");return{session:{id:a,room:a,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:u,actors:l,created_at:((y=d[0])==null?void 0:y.timestamp)??new Date().toISOString()},current_round:{round_number:u,phase:_,events:D,timestamp:((M=d[d.length-1])==null?void 0:M.timestamp)??new Date().toISOString()},map:v||void 0,party:l,story_log:d,history:[]}}async function Es(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Ut(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ls(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Ut(`/api/v1/trpg/state${e}`),Es(t)]);return Ps(n,a,t)}function Rs(t){return Bt("/api/v1/trpg/rounds/run",{room_id:t})}function Ms(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Is(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Bt("/api/v1/trpg/dice/roll",e)}function js(t,e){const n=Ms();return Bt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function wa(t,e){await H("masc_broadcast",{agent_name:t,message:e})}async function Fs(t,e,n=1){await H("masc_add_task",{title:t,description:e,priority:n})}async function Hs(t){return H("masc_join",{agent_name:t})}async function Sa(t){await H("masc_leave",{agent_name:t})}async function Os(t){await H("masc_heartbeat",{agent_name:t})}async function zs(t=40){return(await H("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Us(t,e=20){return H("masc_task_history",{task_id:t,limit:e})}async function Bs(){const t=await H("masc_debates",{});return xa(t)}async function Ks(){const t=await H("masc_sessions",{});return xa(t)}async function Ws(t){const e=await H("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Vs(t){return H("masc_debate_status",{debate_id:t})}const vt=f([]),Kt=f([]),Ca=f([]),ft=f([]),en=f(null),$t=f(null),Fe=f(new Map),Ta=f([]),Cn=f("hot"),Aa=f(null),bt=f(""),He=f(!1),Oe=f(!1),ze=f(!1),Gs=ct(()=>vt.value.filter(t=>t.status==="active"||t.status==="idle")),Na=ct(()=>{const t=Kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Js(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const qs=ct(()=>{const t=new Map;for(const e of ft.value)t.set(e.name,Js(e));return t}),Xs=12e4,Qs=ct(()=>{const t=Date.now(),e=new Set,n=Fe.value;for(const a of ft.value){const s=n.get(a.name);s!=null&&t-s>Xs&&e.add(a.name)}return e}),ie={},Ys=5e3;function Ue(){delete ie.compact,delete ie.full}function j(t){return typeof t=="object"&&t!==null}function m(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function xt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Da(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Zs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function ti(t){if(!j(t))return null;const e=m(t.name);return e?{name:e,status:Da(t.status),current_task:m(t.current_task)??null,last_seen:m(t.last_seen),emoji:m(t.emoji),koreanName:m(t.koreanName)??m(t.korean_name),model:m(t.model),traits:xt(t.traits),interests:xt(t.interests),activityLevel:$(t.activityLevel)??$(t.activity_level),primaryValue:m(t.primaryValue)??m(t.primary_value)}:null}function ei(t){if(!j(t))return null;const e=m(t.id),n=m(t.title);return!e||!n?null:{id:e,title:n,status:Zs(t.status),priority:$(t.priority),assignee:m(t.assignee),description:m(t.description),created_at:m(t.created_at),updated_at:m(t.updated_at)}}function ni(t){if(!j(t))return null;const e=m(t.from)??m(t.from_agent)??"system",n=m(t.content)??"",a=m(t.timestamp)??new Date().toISOString();return{id:m(t.id),seq:$(t.seq),from:e,content:n,timestamp:a,type:m(t.type)}}function ai(t){return Array.isArray(t)?t.map(e=>{if(!j(e))return null;const n=$(e.ts_unix);if(n==null)return null;const a=j(e.handoff)?e.handoff:null;return{ts:n,context_ratio:$(e.context_ratio)??0,context_tokens:$(e.context_tokens)??0,context_max:$(e.context_max)??0,latency_ms:$(e.latency_ms)??0,generation:$(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:$(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:$(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?$(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function si(t){return(Array.isArray(t)?t:j(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!j(n))return null;const a=j(n.agent)?n.agent:null,s=j(n.context)?n.context:null,i=j(n.metrics_window)?n.metrics_window:void 0,r=m(n.name);if(!r)return null;const l=$(n.context_ratio)??$(s==null?void 0:s.context_ratio),d=m(n.status)??m(a==null?void 0:a.status)??"offline",u=Da(d),_=m(n.model)??m(n.active_model)??m(n.primary_model),c=xt(n.skill_secondary),p=s?{source:m(s.source),context_ratio:$(s.context_ratio),context_tokens:$(s.context_tokens),context_max:$(s.context_max),message_count:$(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,v=a?{name:m(a.name),status:m(a.status),current_task:m(a.current_task)??null,last_seen:m(a.last_seen)}:void 0,S=ai(n.metrics_series);return{name:r,emoji:m(n.emoji),koreanName:m(n.koreanName)??m(n.korean_name),agent_name:m(n.agent_name),trace_id:m(n.trace_id),model:_,primary_model:m(n.primary_model),active_model:m(n.active_model),next_model_hint:m(n.next_model_hint)??null,status:u,last_heartbeat:m(n.last_heartbeat)??m(a==null?void 0:a.last_seen),generation:$(n.generation),turn_count:$(n.turn_count)??$(n.total_turns),context_ratio:l,context_tokens:$(n.context_tokens)??$(s==null?void 0:s.context_tokens),context_max:$(n.context_max)??$(s==null?void 0:s.context_max),context_source:m(n.context_source)??m(s==null?void 0:s.source),context:p,traits:xt(n.traits),interests:xt(n.interests),primaryValue:m(n.primaryValue)??m(n.primary_value),activityLevel:$(n.activityLevel)??$(n.activity_level),memory_recent_note:m(n.memory_recent_note)??null,conversation_tail_count:$(n.conversation_tail_count),k2k_count:$(n.k2k_count),handoff_count_total:$(n.handoff_count_total)??$(n.trace_history_count),compaction_count:$(n.compaction_count),last_compaction_saved_tokens:$(n.last_compaction_saved_tokens),skill_primary:m(n.skill_primary)??null,skill_secondary:c,skill_reason:m(n.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function he(t="full"){var a,s,i;const e=Date.now(),n=ie[t];if(!(n&&e-n.time<Ys)){He.value=!0;try{const r=await bs(t);ie[t]={data:r,time:e},vt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(ti).filter(l=>l!==null),Kt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(ei).filter(l=>l!==null),Ca.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(ni).filter(l=>l!==null),ft.value=si(r.keepers),en.value=j(r.status)?r.status:null,$t.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{He.value=!1}}}async function nt(){Oe.value=!0;try{const t=await xs();Ta.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Oe.value=!1}}async function ot(){var t;ze.value=!0;try{const e=bt.value||((t=en.value)==null?void 0:t.room)||"default";bt.value||(bt.value=e);const n=await Ls(e);Aa.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ze.value=!1}}let ye=null,be=null;function ii(){return _a.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Fe.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Fe.value=n}Ue(),ye||(ye=setTimeout(()=>{he(),ye=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(be||(be=setTimeout(()=>{nt(),be=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ue()}})}let kt=null;function oi(){kt||(kt=setInterval(()=>{Ue(),he()},1e4))}function ri(){kt&&(clearInterval(kt),kt=null)}function x({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function V({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function li(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function G({timestamp:t}){const e=li(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const nn=f(null);function Pa(t){nn.value=t}function Tn(){nn.value=null}function Qt(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function ci({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Qt(t.context_tokens)}</div>
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
        <div class="kpi-value">${a}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function ui({keeper:t}){var _,c;const e=t.metrics_series??[];if(e.length<2){const p=(((_=t.context)==null?void 0:_.context_ratio)??0)*100,v=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((p,v)=>{const S=s+v/(i-1)*(n-2*s),D=a-s-(p.context_ratio??0)*(a-2*s);return{x:S,y:D,p}}),l=r.map(({x:p,y:v})=>`${p.toFixed(1)},${v.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${s}" x2="${p.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:v})=>o`
          <circle cx="${p.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const xe=f("");function di({keeper:t}){var s,i,r,l;const e=xe.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${xe.value}
        onInput=${d=>{xe.value=d.target.value}}
      />
      ${a.map(d=>o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Qt(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Qt(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Qt(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function pi({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${a.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${a.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function vi({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function fi({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function An({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ke(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function _i({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ke(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ke(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ke(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function mi(){var e,n,a;const t=nn.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Tn()}}
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
            <${V} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Tn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${ci} keeper=${t} />

        ${""}
        <${ui} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${x} title="Field Dictionary">
            <${di} keeper=${t} />
          <//>

          ${""}
          <${x} title="Profile">
            <${An} traits=${t.traits??[]} label="Traits" />
            <${An} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${G} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${x} title="TRPG Stats">
                <${pi} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${x} title="Equipment (${t.inventory.length})">
                <${vi} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${x} title="Relationships (${Object.keys(t.relationships).length})">
                <${fi} rels=${t.relationships} />
              <//>
            `:null}

          <${x} title="Runtime Signals">
            <${_i} keeper=${t} />
          <//>

          <${x} title="Memory & Context">
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
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
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
      </div>
    </div>
  `:null}let hi=0;const tt=f([]);function w(t,e="success",n=4e3){const a=++hi;tt.value=[...tt.value,{id:a,message:t,type:e}],setTimeout(()=>{tt.value=tt.value.filter(s=>s.id!==a)},n)}function $i(t){tt.value=tt.value.filter(e=>e.id!==t)}function gi(){const t=tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>$i(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const yi="masc_dashboard_agent_name",_t=f(null),oe=f(!1),Ft=f(""),re=f([]),Ht=f([]),rt=f(""),wt=f(!1);function Ea(t){_t.value=t,an()}function Nn(){_t.value=null,Ft.value="",re.value=[],Ht.value=[],rt.value=""}function bi(){const t=_t.value;return t?vt.value.find(e=>e.name===t)??null:null}function La(t){return t?Kt.value.filter(e=>e.assignee===t):[]}async function an(){const t=_t.value;if(t){oe.value=!0,Ft.value="",re.value=[],Ht.value=[];try{const e=await zs(80);re.value=e.filter(s=>s.includes(t)).slice(0,20);const n=La(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Us(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Ht.value=a}catch(e){Ft.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{oe.value=!1}}}async function Dn(){var a;const t=_t.value,e=rt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(yi))==null?void 0:a.trim())||"dashboard";wt.value=!0;try{await wa(n,`@${t} ${e}`),rt.value="",w(`Mention sent to ${t}`,"success"),an()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";w(i,"error")}finally{wt.value=!1}}function xi({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${V} status=${t.status} />
    </div>
  `}function ki({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function wi(){var s,i,r,l;const t=_t.value;if(!t)return null;const e=bi(),n=La(t),a=re.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Nn()}}
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
                        <${V} status=${e.status} />
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
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?o`
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
                    ${e.last_seen?o`<span>Last seen: <${G} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{an()}} disabled=${oe.value}>
              ${oe.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Nn}>Close</button>
          </div>
        </div>

        ${Ft.value?o`<div class="council-error">${Ft.value}</div>`:null}

        <div class="agent-detail-grid">
          <${x} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${xi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${x} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${x} title="Task History">
          ${Ht.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Ht.value.map(d=>o`<${ki} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${x} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${rt.value}
              onInput=${d=>{rt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Dn()}}
              disabled=${wt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Dn()}}
              disabled=${wt.value||rt.value.trim()===""}
            >
              ${wt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function at({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Si({agent:t}){return o`
    <div class="agent" onClick=${()=>Ea(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${V} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Ci(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ti(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Pn(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Ai({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,a=qs.value.get(t.name),s=Qs.value.has(t.name);return o`
    <div class="live-agent keeper-card ${s?"stale":""}" onClick=${()=>Pa(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${V} status=${t.status} />
          ${a?o`<span class="pill pill-lifecycle pill-lifecycle-${a}">${a}</span>`:null}
          ${s?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${Pn(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Pn(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Ci(t.context_tokens)})`:null}
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
            <${G} timestamp=${t.last_heartbeat} />
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
          <div class="keeper-note-preview">${Ti(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function En(){const t=en.value,e=vt.value,n=ft.value,a=Na.value;return o`
    <div class="stats-grid">
      <${at} label="Agents" value=${e.length} />
      <${at} label="Active" value=${Gs.value.length} color="#4ade80" />
      <${at} label="Keepers" value=${n.length} color="#22d3ee" />
      <${at} label="Tasks" value=${Kt.value.length} />
      <${at} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${at} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${x} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${Si} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${x} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${Ai} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${$t.value?o`
        <${x} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${$t.value.running?"Running":"Stopped"}</span>
            ${$t.value.goal?o`<span>Goal: ${$t.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${x} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Ni(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Ni(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const Be=f([]),Ke=f([]),St=f(""),le=f(!1),Ct=f(!1),ce=f(""),ue=f(null),Tt=f(""),We=f(!1);async function Ve(){le.value=!0,ce.value="";try{const[t,e]=await Promise.all([Bs(),Ks()]);Be.value=t,Ke.value=e}catch(t){ce.value=t instanceof Error?t.message:"Failed to load council data"}finally{le.value=!1}}async function Ln(){const t=St.value.trim();if(t){Ct.value=!0;try{const e=await Ws(t);St.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ve()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{Ct.value=!1}}}async function Di(t){ue.value=t,We.value=!0,Tt.value="";try{Tt.value=await Vs(t)}catch(e){Tt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{We.value=!1}}function Pi({debate:t}){const e=ue.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Di(t.id)}
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
  `}function Ei({session:t}){return o`
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
  `}function Li(){return te(()=>{Ve()},[]),o`
    <div>
      <${x} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${St.value}
            onInput=${t=>{St.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Ln()}}
            disabled=${Ct.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ln}
            disabled=${Ct.value||St.value.trim()===""}
          >
            ${Ct.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ve} disabled=${le.value}>
            ${le.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${ce.value?o`<div class="council-error">${ce.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${x} title="Debates" class="section">
          <div class="council-list">
            ${Be.value.length===0?o`<div class="empty-state">No debates yet</div>`:Be.value.map(t=>o`<${Pi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${x} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Ke.value.length===0?o`<div class="empty-state">No active sessions</div>`:Ke.value.map(t=>o`<${Ei} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${x} title=${ue.value?`Debate Detail (${ue.value})`:"Debate Detail"} class="section">
        ${We.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?o`<pre class="council-detail">${Tt.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Ri({text:t}){if(!t)return null;const e=Mi(t);return o`<div class="markdown-content">${e}</div>`}function Mi(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],l=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],l=s.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const u=e[a].replace("</think>","").trim();u&&r.push(u),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${we(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${we(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${we(i.join(`
`))}</p>`)}return n}function we(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Ii=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],At=f([]),Nt=f(!1),Dt=f(""),ji=f("dashboard-user"),Pt=f(!1);async function Ra(t){Nt.value=!0,At.value=[];try{const e=await ks(t);At.value=e.comments??[]}catch{}finally{Nt.value=!1}}async function Rn(t){const e=Dt.value.trim();if(e){Pt.value=!0;try{await ws(t,ji.value,e),Dt.value="",w("Comment posted","success"),await Ra(t),nt()}catch{w("Failed to post comment","error")}finally{Pt.value=!1}}}function Fi(){const t=Cn.value;return o`
    <div class="board-controls">
      ${Ii.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Cn.value=e.id,nt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Ma({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Hi({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await ka(t.id,n),nt()}catch{w("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>ss(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ma} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${G} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Oi({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${G} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function zi({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Dt.value}
        onInput=${e=>{Dt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Rn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Pt.value}
      />
      <button
        onClick=${()=>Rn(t)}
        disabled=${Pt.value||Dt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Pt.value?"...":"Post"}
      </button>
    </div>
  `}function Ui({post:t}){At.value.length===0&&!Nt.value&&Ra(t.id);const e=async n=>{try{await ka(t.id,n),nt()}catch{w("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>me("board")}>← Back to Board</button>
      <${x} title=${o`${t.title} <${Ma} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Ri} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${G} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${x} title="Comments (${Nt.value?"...":At.value.length})">
        ${Nt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Oi} comments=${At.value} />`}
        <${zi} postId=${t.id} />
      <//>
    </div>
  `}function Bi(){const t=Ta.value,e=Oe.value,n=U.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${Ui} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>me("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${Fi} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${Hi} key=${a.id} post=${a} />`)}
          </div>`}
  `}function Ki(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Wi(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Mn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Vi({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${G} timestamp=${t.timestamp} /></span>
    </div>
  `}function Gi(){const t=Ca.value.map(Ki),e=se.value.map(Wi),n=[...t,...e].sort((a,s)=>Mn(s.timestamp)-Mn(a.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(a=>o`<${Vi} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function Ji({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Ea(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${V} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function qi({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>Pa(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${V} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?o`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?o`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?o`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?o`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function Xi(){const t=vt.value,e=ft.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${qi} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Ji} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Se({task:t}){return o`
    <div class="task-row">
      <${V} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${G} timestamp=${t.created_at} />`:null}
    </div>
  `}function Qi(){const{todo:t,inProgress:e,done:n}=Na.value;return o`
    <div class="grid-2col">
      <${x} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${Se} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${x} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${Se} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${x} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${Se} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function Yi({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Zi(){const t=se.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Yi} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const ht=f(""),Ce=f("ability_check"),Te=f("10"),Ae=f("12"),Gt=f(""),Jt=f("idle");function to(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function eo(t,e){return e>0?Math.round(t/e*100):0}const no={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},ao={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ne(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function so(t){const e=t.trim().toLowerCase();return no[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function io(t){const e=t.trim().toLowerCase();return ao[e]??"상황에 따라 선택되는 전술 액션입니다."}function oo({hp:t,max:e}){const n=eo(t,e),a=to(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function ro({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function lo({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function co({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),a=t.traits??[],s=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${V} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${lo} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${oo} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${ro} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ne(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${a.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${a.map(l=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ne(l)}</span>
                  <span class="trpg-annot-desc">${so(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${s.map(l=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ne(l)}</span>
                  <span class="trpg-annot-desc">${io(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function uo({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function po({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var a;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(a=e.dice_roll.rolls)==null?void 0:a.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${G} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function vo({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function fo({state:t}){var d;const e=bt.value||((d=t.session)==null?void 0:d.room)||"",n=Jt.value,a=t.party??[];if(!a.find(u=>u.id===ht.value)&&a.length>0){const u=a[0];u&&(ht.value=u.id)}const i=async()=>{if(!e){w("No room set","error");return}Jt.value="running";try{await Rs(e),Jt.value="ok",w("Round executed","success"),ot()}catch{Jt.value="error",w("Round failed","error")}},r=async()=>{if(e)try{await js(e),w("Turn advanced","success"),ot()}catch{w("Advance failed","error")}},l=async()=>{if(!e)return;const u=ht.value.trim();if(!u){w("Select actor first","warning");return}const _=Number.parseInt(Te.value,10),c=Number.parseInt(Ae.value,10);if(Number.isNaN(_)||Number.isNaN(c)){w("Stat/DC must be numbers","warning");return}const p=Number.parseInt(Gt.value,10),v=Gt.value.trim()===""||Number.isNaN(p)?void 0:p;try{await Is({roomId:e,actorId:u,action:Ce.value.trim()||"ability_check",statValue:_,dc:c,rawD20:v}),w("Dice rolled","success"),ot()}catch{w("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${u=>{bt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ht.value}
            onChange=${u=>{ht.value=u.target.value}}
          >
            <option value="">Select actor</option>
            ${a.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${Ce.value}
              onInput=${u=>{Ce.value=u.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${Te.value}
              onInput=${u=>{Te.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${Ae.value}
              onInput=${u=>{Ae.value=u.target.value}}
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
              onClick=${i}
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

      ${n!=="idle"?o`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function _o({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function mo(){var s,i;const t=Aa.value;if(ze.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ot()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[];return o`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((s=t.session)==null?void 0:s.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((i=t.current_round)==null?void 0:i.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      ${""}
      <${_o} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${x} title="Story Log (${a.length})">
            <${po} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${x} title="Map" style="margin-top:16px;">
                <${uo} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${x} title="Controls">
            <${fo} state=${t} />
          <//>

          ${""}
          <${x} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${co} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${x} title="History (${t.history.length})" style="margin-top:16px;">
                <${vo} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const sn="masc_dashboard_agent_name";function ho(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(sn);return e??n??"dashboard"}const F=f(ho()),Et=f(""),Lt=f(""),de=f(""),Rt=f(!1),st=f(!1),Mt=f(!1),It=f(!1),pe=f(!1),$e=f(!1);function on(t){const e=t.trim();F.value=e,e&&localStorage.setItem(sn,e)}function $o(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ge(){const t=F.value.trim();if(t){Mt.value=!0;try{const e=await Hs(t),n=$o(e);n&&on(n),$e.value=!0,w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{Mt.value=!1}}}async function go(){const t=F.value.trim();if(t){It.value=!0;try{await Sa(t),$e.value=!1,w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{It.value=!1}}}async function yo(){const t=F.value.trim();if(t)try{await Sa(t)}catch{}localStorage.removeItem(sn),on("dashboard"),$e.value=!1,await Ge()}async function bo(){const t=F.value.trim();if(t){pe.value=!0;try{await Os(t),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{pe.value=!1}}}async function In(){const t=F.value.trim(),e=Et.value.trim();if(!(!t||!e)){Rt.value=!0;try{await wa(t,e),Et.value="",w("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";w(a,"error")}finally{Rt.value=!1}}}async function xo(){const t=Lt.value.trim(),e=de.value.trim()||"Created from dashboard";if(t){st.value=!0;try{await Fs(t,e,1),Lt.value="",de.value="",w("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";w(a,"error")}finally{st.value=!1}}}function ko(){return te(()=>{Ge()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${F.value}
        onInput=${t=>on(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Et.value}
          onInput=${t=>{Et.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&In()}}
          disabled=${Rt.value}
        />
        <button
          class="control-btn"
          onClick=${In}
          disabled=${Rt.value||Et.value.trim()===""||F.value.trim()===""}
        >
          ${Rt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ge()}}
          disabled=${Mt.value||F.value.trim()===""}
        >
          ${Mt.value?"Joining...":$e.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{go()}}
          disabled=${It.value||F.value.trim()===""}
        >
          ${It.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{yo()}}
          disabled=${Mt.value||It.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{bo()}}
          disabled=${pe.value||F.value.trim()===""}
        >
          ${pe.value?"Pinging...":"Heartbeat"}
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
        disabled=${st.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${de.value}
        onInput=${t=>{de.value=t.target.value}}
        disabled=${st.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${xo}
        disabled=${st.value||Lt.value.trim()===""}
      >
        ${st.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function wo(){const t=ut.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Ze.value} events</span>
    </div>
  `}const So=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Co(){const t=U.value.tab,e=ut.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${So.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>me(n.id)}
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
            <strong>${vt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${ft.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${Kt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Ze.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{he(),t==="board"&&nt(),t==="trpg"&&ot()}}
        >
          Refresh Now
        </button>
      </section>

      <${ko} />
    </aside>
  `}function To(){switch(U.value.tab){case"overview":return o`<${En} />`;case"council":return o`<${Li} />`;case"board":return o`<${Bi} />`;case"activity":return o`<${Gi} />`;case"agents":return o`<${Xi} />`;case"tasks":return o`<${Qi} />`;case"journal":return o`<${Zi} />`;case"trpg":return o`<${mo} />`;default:return o`<${En} />`}}function Ao(){return te(()=>{is(),ha(),he();const t=ii();return oi(),()=>{fs(),t(),ri()}},[]),te(()=>{const t=U.value.tab;t==="board"&&nt(),t==="trpg"&&ot()},[U.value.tab]),o`
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
          <${wo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${rs} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${He.value&&!ut.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${To} />`}
        </main>
        <${Co} />
      </div>

      <${mi} />
      <${wi} />
      <${gi} />
    </div>
  `}const jn=document.getElementById("app");jn&&Ba(o`<${Ao} />`,jn);
