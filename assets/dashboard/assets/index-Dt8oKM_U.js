(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const o of document.querySelectorAll('link[rel="modulepreload"]'))s(o);new MutationObserver(o=>{for(const i of o)if(i.type==="childList")for(const a of i.addedNodes)a.tagName==="LINK"&&a.rel==="modulepreload"&&s(a)}).observe(document,{childList:!0,subtree:!0});function n(o){const i={};return o.integrity&&(i.integrity=o.integrity),o.referrerPolicy&&(i.referrerPolicy=o.referrerPolicy),o.crossOrigin==="use-credentials"?i.credentials="include":o.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(o){if(o.ep)return;o.ep=!0;const i=n(o);fetch(o.href,i)}})();var dt,h,ue,_e,M,Wt,de,fe,ve,Mt,St,kt,X={},pe=[],Xe=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,ft=Array.isArray;function C(t,e){for(var n in e)t[n]=e[n];return t}function Dt(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function he(t,e,n){var s,o,i,a={};for(i in e)i=="key"?s=e[i]:i=="ref"?o=e[i]:a[i]=e[i];if(arguments.length>2&&(a.children=arguments.length>3?dt.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)a[i]===void 0&&(a[i]=t.defaultProps[i]);return it(t,a,s,o,null)}function it(t,e,n,s,o){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:o??++ue,__i:-1,__u:0};return o==null&&h.vnode!=null&&h.vnode(i),i}function Q(t){return t.children}function K(t,e){this.props=t,this.context=e}function I(t,e){if(e==null)return t.__?I(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?I(t):null}function $e(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return $e(t)}}function Jt(t){(!t.__d&&(t.__d=!0)&&M.push(t)&&!rt.__r++||Wt!=h.debounceRendering)&&((Wt=h.debounceRendering)||de)(rt)}function rt(){for(var t,e,n,s,o,i,a,c=1;M.length;)M.length>c&&M.sort(fe),t=M.shift(),c=M.length,t.__d&&(n=void 0,s=void 0,o=(s=(e=t).__v).__e,i=[],a=[],e.__P&&((n=C({},s)).__v=s.__v+1,h.vnode&&h.vnode(n),Ut(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[o]:null,i,o??I(s),!!(32&s.__u),a),n.__v=s.__v,n.__.__k[n.__i]=n,ye(i,n,a),s.__e=s.__=null,n.__e!=o&&$e(n)));rt.__r=0}function me(t,e,n,s,o,i,a,c,_,u,d){var r,v,f,b,T,w,m,$=s&&s.__k||pe,N=e.length;for(_=Ze(n,e,$,_,N),r=0;r<N;r++)(f=n.__k[r])!=null&&(v=f.__i==-1?X:$[f.__i]||X,f.__i=r,w=Ut(t,f,v,o,i,a,c,_,u,d),b=f.__e,f.ref&&v.ref!=f.ref&&(v.ref&&Ht(v.ref,null,f),d.push(f.ref,f.__c||b,f)),T==null&&b!=null&&(T=b),(m=!!(4&f.__u))||v.__k===f.__k?_=ge(f,_,t,m):typeof f.type=="function"&&w!==void 0?_=w:b&&(_=b.nextSibling),f.__u&=-7);return n.__e=T,_}function Ze(t,e,n,s,o){var i,a,c,_,u,d=n.length,r=d,v=0;for(t.__k=new Array(o),i=0;i<o;i++)(a=e[i])!=null&&typeof a!="boolean"&&typeof a!="function"?(typeof a=="string"||typeof a=="number"||typeof a=="bigint"||a.constructor==String?a=t.__k[i]=it(null,a,null,null,null):ft(a)?a=t.__k[i]=it(Q,{children:a},null,null,null):a.constructor===void 0&&a.__b>0?a=t.__k[i]=it(a.type,a.props,a.key,a.ref?a.ref:null,a.__v):t.__k[i]=a,_=i+v,a.__=t,a.__b=t.__b+1,c=null,(u=a.__i=Qe(a,n,_,r))!=-1&&(r--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(o>d?v--:o<d&&v++),typeof a.type!="function"&&(a.__u|=4)):u!=_&&(u==_-1?v--:u==_+1?v++:(u>_?v--:v++,a.__u|=4))):t.__k[i]=null;if(r)for(i=0;i<d;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==s&&(s=I(c)),we(c,c));return s}function ge(t,e,n,s){var o,i;if(typeof t.type=="function"){for(o=t.__k,i=0;o&&i<o.length;i++)o[i]&&(o[i].__=t,e=ge(o[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=I(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Qe(t,e,n,s){var o,i,a,c=t.key,_=t.type,u=e[n],d=u!=null&&(2&u.__u)==0;if(u===null&&c==null||d&&c==u.key&&_==u.type)return n;if(s>(d?1:0)){for(o=n-1,i=n+1;o>=0||i<e.length;)if((u=e[a=o>=0?o--:i++])!=null&&(2&u.__u)==0&&c==u.key&&_==u.type)return a}return-1}function Kt(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Xe.test(e)?n:n+"px"}function nt(t,e,n,s,o){var i,a;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Kt(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Kt(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(ve,"$1")),a=e.toLowerCase(),e=a in t||e=="onFocusOut"||e=="onFocusIn"?a.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Mt,t.addEventListener(e,i?kt:St,i)):t.removeEventListener(e,i?kt:St,i);else{if(o=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function zt(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Mt++;else if(e.t<n.u)return;return n(h.event?h.event(e):e)}}}function Ut(t,e,n,s,o,i,a,c,_,u){var d,r,v,f,b,T,w,m,$,N,R,tt,q,qt,et,W,mt,P=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(_=!!(32&n.__u),i=[c=e.__e=n.__e]),(d=h.__b)&&d(e);t:if(typeof P=="function")try{if(m=e.props,$="prototype"in P&&P.prototype.render,N=(d=P.contextType)&&s[d.__c],R=d?N?N.props.value:d.__:s,n.__c?w=(r=e.__c=n.__c).__=r.__E:($?e.__c=r=new P(m,R):(e.__c=r=new K(m,R),r.constructor=P,r.render=tn),N&&N.sub(r),r.state||(r.state={}),r.__n=s,v=r.__d=!0,r.__h=[],r._sb=[]),$&&r.__s==null&&(r.__s=r.state),$&&P.getDerivedStateFromProps!=null&&(r.__s==r.state&&(r.__s=C({},r.__s)),C(r.__s,P.getDerivedStateFromProps(m,r.__s))),f=r.props,b=r.state,r.__v=e,v)$&&P.getDerivedStateFromProps==null&&r.componentWillMount!=null&&r.componentWillMount(),$&&r.componentDidMount!=null&&r.__h.push(r.componentDidMount);else{if($&&P.getDerivedStateFromProps==null&&m!==f&&r.componentWillReceiveProps!=null&&r.componentWillReceiveProps(m,R),e.__v==n.__v||!r.__e&&r.shouldComponentUpdate!=null&&r.shouldComponentUpdate(m,r.__s,R)===!1){for(e.__v!=n.__v&&(r.props=m,r.state=r.__s,r.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(H){H&&(H.__=e)}),tt=0;tt<r._sb.length;tt++)r.__h.push(r._sb[tt]);r._sb=[],r.__h.length&&a.push(r);break t}r.componentWillUpdate!=null&&r.componentWillUpdate(m,r.__s,R),$&&r.componentDidUpdate!=null&&r.__h.push(function(){r.componentDidUpdate(f,b,T)})}if(r.context=R,r.props=m,r.__P=t,r.__e=!1,q=h.__r,qt=0,$){for(r.state=r.__s,r.__d=!1,q&&q(e),d=r.render(r.props,r.state,r.context),et=0;et<r._sb.length;et++)r.__h.push(r._sb[et]);r._sb=[]}else do r.__d=!1,q&&q(e),d=r.render(r.props,r.state,r.context),r.state=r.__s;while(r.__d&&++qt<25);r.state=r.__s,r.getChildContext!=null&&(s=C(C({},s),r.getChildContext())),$&&!v&&r.getSnapshotBeforeUpdate!=null&&(T=r.getSnapshotBeforeUpdate(f,b)),W=d,d!=null&&d.type===Q&&d.key==null&&(W=be(d.props.children)),c=me(t,ft(W)?W:[W],e,n,s,o,i,a,c,_,u),r.base=e.__e,e.__u&=-161,r.__h.length&&a.push(r),w&&(r.__E=r.__=null)}catch(H){if(e.__v=null,_||i!=null)if(H.then){for(e.__u|=_?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(mt=i.length;mt--;)Dt(i[mt]);Tt(e)}else e.__e=n.__e,e.__k=n.__k,H.then||Tt(e);h.__e(H,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=Ye(n.__e,e,n,s,o,i,a,_,u);return(d=h.diffed)&&d(e),128&e.__u?void 0:c}function Tt(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Tt)}function ye(t,e,n){for(var s=0;s<n.length;s++)Ht(n[s],n[++s],n[++s]);h.__c&&h.__c(e,t),t.some(function(o){try{t=o.__h,o.__h=[],t.some(function(i){i.call(o)})}catch(i){h.__e(i,o.__v)}})}function be(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:ft(t)?t.map(be):C({},t)}function Ye(t,e,n,s,o,i,a,c,_){var u,d,r,v,f,b,T,w=n.props||X,m=e.props,$=e.type;if($=="svg"?o="http://www.w3.org/2000/svg":$=="math"?o="http://www.w3.org/1998/Math/MathML":o||(o="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((f=i[u])&&"setAttribute"in f==!!$&&($?f.localName==$:f.nodeType==3)){t=f,i[u]=null;break}}if(t==null){if($==null)return document.createTextNode(m);t=document.createElementNS(o,$,m.is&&m),c&&(h.__m&&h.__m(e,i),c=!1),i=null}if($==null)w===m||c&&t.data==m||(t.data=m);else{if(i=i&&dt.call(t.childNodes),!c&&i!=null)for(w={},u=0;u<t.attributes.length;u++)w[(f=t.attributes[u]).name]=f.value;for(u in w)if(f=w[u],u!="children"){if(u=="dangerouslySetInnerHTML")r=f;else if(!(u in m)){if(u=="value"&&"defaultValue"in m||u=="checked"&&"defaultChecked"in m)continue;nt(t,u,null,f,o)}}for(u in m)f=m[u],u=="children"?v=f:u=="dangerouslySetInnerHTML"?d=f:u=="value"?b=f:u=="checked"?T=f:c&&typeof f!="function"||w[u]===f||nt(t,u,f,w[u],o);if(d)c||r&&(d.__html==r.__html||d.__html==t.innerHTML)||(t.innerHTML=d.__html),e.__k=[];else if(r&&(t.innerHTML=""),me(e.type=="template"?t.content:t,ft(v)?v:[v],e,n,s,$=="foreignObject"?"http://www.w3.org/1999/xhtml":o,i,a,i?i[0]:n.__k&&I(n,0),c,_),i!=null)for(u=i.length;u--;)Dt(i[u]);c||(u="value",$=="progress"&&b==null?t.removeAttribute("value"):b!=null&&(b!==t[u]||$=="progress"&&!b||$=="option"&&b!=w[u])&&nt(t,u,b,w[u],o),u="checked",T!=null&&T!=t[u]&&nt(t,u,T,w[u],o))}return t}function Ht(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(o){h.__e(o,n)}}function we(t,e,n){var s,o;if(h.unmount&&h.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Ht(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){h.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(o=0;o<s.length;o++)s[o]&&we(s[o],e,n||typeof t.type!="function");n||Dt(t.__e),t.__c=t.__=t.__e=void 0}function tn(t,e,n){return this.constructor(t,n)}function en(t,e,n){var s,o,i,a;e==document&&(e=document.documentElement),h.__&&h.__(t,e),o=(s=!1)?null:e.__k,i=[],a=[],Ut(e,t=e.__k=he(Q,null,[t]),o||X,X,e.namespaceURI,o?null:e.firstChild?dt.call(e.childNodes):null,i,o?o.__e:e.firstChild,s,a),ye(i,t,a)}dt=pe.slice,h={__e:function(t,e,n,s){for(var o,i,a;e=e.__;)if((o=e.__c)&&!o.__)try{if((i=o.constructor)&&i.getDerivedStateFromError!=null&&(o.setState(i.getDerivedStateFromError(t)),a=o.__d),o.componentDidCatch!=null&&(o.componentDidCatch(t,s||{}),a=o.__d),a)return o.__E=o}catch(c){t=c}throw t}},ue=0,_e=function(t){return t!=null&&t.constructor===void 0},K.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=C({},this.state),typeof t=="function"&&(t=t(C({},n),this.props)),t&&C(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Jt(this))},K.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Jt(this))},K.prototype.render=Q,M=[],de=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,fe=function(t,e){return t.__v.__b-e.__v.__b},rt.__r=0,ve=/(PointerCapture)$|Capture$/i,Mt=0,St=zt(!1),kt=zt(!0);var Se=function(t,e,n,s){var o;e[0]=0;for(var i=1;i<e.length;i++){var a=e[i++],c=e[i]?(e[0]|=a?1:2,n[e[i++]]):e[++i];a===3?s[0]=c:a===4?s[1]=Object.assign(s[1]||{},c):a===5?(s[1]=s[1]||{})[e[++i]]=c:a===6?s[1][e[++i]]+=c+"":a?(o=t.apply(c,Se(t,c,n,["",null])),s.push(o),c[0]?e[0]|=2:(e[i-2]=0,e[i]=o)):s.push(c)}return s},Vt=new Map;function nn(t){var e=Vt.get(this);return e||(e=new Map,Vt.set(this,e)),(e=Se(this,e.get(t)||(e.set(t,e=(function(n){for(var s,o,i=1,a="",c="",_=[0],u=function(v){i===1&&(v||(a=a.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?_.push(0,v,a):i===3&&(v||a)?(_.push(3,v,a),i=2):i===2&&a==="..."&&v?_.push(4,v,0):i===2&&a&&!v?_.push(5,0,!0,a):i>=5&&((a||!v&&i===5)&&(_.push(i,0,a,o),i=6),v&&(_.push(i,v,0,o),i=6)),a=""},d=0;d<n.length;d++){d&&(i===1&&u(),u(d));for(var r=0;r<n[d].length;r++)s=n[d][r],i===1?s==="<"?(u(),_=[_],i=3):a+=s:i===4?a==="--"&&s===">"?(i=1,a=""):a=s+a[0]:c?s===c?c="":a+=s:s==='"'||s==="'"?c=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,o=a,a=""):s==="/"&&(i<5||n[d][r+1]===">")?(u(),i===3&&(_=_[0]),i=_,(_=_[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):a+=s),i===3&&a==="!--"&&(i=4,_=_[0])}return u(),_})(t)),e),arguments,[])).length>1?e:e[0]}var l=nn.bind(he),lt,k,gt,Xt,Zt=0,ke=[],g=h,Qt=g.__b,Yt=g.__r,te=g.diffed,ee=g.__c,ne=g.unmount,se=g.__;function Te(t,e){g.__h&&g.__h(k,t,Zt||e),Zt=0;var n=k.__H||(k.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ie(t,e){var n=Te(lt++,3);!g.__s&&xe(n.__H,e)&&(n.__=t,n.u=e,k.__H.__h.push(n))}function Pe(t,e){var n=Te(lt++,7);return xe(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function sn(){for(var t;t=ke.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ot),t.__H.__h.forEach(Pt),t.__H.__h=[]}catch(e){t.__H.__h=[],g.__e(e,t.__v)}}g.__b=function(t){k=null,Qt&&Qt(t)},g.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),se&&se(t,e)},g.__r=function(t){Yt&&Yt(t),lt=0;var e=(k=t.__c).__H;e&&(gt===k?(e.__h=[],k.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ot),e.__h.forEach(Pt),e.__h=[],lt=0)),gt=k},g.diffed=function(t){te&&te(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(ke.push(e)!==1&&Xt===g.requestAnimationFrame||((Xt=g.requestAnimationFrame)||on)(sn)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),gt=k=null},g.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ot),n.__h=n.__h.filter(function(s){return!s.__||Pt(s)})}catch(s){e.some(function(o){o.__h&&(o.__h=[])}),e=[],g.__e(s,n.__v)}}),ee&&ee(t,e)},g.unmount=function(t){ne&&ne(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{ot(s)}catch(o){e=o}}),n.__H=void 0,e&&g.__e(e,n.__v))};var oe=typeof requestAnimationFrame=="function";function on(t){var e,n=function(){clearTimeout(s),oe&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);oe&&(e=requestAnimationFrame(n))}function ot(t){var e=k,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),k=e}function Pt(t){var e=k;t.__c=t.__(),k=e}function xe(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var an=Symbol.for("preact-signals");function vt(){if(E>1)E--;else{for(var t,e=!1;z!==void 0;){var n=z;for(z=void 0,xt++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ne(n))try{n.c()}catch(o){e||(t=o,e=!0)}n=s}}if(xt=0,E--,e)throw t}}function rn(t){if(E>0)return t();E++;try{return t()}finally{vt()}}var p=void 0;function Ae(t){var e=p;p=void 0;try{return t()}finally{p=e}}var z=void 0,E=0,xt=0,ct=0;function Ce(t){if(p!==void 0){var e=t.n;if(e===void 0||e.t!==p)return e={i:0,S:t,p:p.s,n:void 0,t:p,e:void 0,x:void 0,r:e},p.s!==void 0&&(p.s.n=e),p.s=e,t.n=e,32&p.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=p.s,e.n=void 0,p.s.n=e,p.s=e),e}}function S(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}S.prototype.brand=an;S.prototype.h=function(){return!0};S.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ae(function(){var s;(s=e.W)==null||s.call(e)}))};S.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ae(function(){var o;(o=e.Z)==null||o.call(e)}))}};S.prototype.subscribe=function(t){var e=this;return Y(function(){var n=e.value,s=p;p=void 0;try{t(n)}finally{p=s}},{name:"sub"})};S.prototype.valueOf=function(){return this.value};S.prototype.toString=function(){return this.value+""};S.prototype.toJSON=function(){return this.value};S.prototype.peek=function(){var t=p;p=void 0;try{return this.value}finally{p=t}};Object.defineProperty(S.prototype,"value",{get:function(){var t=Ce(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(xt>100)throw new Error("Cycle detected");this.v=t,this.i++,ct++,E++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{vt()}}}});function y(t,e){return new S(t,e)}function Ne(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ee(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Re(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function U(t,e){S.call(this,void 0),this.x=t,this.s=void 0,this.g=ct-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}U.prototype=new S;U.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ct))return!0;if(this.g=ct,this.f|=1,this.i>0&&!Ne(this))return this.f&=-2,!0;var t=p;try{Ee(this),p=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return p=t,Re(this),this.f&=-2,!0};U.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}S.prototype.S.call(this,t)};U.prototype.U=function(t){if(this.t!==void 0&&(S.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};U.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(U.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ce(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ut(t,e){return new U(t,e)}function Le(t){var e=t.u;if(t.u=void 0,typeof e=="function"){E++;var n=p;p=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Ot(t),s}finally{p=n,vt()}}}function Ot(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Le(t)}function ln(t){if(p!==this)throw new Error("Out-of-order effect");Re(this),p=t,this.f&=-2,8&this.f&&Ot(this),vt()}function B(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}B.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};B.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Le(this),Ee(this),E++;var t=p;return p=this,ln.bind(this,t)};B.prototype.N=function(){2&this.f||(this.f|=2,this.o=z,z=this)};B.prototype.d=function(){this.f|=8,1&this.f||Ot(this)};B.prototype.dispose=function(){this.d()};function Y(t,e){var n=new B(t,e);try{n.c()}catch(o){throw n.d(),o}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Me,st,cn=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,De=[];Y(function(){Me=this.N})();function F(t,e){h[t]=e.bind(null,h[t]||function(){})}function _t(t){if(st){var e=st;st=void 0,e()}st=t&&t.S()}function Ue(t){var e=this,n=t.data,s=_n(n);s.value=n;var o=Pe(function(){for(var c=e,_=e.__v;_=_.__;)if(_.__c){_.__c.__$f|=4;break}var u=ut(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),d=ut(function(){return!Array.isArray(u.value)&&!_e(u.value)}),r=Y(function(){if(this.N=He,d.value){var f=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=f)}}),v=e.__$u.d;return e.__$u.d=function(){r(),v.call(this)},[d,u]},[]),i=o[0],a=o[1];return i.value?a.peek():a.value}Ue.displayName="ReactiveTextNode";Object.defineProperties(S.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ue},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});F("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var o in s)if(o!=="children"){var i=s[o];i instanceof S&&(n||(e.__np=n={}),n[o]=i,s[o]=i.peek())}}t(e)});F("__r",function(t,e){if(t(e),e.type!==Q){_t();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(o,i){var a;return Y(function(){a=this},{name:i}),a.c=o,a})(function(){var o;cn&&((o=n.y)==null||o.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),_t(n)}});F("__e",function(t,e,n,s){_t(),t(e,n,s)});F("diffed",function(t,e){_t();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,o=e.props;if(s){var i=n.U;if(i)for(var a in i){var c=i[a];c!==void 0&&!(a in s)&&(c.d(),i[a]=void 0)}else i={},n.U=i;for(var _ in s){var u=i[_],d=s[_];u===void 0?(u=un(n,_,d),i[_]=u):u.o(d,o)}for(var r in s)o[r]=s[r]}}t(e)});function un(t,e,n,s){var o=e in t&&t.ownerSVGElement===void 0,i=y(n),a=n.peek();return{o:function(c,_){i.value=c,a=c.peek()},d:Y(function(){this.N=He;var c=i.value.value;a!==c?(a=void 0,o?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):a=void 0})}}F("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var o in s){var i=s[o];i&&i.d()}}}e.__np=void 0}else{var a=e.__c;if(a){var c=a.__$u;c&&(a.__$u=void 0,c.d())}}t(e)});F("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});K.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var o in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var a in t)if(a!=="__source"&&t[a]!==this.props[a])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function _n(t,e){return Pe(function(){return y(t,e)},[])}var dn=function(t){queueMicrotask(function(){queueMicrotask(t)})};function fn(){rn(function(){for(var t;t=De.shift();)Me.call(t)})}function He(){De.push(this)===1&&(h.requestAnimationFrame||dn)(fn)}const vn=["overview","board","activity","agents","tasks","journal","trpg"];function jt(t){const e=(t||"").replace(/^#/,"");if(!e)return{tab:"overview",params:{},postId:null};const[n,s]=e.split("?"),o=n.split("/"),i=vn.includes(o[0])?o[0]:"overview";let a=null;o[0]==="board"&&o[1]==="post"&&o[2]&&(a=o[2]);const c={};return s&&new URLSearchParams(s).forEach((u,d)=>{c[d]=u}),{tab:i,params:c,postId:a}}const D=y(jt(window.location.hash));window.addEventListener("hashchange",()=>{D.value=jt(window.location.hash)});function Oe(t,e){let n=`#${t}`;window.location.hash=n}function pn(t){window.location.hash=`#board/post/${t}`}function hn(){(!window.location.hash||window.location.hash==="#")&&(window.location.hash="#overview"),D.value=jt(window.location.hash)}const $n=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function mn(){const t=D.value.tab;return l`
    <div class="main-tab-bar">
      ${$n.map(e=>l`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Oe(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ae="masc_dashboard_sse_session_id",gn=1e3,yn=15e3,Z=y(!1),At=y(0),je=y(null),Ct=y([]);function bn(){let t=sessionStorage.getItem(ae);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ae,t)),t}const wn=200;function L(t,e){const n={agent:t,text:e,timestamp:Date.now()};Ct.value=[n,...Ct.value].slice(0,wn)}let x=null,j=null,Nt=0;function Ie(){j&&(clearTimeout(j),j=null)}function Sn(){if(j)return;Nt++;const t=Math.min(Nt,5),e=Math.min(yn,gn*Math.pow(2,t));j=setTimeout(()=>{j=null,Be()},e)}function Be(){Ie(),x&&(x.close(),x=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",bn());const o=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(o);x=i,i.onopen=()=>{x===i&&(Nt=0,Z.value=!0)},i.onerror=()=>{x===i&&(Z.value=!1,i.close(),x=null,Sn())},i.onmessage=a=>{try{const c=JSON.parse(a.data);At.value++,je.value=c,kn(c)}catch{}}}function kn(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":L(n,"Joined");break;case"agent_left":L(n,"Left");break;case"broadcast":L(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":L(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":L(n,"New post");break;case"board_comment":L(n,"New comment");break;default:L(n,e)}}function Tn(){Ie(),x&&(x.close(),x=null),Z.value=!1}function Pn(){return new URLSearchParams(window.location.search)}function Fe(){const t=Pn(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function xn(){return{...Fe(),"Content-Type":"application/json"}}async function It(t){const e=await fetch(t,{headers:Fe()});if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function An(t,e){const n=await fetch(t,{method:"POST",headers:xn(),body:JSON.stringify(e)});if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}function Cn(){return It("/api/v1/dashboard")}function Nn(){return It("/api/v1/board")}function En(t,e){return An(`/api/v1/board/${t}/vote`,{direction:e})}function Rn(t){const e=t?`?room=${encodeURIComponent(t)}`:"";return It(`/api/v1/trpg/state${e}`)}const pt=y([]),Bt=y([]),Ge=y([]),Ft=y([]),qe=y(null),J=y(null),We=y([]),re=y("hot"),Je=y(null),Ln=y(""),Et=y(!1),Rt=y(!1),Lt=y(!1),Mn=ut(()=>pt.value.filter(t=>t.status==="active"||t.status==="idle")),Ke=ut(()=>{const t=Bt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let at=null;const Dn=5e3;function ze(){at=null}function Un(t){return Array.isArray(t)?t:t&&Array.isArray(t.keepers)?t.keepers:[]}async function Gt(){var e,n,s;const t=Date.now();if(!(at&&t-at.time<Dn)){Et.value=!0;try{const o=await Cn();at={data:o,time:t},pt.value=((e=o.agents)==null?void 0:e.agents)??[],Bt.value=((n=o.tasks)==null?void 0:n.tasks)??[],Ge.value=((s=o.messages)==null?void 0:s.messages)??[],Ft.value=Un(o.keepers),qe.value=o.status??null,J.value=o.perpetual??null}catch(o){console.error("Dashboard fetch error:",o)}finally{Et.value=!1}}}async function ht(){Rt.value=!0;try{const t=await Nn();We.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Rt.value=!1}}async function Ve(){Lt.value=!0;try{const t=Ln.value||void 0,e=await Rn(t);Je.value=e}catch(t){console.error("TRPG fetch error:",t)}finally{Lt.value=!1}}let yt=null,bt=null;function Hn(){return je.subscribe(e=>{e&&(ze(),yt||(yt=setTimeout(()=>{Gt(),yt=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(bt||(bt=setTimeout(()=>{ht(),bt=null},500))))})}let V=null;function On(){V||(V=setInterval(()=>{ze(),Gt()},1e4))}function jn(){V&&(clearInterval(V),V=null)}function A({title:t,class:e,children:n}){return l`
    <div class="card ${e??""}">
      ${t?l`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function G({status:t,label:e}){return l`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function O({label:t,value:e,color:n}){return l`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function In({agent:t}){return l`
    <div class="agent">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${G} status=${t.status} />
      ${t.current_task?l`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Bn({keeper:t}){return l`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
          ${t.model?l`<span class="pill">${t.model}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>
        ${t.generation!=null?l`<div class="live-agent-meta">
              <span>Gen ${t.generation}</span>
              <span>Turn ${t.turn_count??0}</span>
              ${t.context_ratio!=null?l`<span class=${t.context_ratio>.7?"warn-metric":""}>
                    Ctx ${Math.round(t.context_ratio*100)}%
                  </span>`:null}
            </div>`:null}
      </div>
    </div>
  `}function le(){const t=qe.value,e=pt.value,n=Ft.value,s=Ke.value;return l`
    <div class="stats-grid">
      <${O} label="Agents" value=${e.length} />
      <${O} label="Active" value=${Mn.value.length} color="#4ade80" />
      <${O} label="Keepers" value=${n.length} color="#22d3ee" />
      <${O} label="Tasks" value=${Bt.value.length} />
      <${O} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${O} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${A} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?l`<div class="empty-state">No agents connected</div>`:e.map(o=>l`<${In} key=${o.name} agent=${o} />`)}
        </div>
      <//>

      <${A} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?l`<div class="empty-state">No keepers active</div>`:n.map(o=>l`<${Bn} key=${o.name} keeper=${o} />`)}
        </div>
      <//>
    </div>

    ${J.value?l`
        <${A} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${J.value.running?"Running":"Stopped"}</span>
            ${J.value.goal?l`<span>Goal: ${J.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?l`
        <${A} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${Fn(t.uptime_seconds)}</span>
          </div>
        <//>
      `:null}
  `}function Fn(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Gn(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const o=Math.floor(s/60);if(o<60)return`${o}m ago`;const i=Math.floor(o/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function $t({timestamp:t}){const e=Gn(t);return l`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const qn=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}];function Wn(){const t=re.value;return l`
    <div class="board-sort-bar">
      ${qn.map(e=>l`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{re.value=e.id,ht()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Jn({post:t}){const e=async n=>{await En(t.id,n),ht()};return l`
    <div class="board-post" onClick=${()=>pn(t.id)}>
      <div class="board-post-votes">
        <button class="vote-btn up" onClick=${n=>{n.stopPropagation(),e("up")}}>+</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn down" onClick=${n=>{n.stopPropagation(),e("down")}}>-</button>
      </div>
      <div class="board-post-content">
        <div class="board-post-title">${t.title}</div>
        <div class="board-post-meta">
          <span class="board-post-author">${t.author}</span>
          <${$t} timestamp=${t.created_at} />
          ${t.comment_count>0?l`<span class="board-post-comments">${t.comment_count} comments</span>`:null}
        </div>
      </div>
    </div>
  `}function Kn(){const t=We.value,e=Rt.value,n=D.value.postId;if(n){const s=t.find(o=>o.id===n);return l`
      <div>
        <button class="back-btn" onClick=${()=>Oe("board")}>Back to Board</button>
        ${s?l`
            <${A} title=${s.title}>
              <div class="board-post-detail">
                <div class="board-post-body">${s.content}</div>
                <div class="board-post-meta">
                  <span>${s.author}</span>
                  <${$t} timestamp=${s.created_at} />
                  <span>${s.votes??0} votes</span>
                </div>
              </div>
            <//>
          `:l`<div class="empty-state">Post not found</div>`}
      </div>
    `}return l`
    <${Wn} />
    ${e?l`<div class="loading-indicator">Loading board...</div>`:t.length===0?l`<div class="empty-state">No posts yet</div>`:l`<div class="board-post-list">
            ${t.map(s=>l`<${Jn} key=${s.id} post=${s} />`)}
          </div>`}
  `}function zn({msg:t}){return l`
    <div class="message-row">
      <span class="message-author">${t.from??"system"}</span>
      <span class="message-content">${t.content}</span>
      <${$t} timestamp=${t.timestamp} />
    </div>
  `}function Vn(){const t=Ge.value;return l`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${t.length===0?l`<div class="empty-state">No recent activity</div>`:t.slice(0,50).map((e,n)=>l`<${zn} key=${n} msg=${e} />`)}
      </div>
    </div>
  `}function Xn({agent:t}){return l`
    <div class="agent-card ${t.status}">
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?l`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${G} status=${t.status} />
      </div>
      ${t.current_task?l`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?l`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </div>
  `}function Zn({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return l`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
          ${t.model?l`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?l`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?l`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?l`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?l`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?l`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function Qn(){const t=pt.value,e=Ft.value;return l`
    <div>
      ${e.length>0?l`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>l`<${Zn} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?l`<div class="empty-state">No agents registered</div>`:l`
            <div class="agent-grid">
              ${t.map(n=>l`<${Xn} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function wt({task:t}){return l`
    <div class="task-row">
      <${G} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?l`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?l`<${$t} timestamp=${t.created_at} />`:null}
    </div>
  `}function Yn(){const{todo:t,inProgress:e,done:n}=Ke.value;return l`
    <div class="grid-2col">
      <${A} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?l`<div class="empty-state">No tasks in progress</div>`:e.map(s=>l`<${wt} key=${s.id} task=${s} />`)}
        </div>
      <//>

      <${A} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?l`<div class="empty-state">No pending tasks</div>`:t.map(s=>l`<${wt} key=${s.id} task=${s} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?l`
        <${A} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(s=>l`<${wt} key=${s.id} task=${s} />`)}
            ${n.length>20?l`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function ts({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return l`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function es(){const t=Ct.value;return l`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?l`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>l`<${ts} key=${n} event=${e} />`)}
      </div>
    </div>
  `}function ns({actor:t}){return l`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${G} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
      </div>
      ${t.stats?l`
          <div class="trpg-actor-stats">
            <span>HP ${t.stats.hp}/${t.stats.max_hp}</span>
            <span>STR ${t.stats.strength}</span>
            <span>DEX ${t.stats.dexterity}</span>
          </div>
        `:null}
    </div>
  `}function ss({state:t}){const e=t.story_log??[];return l`
    <div class="trpg-story">
      ${e.length===0?l`<div class="empty-state">No story events yet</div>`:e.slice(-20).map((n,s)=>l`
            <div key=${s} class="trpg-event ${n.type??""}">
              ${n.dice_roll?l`<span class="trpg-dice">[${n.dice_roll.notation}: ${n.dice_roll.total}]</span>`:null}
              <span class="trpg-event-text">${n.content??""}</span>
            </div>
          `)}
    </div>
  `}function is(){var n,s,o;const t=Je.value;return Lt.value&&!t?l`<div class="loading-indicator">Loading TRPG state...</div>`:t?l`
    <div>
      <div class="stats-grid" style="margin-bottom: 20px">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size: 18px">${((n=t.session)==null?void 0:n.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((s=t.current_round)==null?void 0:s.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${((o=t.party)==null?void 0:o.length)??0}</div>
        </div>
      </div>

      <div class="grid-2col">
        <${A} title="Party" class="section">
          <div class="trpg-actor-list">
            ${(t.party??[]).map(i=>l`<${ns} key=${i.name} actor=${i} />`)}
          </div>
        <//>

        <${A} title="Story" class="section">
          <${ss} state=${t} />
        <//>
      </div>
    </div>
  `:l`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ve()}>Refresh</button>
      </div>
    `}function os(){const t=Z.value;return l`
    <div class="connection-status">
      <span class="status-dot ${t?"connected":""}"></span>
      <span class="status-text">${t?"Live":"Connecting..."}</span>
      ${At.value>0?l`<span class="event-count">${At.value} events</span>`:null}
    </div>
  `}function as(){switch(D.value.tab){case"overview":return l`<${le} />`;case"board":return l`<${Kn} />`;case"activity":return l`<${Vn} />`;case"agents":return l`<${Qn} />`;case"tasks":return l`<${Yn} />`;case"journal":return l`<${es} />`;case"trpg":return l`<${is} />`;default:return l`<${le} />`}}function rs(){return ie(()=>{hn(),Be(),Gt();const t=Hn();return On(),()=>{Tn(),t(),jn()}},[]),ie(()=>{const t=D.value.tab;t==="board"&&ht(),t==="trpg"&&Ve()},[D.value.tab]),l`
    <div class="container">
      <header>
        <h1>
          MASC Dashboard
          <span class="version-badge">SPA</span>
        </h1>
        <${os} />
      </header>

      <${mn} />

      <main>
        ${Et.value&&!Z.value?l`<div class="loading-indicator">Loading dashboard...</div>`:l`<${as} />`}
      </main>
    </div>
  `}const ce=document.getElementById("app");ce&&en(l`<${rs} />`,ce);
