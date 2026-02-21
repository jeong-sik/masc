(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&a(l)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var ve,x,Mn,In,Z,ln,jn,Fn,On,Ge,Ne,De,jt={},Hn=[],Ma=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,fe=Array.isArray;function K(t,e){for(var n in e)t[n]=e[n];return t}function Je(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function zn(t,e,n){var a,s,i,l={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:l[i]=e[i];if(arguments.length>2&&(l.children=arguments.length>3?ve.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)l[i]===void 0&&(l[i]=t.defaultProps[i]);return qt(t,l,a,s,null)}function qt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Mn,__i:-1,__u:0};return s==null&&x.vnode!=null&&x.vnode(i),i}function Ht(t){return t.children}function gt(t,e){this.props=t,this.context=e}function rt(t,e){if(e==null)return t.__?rt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?rt(t):null}function Un(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Un(t)}}function rn(t){(!t.__d&&(t.__d=!0)&&Z.push(t)&&!Yt.__r++||ln!=x.debounceRendering)&&((ln=x.debounceRendering)||jn)(Yt)}function Yt(){for(var t,e,n,a,s,i,l,r=1;Z.length;)Z.length>r&&Z.sort(Fn),t=Z.shift(),r=Z.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],l=[],e.__P&&((n=K({},a)).__v=a.__v+1,x.vnode&&x.vnode(n),qe(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??rt(a),!!(32&a.__u),l),n.__v=a.__v,n.__.__k[n.__i]=n,Vn(i,n,l),a.__e=a.__=null,n.__e!=s&&Un(n)));Yt.__r=0}function Bn(t,e,n,a,s,i,l,r,d,u,_){var c,p,v,w,D,T,S,y=a&&a.__k||Hn,M=e.length;for(d=Ia(n,e,y,d,M),c=0;c<M;c++)(v=n.__k[c])!=null&&(p=v.__i==-1?jt:y[v.__i]||jt,v.__i=c,T=qe(t,v,p,s,i,l,r,d,u,_),w=v.__e,v.ref&&p.ref!=v.ref&&(p.ref&&Xe(p.ref,null,v),_.push(v.ref,v.__c||w,v)),D==null&&w!=null&&(D=w),(S=!!(4&v.__u))||p.__k===v.__k?d=Kn(v,d,t,S):typeof v.type=="function"&&T!==void 0?d=T:w&&(d=w.nextSibling),v.__u&=-7);return n.__e=D,d}function Ia(t,e,n,a,s){var i,l,r,d,u,_=n.length,c=_,p=0;for(t.__k=new Array(s),i=0;i<s;i++)(l=e[i])!=null&&typeof l!="boolean"&&typeof l!="function"?(typeof l=="string"||typeof l=="number"||typeof l=="bigint"||l.constructor==String?l=t.__k[i]=qt(null,l,null,null,null):fe(l)?l=t.__k[i]=qt(Ht,{children:l},null,null,null):l.constructor===void 0&&l.__b>0?l=t.__k[i]=qt(l.type,l.props,l.key,l.ref?l.ref:null,l.__v):t.__k[i]=l,d=i+p,l.__=t,l.__b=t.__b+1,r=null,(u=l.__i=ja(l,n,d,c))!=-1&&(c--,(r=n[u])&&(r.__u|=2)),r==null||r.__v==null?(u==-1&&(s>_?p--:s<_&&p++),typeof l.type!="function"&&(l.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,l.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<_;i++)(r=n[i])!=null&&(2&r.__u)==0&&(r.__e==a&&(a=rt(r)),Gn(r,r));return a}function Kn(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Kn(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=rt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function ja(t,e,n,a){var s,i,l,r=t.key,d=t.type,u=e[n],_=u!=null&&(2&u.__u)==0;if(u===null&&r==null||_&&r==u.key&&d==u.type)return n;if(a>(_?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((u=e[l=s>=0?s--:i++])!=null&&(2&u.__u)==0&&r==u.key&&d==u.type)return l}return-1}function cn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Ma.test(e)?n:n+"px"}function Vt(t,e,n,a,s){var i,l;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||cn(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||cn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(On,"$1")),l=e.toLowerCase(),e=l in t||e=="onFocusOut"||e=="onFocusIn"?l.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Ge,t.addEventListener(e,i?De:Ne,i)):t.removeEventListener(e,i?De:Ne,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function un(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ge++;else if(e.t<n.u)return;return n(x.event?x.event(e):e)}}}function qe(t,e,n,a,s,i,l,r,d,u){var _,c,p,v,w,D,T,S,y,M,E,U,C,X,Q,Y,mt,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[r=e.__e=n.__e]),(_=x.__b)&&_(e);t:if(typeof R=="function")try{if(S=e.props,y="prototype"in R&&R.prototype.render,M=(_=R.contextType)&&a[_.__c],E=_?M?M.props.value:_.__:a,n.__c?T=(c=e.__c=n.__c).__=c.__E:(y?e.__c=c=new R(S,E):(e.__c=c=new gt(S,E),c.constructor=R,c.render=Oa),M&&M.sub(c),c.state||(c.state={}),c.__n=a,p=c.__d=!0,c.__h=[],c._sb=[]),y&&c.__s==null&&(c.__s=c.state),y&&R.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=K({},c.__s)),K(c.__s,R.getDerivedStateFromProps(S,c.__s))),v=c.props,w=c.state,c.__v=e,p)y&&R.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),y&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(y&&R.getDerivedStateFromProps==null&&S!==v&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(S,E),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(S,c.__s,E)===!1){for(e.__v!=n.__v&&(c.props=S,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(J){J&&(J.__=e)}),U=0;U<c._sb.length;U++)c.__h.push(c._sb[U]);c._sb=[],c.__h.length&&l.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(S,c.__s,E),y&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(v,w,D)})}if(c.context=E,c.props=S,c.__P=t,c.__e=!1,C=x.__r,X=0,y){for(c.state=c.__s,c.__d=!1,C&&C(e),_=c.render(c.props,c.state,c.context),Q=0;Q<c._sb.length;Q++)c.__h.push(c._sb[Q]);c._sb=[]}else do c.__d=!1,C&&C(e),_=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++X<25);c.state=c.__s,c.getChildContext!=null&&(a=K(K({},a),c.getChildContext())),y&&!p&&c.getSnapshotBeforeUpdate!=null&&(D=c.getSnapshotBeforeUpdate(v,w)),Y=_,_!=null&&_.type===Ht&&_.key==null&&(Y=Wn(_.props.children)),r=Bn(t,fe(Y)?Y:[Y],e,n,a,s,i,l,r,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&l.push(c),T&&(c.__E=c.__=null)}catch(J){if(e.__v=null,d||i!=null)if(J.then){for(e.__u|=d?160:128;r&&r.nodeType==8&&r.nextSibling;)r=r.nextSibling;i[i.indexOf(r)]=null,e.__e=r}else{for(mt=i.length;mt--;)Je(i[mt]);Pe(e)}else e.__e=n.__e,e.__k=n.__k,J.then||Pe(e);x.__e(J,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):r=e.__e=Fa(n.__e,e,n,a,s,i,l,d,u);return(_=x.diffed)&&_(e),128&e.__u?void 0:r}function Pe(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Pe)}function Vn(t,e,n){for(var a=0;a<n.length;a++)Xe(n[a],n[++a],n[++a]);x.__c&&x.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){x.__e(i,s.__v)}})}function Wn(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:fe(t)?t.map(Wn):K({},t)}function Fa(t,e,n,a,s,i,l,r,d){var u,_,c,p,v,w,D,T=n.props||jt,S=e.props,y=e.type;if(y=="svg"?s="http://www.w3.org/2000/svg":y=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((v=i[u])&&"setAttribute"in v==!!y&&(y?v.localName==y:v.nodeType==3)){t=v,i[u]=null;break}}if(t==null){if(y==null)return document.createTextNode(S);t=document.createElementNS(s,y,S.is&&S),r&&(x.__m&&x.__m(e,i),r=!1),i=null}if(y==null)T===S||r&&t.data==S||(t.data=S);else{if(i=i&&ve.call(t.childNodes),!r&&i!=null)for(T={},u=0;u<t.attributes.length;u++)T[(v=t.attributes[u]).name]=v.value;for(u in T)if(v=T[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=v;else if(!(u in S)){if(u=="value"&&"defaultValue"in S||u=="checked"&&"defaultChecked"in S)continue;Vt(t,u,null,v,s)}}for(u in S)v=S[u],u=="children"?p=v:u=="dangerouslySetInnerHTML"?_=v:u=="value"?w=v:u=="checked"?D=v:r&&typeof v!="function"||T[u]===v||Vt(t,u,v,T[u],s);if(_)r||c&&(_.__html==c.__html||_.__html==t.innerHTML)||(t.innerHTML=_.__html),e.__k=[];else if(c&&(t.innerHTML=""),Bn(e.type=="template"?t.content:t,fe(p)?p:[p],e,n,a,y=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,l,i?i[0]:n.__k&&rt(n,0),r,d),i!=null)for(u=i.length;u--;)Je(i[u]);r||(u="value",y=="progress"&&w==null?t.removeAttribute("value"):w!=null&&(w!==t[u]||y=="progress"&&!w||y=="option"&&w!=T[u])&&Vt(t,u,w,T[u],s),u="checked",D!=null&&D!=t[u]&&Vt(t,u,D,T[u],s))}return t}function Xe(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){x.__e(s,n)}}function Gn(t,e,n){var a,s;if(x.unmount&&x.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Xe(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){x.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Gn(a[s],e,n||typeof t.type!="function");n||Je(t.__e),t.__c=t.__=t.__e=void 0}function Oa(t,e,n){return this.constructor(t,n)}function Ha(t,e,n){var a,s,i,l;e==document&&(e=document.documentElement),x.__&&x.__(t,e),s=(a=!1)?null:e.__k,i=[],l=[],qe(e,t=e.__k=zn(Ht,null,[t]),s||jt,jt,e.namespaceURI,s?null:e.firstChild?ve.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,l),Vn(i,t,l)}ve=Hn.slice,x={__e:function(t,e,n,a){for(var s,i,l;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),l=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),l=s.__d),l)return s.__E=s}catch(r){t=r}throw t}},Mn=0,In=function(t){return t!=null&&t.constructor===void 0},gt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=K({},this.state),typeof t=="function"&&(t=t(K({},n),this.props)),t&&K(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),rn(this))},gt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),rn(this))},gt.prototype.render=Ht,Z=[],jn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Fn=function(t,e){return t.__v.__b-e.__v.__b},Yt.__r=0,On=/(PointerCapture)$|Capture$/i,Ge=0,Ne=un(!1),De=un(!0);var Jn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var l=e[i++],r=e[i]?(e[0]|=l?1:2,n[e[i++]]):e[++i];l===3?a[0]=r:l===4?a[1]=Object.assign(a[1]||{},r):l===5?(a[1]=a[1]||{})[e[++i]]=r:l===6?a[1][e[++i]]+=r+"":l?(s=t.apply(r,Jn(t,r,n,["",null])),a.push(s),r[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(r)}return a},dn=new Map;function za(t){var e=dn.get(this);return e||(e=new Map,dn.set(this,e)),(e=Jn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,l="",r="",d=[0],u=function(p){i===1&&(p||(l=l.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,l):i===3&&(p||l)?(d.push(3,p,l),i=2):i===2&&l==="..."&&p?d.push(4,p,0):i===2&&l&&!p?d.push(5,0,!0,l):i>=5&&((l||!p&&i===5)&&(d.push(i,0,l,s),i=6),p&&(d.push(i,p,0,s),i=6)),l=""},_=0;_<n.length;_++){_&&(i===1&&u(),u(_));for(var c=0;c<n[_].length;c++)a=n[_][c],i===1?a==="<"?(u(),d=[d],i=3):l+=a:i===4?l==="--"&&a===">"?(i=1,l=""):l=a+l[0]:r?a===r?r="":l+=a:a==='"'||a==="'"?r=a:a===">"?(u(),i=1):i&&(a==="="?(i=5,s=l,l=""):a==="/"&&(i<5||n[_][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(u(),i=2):l+=a),i===3&&l==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=za.bind(zn),Zt,P,ge,pn,vn=0,qn=[],A=x,fn=A.__b,_n=A.__r,mn=A.diffed,hn=A.__c,$n=A.unmount,gn=A.__;function Xn(t,e){A.__h&&A.__h(P,t,vn||e),vn=0;var n=P.__H||(P.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function te(t,e){var n=Xn(Zt++,3);!A.__s&&Yn(n.__H,e)&&(n.__=t,n.u=e,P.__H.__h.push(n))}function Qn(t,e){var n=Xn(Zt++,7);return Yn(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ua(){for(var t;t=qn.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Xt),t.__H.__h.forEach(Ee),t.__H.__h=[]}catch(e){t.__H.__h=[],A.__e(e,t.__v)}}A.__b=function(t){P=null,fn&&fn(t)},A.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),gn&&gn(t,e)},A.__r=function(t){_n&&_n(t),Zt=0;var e=(P=t.__c).__H;e&&(ge===P?(e.__h=[],P.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Xt),e.__h.forEach(Ee),e.__h=[],Zt=0)),ge=P},A.diffed=function(t){mn&&mn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(qn.push(e)!==1&&pn===A.requestAnimationFrame||((pn=A.requestAnimationFrame)||Ba)(Ua)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ge=P=null},A.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Xt),n.__h=n.__h.filter(function(a){return!a.__||Ee(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],A.__e(a,n.__v)}}),hn&&hn(t,e)},A.unmount=function(t){$n&&$n(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Xt(a)}catch(s){e=s}}),n.__H=void 0,e&&A.__e(e,n.__v))};var yn=typeof requestAnimationFrame=="function";function Ba(t){var e,n=function(){clearTimeout(a),yn&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);yn&&(e=requestAnimationFrame(n))}function Xt(t){var e=P,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),P=e}function Ee(t){var e=P;t.__c=t.__(),P=e}function Yn(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var Ka=Symbol.for("preact-signals");function _e(){if(q>1)q--;else{for(var t,e=!1;yt!==void 0;){var n=yt;for(yt=void 0,Re++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ea(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Re=0,q--,e)throw t}}function Va(t){if(q>0)return t();q++;try{return t()}finally{_e()}}var g=void 0;function Zn(t){var e=g;g=void 0;try{return t()}finally{g=e}}var yt=void 0,q=0,Re=0,ee=0;function ta(t){if(g!==void 0){var e=t.n;if(e===void 0||e.t!==g)return e={i:0,S:t,p:g.s,n:void 0,t:g,e:void 0,x:void 0,r:e},g.s!==void 0&&(g.s.n=e),g.s=e,t.n=e,32&g.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=g.s,e.n=void 0,g.s.n=e,g.s=e),e}}function N(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}N.prototype.brand=Ka;N.prototype.h=function(){return!0};N.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Zn(function(){var a;(a=e.W)==null||a.call(e)}))};N.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&Zn(function(){var s;(s=e.Z)==null||s.call(e)}))}};N.prototype.subscribe=function(t){var e=this;return zt(function(){var n=e.value,a=g;g=void 0;try{t(n)}finally{g=a}},{name:"sub"})};N.prototype.valueOf=function(){return this.value};N.prototype.toString=function(){return this.value+""};N.prototype.toJSON=function(){return this.value};N.prototype.peek=function(){var t=g;g=void 0;try{return this.value}finally{g=t}};Object.defineProperty(N.prototype,"value",{get:function(){var t=ta(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Re>100)throw new Error("Cycle detected");this.v=t,this.i++,ee++,q++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{_e()}}}});function f(t,e){return new N(t,e)}function ea(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function na(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function aa(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function et(t,e){N.call(this,void 0),this.x=t,this.s=void 0,this.g=ee-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}et.prototype=new N;et.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ee))return!0;if(this.g=ee,this.f|=1,this.i>0&&!ea(this))return this.f&=-2,!0;var t=g;try{na(this),g=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return g=t,aa(this),this.f&=-2,!0};et.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}N.prototype.S.call(this,t)};et.prototype.U=function(t){if(this.t!==void 0&&(N.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};et.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(et.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ta(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ct(t,e){return new et(t,e)}function sa(t){var e=t.u;if(t.u=void 0,typeof e=="function"){q++;var n=g;g=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Qe(t),a}finally{g=n,_e()}}}function Qe(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,sa(t)}function Wa(t){if(g!==this)throw new Error("Out-of-order effect");aa(this),g=t,this.f&=-2,8&this.f&&Qe(this),_e()}function dt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}dt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};dt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,sa(this),na(this),q++;var t=g;return g=this,Wa.bind(this,t)};dt.prototype.N=function(){2&this.f||(this.f|=2,this.o=yt,yt=this)};dt.prototype.d=function(){this.f|=8,1&this.f||Qe(this)};dt.prototype.dispose=function(){this.d()};function zt(t,e){var n=new dt(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var ia,Wt,Ga=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,oa=[];zt(function(){ia=this.N})();function pt(t,e){x[t]=e.bind(null,x[t]||function(){})}function ne(t){if(Wt){var e=Wt;Wt=void 0,e()}Wt=t&&t.S()}function la(t){var e=this,n=t.data,a=qa(n);a.value=n;var s=Qn(function(){for(var r=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=ct(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),_=ct(function(){return!Array.isArray(u.value)&&!In(u.value)}),c=zt(function(){if(this.N=ra,_.value){var v=u.value;r.__v&&r.__v.__e&&r.__v.__e.nodeType===3&&(r.__v.__e.data=v)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[_,u]},[]),i=s[0],l=s[1];return i.value?l.peek():l.value}la.displayName="ReactiveTextNode";Object.defineProperties(N.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:la},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});pt("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof N&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});pt("__r",function(t,e){if(t(e),e.type!==Ht){ne();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var l;return zt(function(){l=this},{name:i}),l.c=s,l})(function(){var s;Ga&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ne(n)}});pt("__e",function(t,e,n,a){ne(),t(e,n,a)});pt("diffed",function(t,e){ne();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var l in i){var r=i[l];r!==void 0&&!(l in a)&&(r.d(),i[l]=void 0)}else i={},n.U=i;for(var d in a){var u=i[d],_=a[d];u===void 0?(u=Ja(n,d,_),i[d]=u):u.o(_,s)}for(var c in a)s[c]=a[c]}}t(e)});function Ja(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=f(n),l=n.peek();return{o:function(r,d){i.value=r,l=r.peek()},d:zt(function(){this.N=ra;var r=i.value.value;l!==r?(l=void 0,s?t[e]=r:r!=null&&(r!==!1||e[4]==="-")?t.setAttribute(e,r):t.removeAttribute(e)):l=void 0})}}pt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var l=e.__c;if(l){var r=l.__$u;r&&(l.__$u=void 0,r.d())}}t(e)});pt("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});gt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var l in t)if(l!=="__source"&&t[l]!==this.props[l])return!0;for(var r in this.props)if(!(r in t))return!0;return!1};function qa(t,e){return Qn(function(){return f(t,e)},[])}var Xa=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Qa(){Va(function(){for(var t;t=oa.shift();)ia.call(t)})}function ra(){oa.push(this)===1&&(x.requestAnimationFrame||Xa)(Qa)}const Ya=["overview","board","activity","agents","tasks","journal","trpg","council"],ca={tab:"overview",params:{},postId:null};function bn(t){return!!t&&Ya.includes(t)}function Le(t){try{return decodeURIComponent(t)}catch{return t}}function Me(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Za(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ua(t,e){const n=t[0],a=e.tab,s=bn(n)?n:bn(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Le(t[2]):t[0]==="post"&&t[1]&&(i=Le(t[1]))),{tab:s,params:e,postId:i}}function ae(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ca;const n=Le(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const r=n.indexOf("?");r>=0&&(a=n.slice(0,r),s=n.slice(r+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Me(s),l=Za(a);return ua(l,i)}function ts(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...ca,params:Me(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Me(e.replace(/^\?/,""));return ua(a,s)}function da(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const z=f(ae(window.location.hash));window.addEventListener("hashchange",()=>{z.value=ae(window.location.hash)});function me(t,e){const n={tab:t,params:{},postId:null};window.location.hash=da(n)}function es(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ns(){if(window.location.hash&&window.location.hash!=="#"){z.value=ae(window.location.hash);return}const t=ts(window.location.pathname,window.location.search);if(t){z.value=t;const e=da(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",z.value=ae(window.location.hash)}const as=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function ss(){const t=z.value.tab;return o`
    <div class="main-tab-bar">
      ${as.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>me(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const xn="masc_dashboard_sse_session_id",is=1e3,os=15e3,ut=f(!1),Ye=f(0),pa=f(null),se=f([]);function ls(){let t=sessionStorage.getItem(xn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(xn,t)),t}const rs=200;function I(t,e){const n={agent:t,text:e,timestamp:Date.now()};se.value=[n,...se.value].slice(0,rs)}let H=null,it=null,Ie=0;function va(){it&&(clearTimeout(it),it=null)}function cs(){if(it)return;Ie++;const t=Math.min(Ie,5),e=Math.min(os,is*Math.pow(2,t));it=setTimeout(()=>{it=null,fa()},e)}function fa(){va(),H&&(H.close(),H=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",ls());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);H=i,i.onopen=()=>{H===i&&(Ie=0,ut.value=!0)},i.onerror=()=>{H===i&&(ut.value=!1,i.close(),H=null,cs())},i.onmessage=l=>{try{const r=JSON.parse(l.data);Ye.value++,pa.value=r,us(r)}catch{}}}function us(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":I(n,"Joined");break;case"agent_left":I(n,"Left");break;case"broadcast":I(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":I(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":I(n,"New post");break;case"board_comment":I(n,"New comment");break;case"keeper_heartbeat":I(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":I(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":I(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":I(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:I(n,e)}}function ds(){va(),H&&(H.close(),H=null),ut.value=!1}function _a(){return new URLSearchParams(window.location.search)}function ma(){const t=_a(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function ha(){return{...ma(),"Content-Type":"application/json"}}const ps=15e3,$a=3e4,vs=6e4;async function Ze(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${l} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(s)}}function fs(){var e,n;const t=_a();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Ut(t){const e=await Ze(t,{headers:ma()},ps);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Bt(t,e){const n=await Ze(t,{method:"POST",headers:ha(),body:JSON.stringify(e)},$a);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function _s(t,e,n,a=$a){const s=await Ze(t,{method:"POST",headers:{...ha(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Error(`POST ${t}: ${s.status} ${s.statusText}`);return s.text()}function ms(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function hs(t){var e,n,a,s,i,l,r;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((r=(l=(i=t.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:r.text)??""}async function O(t,e){const n=await _s("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},vs),a=ms(n);return hs(a)}function ga(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function $s(t="compact"){return Ut(`/api/v1/dashboard?mode=${t}`)}function gs(){return Ut("/api/v1/board")}function ys(t){return Ut(`/api/v1/board/${t}`)}function ya(t,e){return Bt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:fs()})}function bs(t,e,n){return Bt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function B(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function V(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function xs(t,e=!1){return typeof t=="boolean"?t:e}function ks(t){return t==="dm"||t==="player"||t==="npc"?t:"npc"}function L(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}function ws(t,e){if(t!=="dice.rolled")return;const n=V(e.raw_d20,0),a=V(e.total,0),s=V(e.bonus,0),i=$(e.action,"roll"),l=V(e.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function Ss(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Cs(t,e,n){const a=e||$(n.actor_id,"");switch(t){case"turn.action.proposed":{const s=$(n.proposed_action,$(n.reply,""));return s?`${a||"actor"}: ${s}`:"Action proposed"}case"turn.action.resolved":{const s=$(n.reply,$(n.result,""));return s?`Resolved: ${s}`:"Action resolved"}case"narration.posted":return $(n.reply,$(n.content,$(n.text,"Narration")));case"dice.rolled":{const s=$(n.action,"roll"),i=V(n.total,0),l=V(n.dc,0),r=$(n.label,""),d=a||"actor",u=l>0?` vs DC ${l}`:"",_=r?` (${r})`:"";return`${d} ${s}: ${i}${u}${_}`}case"turn.started":return`Turn ${V(n.turn,1)} started`;case"phase.changed":return`Phase: ${$(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(n.name,a||"unknown")}`;case"actor.claimed":return`${$(n.keeper,"keeper")} claimed ${a||"actor"}`;case"actor.released":return`${$(n.keeper,"keeper")} released ${a||"actor"}`;case"combat.attack":return $(n.summary,$(n.result,"Attack resolved"));case"combat.defense":return $(n.summary,$(n.result,"Defense resolved"));case"session.outcome":return $(n.summary,$(n.outcome,"Session ended"));default:{const s=Ss(n);return s?`${t}: ${s}`:t}}}function Ts(t){const e=B(t)?t:{},n=$(e.type,"event"),a=typeof e.actor_id=="string"?e.actor_id:"",s=B(e.payload)?e.payload:{};return{type:n,actor:a||$(s.actor_id,""),content:Cs(n,a,s),dice_roll:ws(n,s),timestamp:$(e.ts,new Date().toISOString())}}function As(t,e,n){var y,M;const a=$(t.room_id,"")||n||"default",s=B(t.state)?t.state:{},i=B(s.party)?s.party:{},l=B(s.actor_control)?s.actor_control:{},r=Object.entries(i).map(([E,U])=>{const C=B(U)?U:{},X=L(C,"max_hp",void 0,10),Q=L(C,"hp",void 0,X),Y=L(C,"max_mp",void 0,0),mt=L(C,"mp",void 0,0),R=L(C,"level",void 0,1),J=L(C,"xp",void 0,0),Ra=xs(C.alive,Q>0),on=l[E],La=typeof on=="string"?on:void 0;return{id:E,name:$(C.name,E),role:ks(C.role),keeper:La,status:Ra?"active":"dead",stats:{hp:Q,max_hp:X,mp:mt,max_mp:Y,level:R,xp:J,strength:L(C,"strength","str",10),dexterity:L(C,"dexterity","dex",10),constitution:L(C,"constitution","con",10),intelligence:L(C,"intelligence","int",10),wisdom:L(C,"wisdom","wis",10),charisma:L(C,"charisma","cha",10)}}}),d=e.map(Ts),u=V(s.turn,1),_=$(s.phase,"round"),c=$(s.map,""),p=B(s.world)?s.world:{},v=c||$(p.ascii_map,$(p.map,"")),w=d.filter((E,U)=>{const C=e[U];if(!B(C))return!1;const X=B(C.payload)?C.payload:{};return V(X.turn,-1)===u}),D=(w.length>0?w:d).slice(-12),T=$(s.status,"active");return{session:{id:a,room:a,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:u,actors:r,created_at:((y=d[0])==null?void 0:y.timestamp)??new Date().toISOString()},current_round:{round_number:u,phase:_,events:D,timestamp:((M=d[d.length-1])==null?void 0:M.timestamp)??new Date().toISOString()},map:v||void 0,party:r,story_log:d,history:[]}}async function Ns(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Ut(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ds(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Ut(`/api/v1/trpg/state${e}`),Ns(t)]);return As(n,a,t)}function Ps(t){return Bt("/api/v1/trpg/rounds/run",{room_id:t})}function Es(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Rs(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Bt("/api/v1/trpg/dice/roll",e)}function Ls(t,e){const n=Es();return Bt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function ba(t,e){await O("masc_broadcast",{agent_name:t,message:e})}async function Ms(t,e,n=1){await O("masc_add_task",{title:t,description:e,priority:n})}async function Is(t){return O("masc_join",{agent_name:t})}async function xa(t){await O("masc_leave",{agent_name:t})}async function js(t){await O("masc_heartbeat",{agent_name:t})}async function Fs(t=40){return(await O("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Os(t,e=20){return O("masc_task_history",{task_id:t,limit:e})}async function Hs(){const t=await O("masc_debates",{});return ga(t)}async function zs(){const t=await O("masc_sessions",{});return ga(t)}async function Us(t){const e=await O("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Bs(t){return O("masc_debate_status",{debate_id:t})}const vt=f([]),Kt=f([]),ka=f([]),ft=f([]),tn=f(null),$t=f(null),je=f(new Map),wa=f([]),kn=f("hot"),Sa=f(null),bt=f(""),Fe=f(!1),Oe=f(!1),He=f(!1),Ks=ct(()=>vt.value.filter(t=>t.status==="active"||t.status==="idle")),Ca=ct(()=>{const t=Kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Vs(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Ws=ct(()=>{const t=new Map;for(const e of ft.value)t.set(e.name,Vs(e));return t}),Gs=12e4,Js=ct(()=>{const t=Date.now(),e=new Set,n=je.value;for(const a of ft.value){const s=n.get(a.name);s!=null&&t-s>Gs&&e.add(a.name)}return e}),ie={},qs=5e3;function ze(){delete ie.compact,delete ie.full}function j(t){return typeof t=="object"&&t!==null}function m(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function xt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ta(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Xs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Qs(t){if(!j(t))return null;const e=m(t.name);return e?{name:e,status:Ta(t.status),current_task:m(t.current_task)??null,last_seen:m(t.last_seen),emoji:m(t.emoji),koreanName:m(t.koreanName)??m(t.korean_name),model:m(t.model),traits:xt(t.traits),interests:xt(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:m(t.primaryValue)??m(t.primary_value)}:null}function Ys(t){if(!j(t))return null;const e=m(t.id),n=m(t.title);return!e||!n?null:{id:e,title:n,status:Xs(t.status),priority:h(t.priority),assignee:m(t.assignee),description:m(t.description),created_at:m(t.created_at),updated_at:m(t.updated_at)}}function Zs(t){if(!j(t))return null;const e=m(t.from)??m(t.from_agent)??"system",n=m(t.content)??"",a=m(t.timestamp)??new Date().toISOString();return{id:m(t.id),seq:h(t.seq),from:e,content:n,timestamp:a,type:m(t.type)}}function ti(t){return Array.isArray(t)?t.map(e=>{if(!j(e))return null;const n=h(e.ts_unix);if(n==null)return null;const a=j(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?h(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function ei(t){return(Array.isArray(t)?t:j(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!j(n))return null;const a=j(n.agent)?n.agent:null,s=j(n.context)?n.context:null,i=j(n.metrics_window)?n.metrics_window:void 0,l=m(n.name);if(!l)return null;const r=h(n.context_ratio)??h(s==null?void 0:s.context_ratio),d=m(n.status)??m(a==null?void 0:a.status)??"offline",u=Ta(d),_=m(n.model)??m(n.active_model)??m(n.primary_model),c=xt(n.skill_secondary),p=s?{source:m(s.source),context_ratio:h(s.context_ratio),context_tokens:h(s.context_tokens),context_max:h(s.context_max),message_count:h(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,v=a?{name:m(a.name),status:m(a.status),current_task:m(a.current_task)??null,last_seen:m(a.last_seen)}:void 0,w=ti(n.metrics_series);return{name:l,emoji:m(n.emoji),koreanName:m(n.koreanName)??m(n.korean_name),agent_name:m(n.agent_name),trace_id:m(n.trace_id),model:_,primary_model:m(n.primary_model),active_model:m(n.active_model),next_model_hint:m(n.next_model_hint)??null,status:u,last_heartbeat:m(n.last_heartbeat)??m(a==null?void 0:a.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:r,context_tokens:h(n.context_tokens)??h(s==null?void 0:s.context_tokens),context_max:h(n.context_max)??h(s==null?void 0:s.context_max),context_source:m(n.context_source)??m(s==null?void 0:s.source),context:p,traits:xt(n.traits),interests:xt(n.interests),primaryValue:m(n.primaryValue)??m(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:m(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:m(n.skill_primary)??null,skill_secondary:c,skill_reason:m(n.skill_reason)??null,metrics_series:w.length>0?w:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function he(t="full"){var a,s,i;const e=Date.now(),n=ie[t];if(!(n&&e-n.time<qs)){Fe.value=!0;try{const l=await $s(t);ie[t]={data:l,time:e},vt.value=(Array.isArray((a=l.agents)==null?void 0:a.agents)?l.agents.agents:[]).map(Qs).filter(r=>r!==null),Kt.value=(Array.isArray((s=l.tasks)==null?void 0:s.tasks)?l.tasks.tasks:[]).map(Ys).filter(r=>r!==null),ka.value=(Array.isArray((i=l.messages)==null?void 0:i.messages)?l.messages.messages:[]).map(Zs).filter(r=>r!==null),ft.value=ei(l.keepers),tn.value=j(l.status)?l.status:null,$t.value=l.perpetual??null}catch(l){console.error("Dashboard fetch error:",l)}finally{Fe.value=!1}}}async function nt(){Oe.value=!0;try{const t=await gs();wa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Oe.value=!1}}async function ot(){var t;He.value=!0;try{const e=bt.value||((t=tn.value)==null?void 0:t.room)||"default";bt.value||(bt.value=e);const n=await Ds(e);Sa.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{He.value=!1}}let ye=null,be=null;function ni(){return pa.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(je.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),je.value=n}ze(),ye||(ye=setTimeout(()=>{he(),ye=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(be||(be=setTimeout(()=>{nt(),be=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ze()}})}let kt=null;function ai(){kt||(kt=setInterval(()=>{ze(),he()},1e4))}function si(){kt&&(clearInterval(kt),kt=null)}function b({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function W({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ii(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function G({timestamp:t}){const e=ii(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const en=f(null);function Aa(t){en.value=t}function wn(){en.value=null}function Qt(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function oi({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
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
  `}function li({keeper:t}){var _,c;const e=t.metrics_series??[];if(e.length<2){const p=(((_=t.context)==null?void 0:_.context_ratio)??0)*100,v=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,l=e.map((p,v)=>{const w=s+v/(i-1)*(n-2*s),D=a-s-(p.context_ratio??0)*(a-2*s);return{x:w,y:D,p}}),r=l.map(({x:p,y:v})=>`${p.toFixed(1)},${v.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${s}" x2="${p.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${r}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${l.filter(({p})=>p.is_compaction).map(({x:p,y:v})=>o`
          <circle cx="${p.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const xe=f("");function ri({keeper:t}){var s,i,l,r;const e=xe.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
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
      ${((l=t.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function ci({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function ui({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function di({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Sn({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ke(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function pi({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ke(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ke(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ke(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function vi(){var e,n,a;const t=en.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&wn()}}
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
            <${W} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>wn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${oi} keeper=${t} />

        ${""}
        <${li} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${ri} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Sn} traits=${t.traits??[]} label="Traits" />
            <${Sn} traits=${t.interests??[]} label="Interests" />
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
              <${b} title="TRPG Stats">
                <${ci} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${b} title="Equipment (${t.inventory.length})">
                <${ui} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${di} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${pi} keeper=${t} />
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
  `:null}let fi=0;const tt=f([]);function k(t,e="success",n=4e3){const a=++fi;tt.value=[...tt.value,{id:a,message:t,type:e}],setTimeout(()=>{tt.value=tt.value.filter(s=>s.id!==a)},n)}function _i(t){tt.value=tt.value.filter(e=>e.id!==t)}function mi(){const t=tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>_i(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const hi="masc_dashboard_agent_name",_t=f(null),oe=f(!1),Ft=f(""),le=f([]),Ot=f([]),lt=f(""),wt=f(!1);function Na(t){_t.value=t,nn()}function Cn(){_t.value=null,Ft.value="",le.value=[],Ot.value=[],lt.value=""}function $i(){const t=_t.value;return t?vt.value.find(e=>e.name===t)??null:null}function Da(t){return t?Kt.value.filter(e=>e.assignee===t):[]}async function nn(){const t=_t.value;if(t){oe.value=!0,Ft.value="",le.value=[],Ot.value=[];try{const e=await Fs(80);le.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Da(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Os(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${l}`}}}));Ot.value=a}catch(e){Ft.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{oe.value=!1}}}async function Tn(){var a;const t=_t.value,e=lt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(hi))==null?void 0:a.trim())||"dashboard";wt.value=!0;try{await ba(n,`@${t} ${e}`),lt.value="",k(`Mention sent to ${t}`,"success"),nn()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";k(i,"error")}finally{wt.value=!1}}function gi({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${W} status=${t.status} />
    </div>
  `}function yi({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function bi(){var s,i,l,r;const t=_t.value;if(!t)return null;const e=$i(),n=Da(t),a=le.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Cn()}}
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
                        <${W} status=${e.status} />
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
            ${(((l=e==null?void 0:e.interests)==null?void 0:l.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(r=e==null?void 0:e.interests)==null?void 0:r.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
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
            <button class="control-btn ghost" onClick=${()=>{nn()}} disabled=${oe.value}>
              ${oe.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Cn}>Close</button>
          </div>
        </div>

        ${Ft.value?o`<div class="council-error">${Ft.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${gi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${Ot.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Ot.value.map(d=>o`<${yi} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${lt.value}
              onInput=${d=>{lt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Tn()}}
              disabled=${wt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Tn()}}
              disabled=${wt.value||lt.value.trim()===""}
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
  `}function xi({agent:t}){return o`
    <div class="agent" onClick=${()=>Na(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${W} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function ki(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function wi(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function An(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Si({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,a=Ws.value.get(t.name),s=Js.value.has(t.name);return o`
    <div class="live-agent keeper-card ${s?"stale":""}" onClick=${()=>Aa(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${W} status=${t.status} />
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
              <div class="keeper-ctx-fill ${An(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${An(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${ki(t.context_tokens)})`:null}
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
          <div class="keeper-note-preview">${wi(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Nn(){const t=tn.value,e=vt.value,n=ft.value,a=Ca.value;return o`
    <div class="stats-grid">
      <${at} label="Agents" value=${e.length} />
      <${at} label="Active" value=${Ks.value.length} color="#4ade80" />
      <${at} label="Keepers" value=${n.length} color="#22d3ee" />
      <${at} label="Tasks" value=${Kt.value.length} />
      <${at} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${at} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${xi} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${Si} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${$t.value?o`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${$t.value.running?"Running":"Stopped"}</span>
            ${$t.value.goal?o`<span>Goal: ${$t.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Ci(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Ci(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const Ue=f([]),Be=f([]),St=f(""),re=f(!1),Ct=f(!1),ce=f(""),ue=f(null),Tt=f(""),Ke=f(!1);async function Ve(){re.value=!0,ce.value="";try{const[t,e]=await Promise.all([Hs(),zs()]);Ue.value=t,Be.value=e}catch(t){ce.value=t instanceof Error?t.message:"Failed to load council data"}finally{re.value=!1}}async function Dn(){const t=St.value.trim();if(t){Ct.value=!0;try{const e=await Us(t);St.value="",k(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ve()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";k(n,"error")}finally{Ct.value=!1}}}async function Ti(t){ue.value=t,Ke.value=!0,Tt.value="";try{Tt.value=await Bs(t)}catch(e){Tt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{Ke.value=!1}}function Ai({debate:t}){const e=ue.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Ti(t.id)}
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
  `}function Ni({session:t}){return o`
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
  `}function Di(){return te(()=>{Ve()},[]),o`
    <div>
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${St.value}
            onInput=${t=>{St.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Dn()}}
            disabled=${Ct.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Dn}
            disabled=${Ct.value||St.value.trim()===""}
          >
            ${Ct.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ve} disabled=${re.value}>
            ${re.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${ce.value?o`<div class="council-error">${ce.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${Ue.value.length===0?o`<div class="empty-state">No debates yet</div>`:Ue.value.map(t=>o`<${Ai} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Be.value.length===0?o`<div class="empty-state">No active sessions</div>`:Be.value.map(t=>o`<${Ni} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${b} title=${ue.value?`Debate Detail (${ue.value})`:"Debate Detail"} class="section">
        ${Ke.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?o`<pre class="council-detail">${Tt.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Pi({text:t}){if(!t)return null;const e=Ei(t);return o`<div class="markdown-content">${e}</div>`}function Ei(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const l=s.match(/^(`{3,}|~{3,})/)[0],r=s.slice(l.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(l);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${r?`language-${r}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const l=[],r=s.trim().replace(/^<think>/,"").trim();for(r&&r!=="</think>"&&l.push(r),a++;a<e.length&&!e[a].includes("</think>");)l.push(e[a]),a++;if(a<e.length){const u=e[a].replace("</think>","").trim();u&&l.push(u),a++}const d=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${we(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const l=[];for(;a<e.length&&e[a].startsWith("> ");)l.push(e[a].slice(2)),a++;n.push(o`<blockquote>${we(l.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const l=e[a];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),a++}i.length>0&&n.push(o`<p>${we(i.join(`
`))}</p>`)}return n}function we(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Ri=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],At=f([]),Nt=f(!1),Dt=f(""),Li=f("dashboard-user"),Pt=f(!1);async function Pa(t){Nt.value=!0,At.value=[];try{const e=await ys(t);At.value=e.comments??[]}catch{}finally{Nt.value=!1}}async function Pn(t){const e=Dt.value.trim();if(e){Pt.value=!0;try{await bs(t,Li.value,e),Dt.value="",k("Comment posted","success"),await Pa(t),nt()}catch{k("Failed to post comment","error")}finally{Pt.value=!1}}}function Mi(){const t=kn.value;return o`
    <div class="board-controls">
      ${Ri.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{kn.value=e.id,nt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Ea({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Ii({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await ya(t.id,n),nt()}catch{k("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>es(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ea} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${G} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function ji({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${G} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Fi({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Dt.value}
        onInput=${e=>{Dt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Pn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Pt.value}
      />
      <button
        onClick=${()=>Pn(t)}
        disabled=${Pt.value||Dt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Pt.value?"...":"Post"}
      </button>
    </div>
  `}function Oi({post:t}){At.value.length===0&&!Nt.value&&Pa(t.id);const e=async n=>{try{await ya(t.id,n),nt()}catch{k("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>me("board")}>← Back to Board</button>
      <${b} title=${o`${t.title} <${Ea} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Pi} text=${t.content} />
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

      <${b} title="Comments (${Nt.value?"...":At.value.length})">
        ${Nt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${ji} comments=${At.value} />`}
        <${Fi} postId=${t.id} />
      <//>
    </div>
  `}function Hi(){const t=wa.value,e=Oe.value,n=z.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${Oi} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>me("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${Mi} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${Ii} key=${a.id} post=${a} />`)}
          </div>`}
  `}function zi(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Ui(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function En(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Bi({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${G} timestamp=${t.timestamp} /></span>
    </div>
  `}function Ki(){const t=ka.value.map(zi),e=se.value.map(Ui),n=[...t,...e].sort((a,s)=>En(s.timestamp)-En(a.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(a=>o`<${Bi} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function Vi({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Na(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${W} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Wi({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>Aa(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${W} status=${t.status} />
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
  `}function Gi(){const t=vt.value,e=ft.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Wi} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Vi} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Se({task:t}){return o`
    <div class="task-row">
      <${W} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${G} timestamp=${t.created_at} />`:null}
    </div>
  `}function Ji(){const{todo:t,inProgress:e,done:n}=Ca.value;return o`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${Se} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${Se} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${Se} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function qi({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Xi(){const t=se.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${qi} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const ht=f(""),Ce=f("ability_check"),Te=f("10"),Ae=f("12"),Gt=f(""),Jt=f("idle");function Qi(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Yi(t,e){return e>0?Math.round(t/e*100):0}function Zi({hp:t,max:e}){const n=Yi(t,e),a=Qi(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function to({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function eo({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function no({actor:t}){return o`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${W} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${eo} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Zi} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${to} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function ao({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function so({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
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
  `}function io({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function oo({state:t}){var d;const e=bt.value||((d=t.session)==null?void 0:d.room)||"",n=Jt.value,a=t.party??[];if(!a.find(u=>u.id===ht.value)&&a.length>0){const u=a[0];u&&(ht.value=u.id)}const i=async()=>{if(!e){k("No room set","error");return}Jt.value="running";try{await Ps(e),Jt.value="ok",k("Round executed","success"),ot()}catch{Jt.value="error",k("Round failed","error")}},l=async()=>{if(e)try{await Ls(e),k("Turn advanced","success"),ot()}catch{k("Advance failed","error")}},r=async()=>{if(!e)return;const u=ht.value.trim();if(!u){k("Select actor first","warning");return}const _=Number.parseInt(Te.value,10),c=Number.parseInt(Ae.value,10);if(Number.isNaN(_)||Number.isNaN(c)){k("Stat/DC must be numbers","warning");return}const p=Number.parseInt(Gt.value,10),v=Gt.value.trim()===""||Number.isNaN(p)?void 0:p;try{await Rs({roomId:e,actorId:u,action:Ce.value.trim()||"ability_check",statValue:_,dc:c,rawD20:v}),k("Dice rolled","success"),ot()}catch{k("Dice roll failed","error")}};return o`
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
              onKeyDown=${u=>{u.key==="Enter"&&r()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${r}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?o`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function lo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ro(){var s,i;const t=Sa.value;if(He.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
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
      <${lo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${a.length})">
            <${so} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${b} title="Map" style="margin-top:16px;">
                <${ao} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${oo} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(l=>o`<${no} key=${l.id??l.name} actor=${l} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${io} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const an="masc_dashboard_agent_name";function co(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(an);return e??n??"dashboard"}const F=f(co()),Et=f(""),Rt=f(""),de=f(""),Lt=f(!1),st=f(!1),Mt=f(!1),It=f(!1),pe=f(!1),$e=f(!1);function sn(t){const e=t.trim();F.value=e,e&&localStorage.setItem(an,e)}function uo(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function We(){const t=F.value.trim();if(t){Mt.value=!0;try{const e=await Is(t),n=uo(e);n&&sn(n),$e.value=!0,k(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";k(n,"error")}finally{Mt.value=!1}}}async function po(){const t=F.value.trim();if(t){It.value=!0;try{await xa(t),$e.value=!1,k(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";k(n,"error")}finally{It.value=!1}}}async function vo(){const t=F.value.trim();if(t)try{await xa(t)}catch{}localStorage.removeItem(an),sn("dashboard"),$e.value=!1,await We()}async function fo(){const t=F.value.trim();if(t){pe.value=!0;try{await js(t),k("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";k(n,"error")}finally{pe.value=!1}}}async function Rn(){const t=F.value.trim(),e=Et.value.trim();if(!(!t||!e)){Lt.value=!0;try{await ba(t,e),Et.value="",k("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";k(a,"error")}finally{Lt.value=!1}}}async function _o(){const t=Rt.value.trim(),e=de.value.trim()||"Created from dashboard";if(t){st.value=!0;try{await Ms(t,e,1),Rt.value="",de.value="",k("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";k(a,"error")}finally{st.value=!1}}}function mo(){return te(()=>{We()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${F.value}
        onInput=${t=>sn(t.target.value)}
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
          onKeyDown=${t=>{t.key==="Enter"&&Rn()}}
          disabled=${Lt.value}
        />
        <button
          class="control-btn"
          onClick=${Rn}
          disabled=${Lt.value||Et.value.trim()===""||F.value.trim()===""}
        >
          ${Lt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{We()}}
          disabled=${Mt.value||F.value.trim()===""}
        >
          ${Mt.value?"Joining...":$e.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{po()}}
          disabled=${It.value||F.value.trim()===""}
        >
          ${It.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{vo()}}
          disabled=${Mt.value||It.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{fo()}}
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
        value=${Rt.value}
        onInput=${t=>{Rt.value=t.target.value}}
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
        onClick=${_o}
        disabled=${st.value||Rt.value.trim()===""}
      >
        ${st.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function ho(){const t=ut.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Ye.value} events</span>
    </div>
  `}const $o=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function go(){const t=z.value.tab,e=ut.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${$o.map(n=>o`
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
            <strong>${Ye.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{he(),t==="board"&&nt(),t==="trpg"&&ot()}}
        >
          Refresh Now
        </button>
      </section>

      <${mo} />
    </aside>
  `}function yo(){switch(z.value.tab){case"overview":return o`<${Nn} />`;case"council":return o`<${Di} />`;case"board":return o`<${Hi} />`;case"activity":return o`<${Ki} />`;case"agents":return o`<${Gi} />`;case"tasks":return o`<${Ji} />`;case"journal":return o`<${Xi} />`;case"trpg":return o`<${ro} />`;default:return o`<${Nn} />`}}function bo(){return te(()=>{ns(),fa(),he();const t=ni();return ai(),()=>{ds(),t(),si()}},[]),te(()=>{const t=z.value.tab;t==="board"&&nt(),t==="trpg"&&ot()},[z.value.tab]),o`
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
          <${ho} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${ss} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Fe.value&&!ut.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${yo} />`}
        </main>
        <${go} />
      </div>

      <${vi} />
      <${bi} />
      <${mi} />
    </div>
  `}const Ln=document.getElementById("app");Ln&&Ha(o`<${bo} />`,Ln);
