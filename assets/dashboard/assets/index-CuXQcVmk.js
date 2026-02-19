(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))i(a);new MutationObserver(a=>{for(const s of a)if(s.type==="childList")for(const o of s.addedNodes)o.tagName==="LINK"&&o.rel==="modulepreload"&&i(o)}).observe(document,{childList:!0,subtree:!0});function n(a){const s={};return a.integrity&&(s.integrity=a.integrity),a.referrerPolicy&&(s.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?s.credentials="include":a.crossOrigin==="anonymous"?s.credentials="omit":s.credentials="same-origin",s}function i(a){if(a.ep)return;a.ep=!0;const s=n(a);fetch(a.href,s)}})();var kt,$,Te,Pe,M,ae,Ne,Ae,Le,Kt,jt,Ht,st={},Re=[],hn=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,wt=Array.isArray;function A(t,e){for(var n in e)t[n]=e[n];return t}function Vt(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Ee(t,e,n){var i,a,s,o={};for(s in e)s=="key"?i=e[s]:s=="ref"?a=e[s]:o[s]=e[s];if(arguments.length>2&&(o.children=arguments.length>3?kt.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(s in t.defaultProps)o[s]===void 0&&(o[s]=t.defaultProps[s]);return _t(t,o,i,a,null)}function _t(t,e,n,i,a){var s={type:t,props:e,key:n,ref:i,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Te,__i:-1,__u:0};return a==null&&$.vnode!=null&&$.vnode(s),s}function ot(t){return t.children}function X(t,e){this.props=t,this.context=e}function F(t,e){if(e==null)return t.__?F(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?F(t):null}function De(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return De(t)}}function oe(t){(!t.__d&&(t.__d=!0)&&M.push(t)&&!mt.__r++||ae!=$.debounceRendering)&&((ae=$.debounceRendering)||Ne)(mt)}function mt(){for(var t,e,n,i,a,s,o,c=1;M.length;)M.length>c&&M.sort(Ae),t=M.shift(),c=M.length,t.__d&&(n=void 0,i=void 0,a=(i=(e=t).__v).__e,s=[],o=[],e.__P&&((n=A({},i)).__v=i.__v+1,$.vnode&&$.vnode(n),Jt(e.__P,n,i,e.__n,e.__P.namespaceURI,32&i.__u?[a]:null,s,a??F(i),!!(32&i.__u),o),n.__v=i.__v,n.__.__k[n.__i]=n,He(s,n,o),i.__e=i.__=null,n.__e!=a&&De(n)));mt.__r=0}function Me(t,e,n,i,a,s,o,c,d,u,v){var l,f,p,x,C,k,g,m=i&&i.__k||Re,L=e.length;for(d=$n(n,e,m,d,L),l=0;l<L;l++)(p=n.__k[l])!=null&&(f=p.__i==-1?st:m[p.__i]||st,p.__i=l,k=Jt(t,p,f,a,s,o,c,d,u,v),x=p.__e,p.ref&&f.ref!=p.ref&&(f.ref&&Xt(f.ref,null,p),v.push(p.ref,p.__c||x,p)),C==null&&x!=null&&(C=x),(g=!!(4&p.__u))||f.__k===p.__k?d=je(p,d,t,g):typeof p.type=="function"&&k!==void 0?d=k:x&&(d=x.nextSibling),p.__u&=-7);return n.__e=C,d}function $n(t,e,n,i,a){var s,o,c,d,u,v=n.length,l=v,f=0;for(t.__k=new Array(a),s=0;s<a;s++)(o=e[s])!=null&&typeof o!="boolean"&&typeof o!="function"?(typeof o=="string"||typeof o=="number"||typeof o=="bigint"||o.constructor==String?o=t.__k[s]=_t(null,o,null,null,null):wt(o)?o=t.__k[s]=_t(ot,{children:o},null,null,null):o.constructor===void 0&&o.__b>0?o=t.__k[s]=_t(o.type,o.props,o.key,o.ref?o.ref:null,o.__v):t.__k[s]=o,d=s+f,o.__=t,o.__b=t.__b+1,c=null,(u=o.__i=mn(o,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(a>v?f--:a<v&&f++),typeof o.type!="function"&&(o.__u|=4)):u!=d&&(u==d-1?f--:u==d+1?f++:(u>d?f--:f++,o.__u|=4))):t.__k[s]=null;if(l)for(s=0;s<v;s++)(c=n[s])!=null&&(2&c.__u)==0&&(c.__e==i&&(i=F(c)),Ue(c,c));return i}function je(t,e,n,i){var a,s;if(typeof t.type=="function"){for(a=t.__k,s=0;a&&s<a.length;s++)a[s]&&(a[s].__=t,e=je(a[s],e,n,i));return e}t.__e!=e&&(i&&(e&&t.type&&!e.parentNode&&(e=F(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function mn(t,e,n,i){var a,s,o,c=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&c==null||v&&c==u.key&&d==u.type)return n;if(i>(v?1:0)){for(a=n-1,s=n+1;a>=0||s<e.length;)if((u=e[o=a>=0?a--:s++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return o}return-1}function re(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||hn.test(e)?n:n+"px"}function dt(t,e,n,i,a){var s,o;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof i=="string"&&(t.style.cssText=i=""),i)for(e in i)n&&e in n||re(t.style,e,"");if(n)for(e in n)i&&n[e]==i[e]||re(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")s=e!=(e=e.replace(Le,"$1")),o=e.toLowerCase(),e=o in t||e=="onFocusOut"||e=="onFocusIn"?o.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+s]=n,n?i?n.u=i.u:(n.u=Kt,t.addEventListener(e,s?Ht:jt,s)):t.removeEventListener(e,s?Ht:jt,s);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function le(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Kt++;else if(e.t<n.u)return;return n($.event?$.event(e):e)}}}function Jt(t,e,n,i,a,s,o,c,d,u){var v,l,f,p,x,C,k,g,m,L,E,ct,K,se,ut,V,Pt,T=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),s=[c=e.__e=n.__e]),(v=$.__b)&&v(e);t:if(typeof T=="function")try{if(g=e.props,m="prototype"in T&&T.prototype.render,L=(v=T.contextType)&&i[v.__c],E=v?L?L.props.value:v.__:i,n.__c?k=(l=e.__c=n.__c).__=l.__E:(m?e.__c=l=new T(g,E):(e.__c=l=new X(g,E),l.constructor=T,l.render=yn),L&&L.sub(l),l.state||(l.state={}),l.__n=i,f=l.__d=!0,l.__h=[],l._sb=[]),m&&l.__s==null&&(l.__s=l.state),m&&T.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=A({},l.__s)),A(l.__s,T.getDerivedStateFromProps(g,l.__s))),p=l.props,x=l.state,l.__v=e,f)m&&T.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),m&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(m&&T.getDerivedStateFromProps==null&&g!==p&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(g,E),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(g,l.__s,E)===!1){for(e.__v!=n.__v&&(l.props=g,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(I){I&&(I.__=e)}),ct=0;ct<l._sb.length;ct++)l.__h.push(l._sb[ct]);l._sb=[],l.__h.length&&o.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(g,l.__s,E),m&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(p,x,C)})}if(l.context=E,l.props=g,l.__P=t,l.__e=!1,K=$.__r,se=0,m){for(l.state=l.__s,l.__d=!1,K&&K(e),v=l.render(l.props,l.state,l.context),ut=0;ut<l._sb.length;ut++)l.__h.push(l._sb[ut]);l._sb=[]}else do l.__d=!1,K&&K(e),v=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++se<25);l.state=l.__s,l.getChildContext!=null&&(i=A(A({},i),l.getChildContext())),m&&!f&&l.getSnapshotBeforeUpdate!=null&&(C=l.getSnapshotBeforeUpdate(p,x)),V=v,v!=null&&v.type===ot&&v.key==null&&(V=Oe(v.props.children)),c=Me(t,wt(V)?V:[V],e,n,i,a,s,o,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&o.push(l),k&&(l.__E=l.__=null)}catch(I){if(e.__v=null,d||s!=null)if(I.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;s[s.indexOf(c)]=null,e.__e=c}else{for(Pt=s.length;Pt--;)Vt(s[Pt]);Ot(e)}else e.__e=n.__e,e.__k=n.__k,I.then||Ot(e);$.__e(I,e,n)}else s==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=gn(n.__e,e,n,i,a,s,o,d,u);return(v=$.diffed)&&v(e),128&e.__u?void 0:c}function Ot(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Ot)}function He(t,e,n){for(var i=0;i<n.length;i++)Xt(n[i],n[++i],n[++i]);$.__c&&$.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(s){s.call(a)})}catch(s){$.__e(s,a.__v)}})}function Oe(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:wt(t)?t.map(Oe):A({},t)}function gn(t,e,n,i,a,s,o,c,d){var u,v,l,f,p,x,C,k=n.props||st,g=e.props,m=e.type;if(m=="svg"?a="http://www.w3.org/2000/svg":m=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),s!=null){for(u=0;u<s.length;u++)if((p=s[u])&&"setAttribute"in p==!!m&&(m?p.localName==m:p.nodeType==3)){t=p,s[u]=null;break}}if(t==null){if(m==null)return document.createTextNode(g);t=document.createElementNS(a,m,g.is&&g),c&&($.__m&&$.__m(e,s),c=!1),s=null}if(m==null)k===g||c&&t.data==g||(t.data=g);else{if(s=s&&kt.call(t.childNodes),!c&&s!=null)for(k={},u=0;u<t.attributes.length;u++)k[(p=t.attributes[u]).name]=p.value;for(u in k)if(p=k[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=p;else if(!(u in g)){if(u=="value"&&"defaultValue"in g||u=="checked"&&"defaultChecked"in g)continue;dt(t,u,null,p,a)}}for(u in g)p=g[u],u=="children"?f=p:u=="dangerouslySetInnerHTML"?v=p:u=="value"?x=p:u=="checked"?C=p:c&&typeof p!="function"||k[u]===p||dt(t,u,p,k[u],a);if(v)c||l&&(v.__html==l.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(l&&(t.innerHTML=""),Me(e.type=="template"?t.content:t,wt(f)?f:[f],e,n,i,m=="foreignObject"?"http://www.w3.org/1999/xhtml":a,s,o,s?s[0]:n.__k&&F(n,0),c,d),s!=null)for(u=s.length;u--;)Vt(s[u]);c||(u="value",m=="progress"&&x==null?t.removeAttribute("value"):x!=null&&(x!==t[u]||m=="progress"&&!x||m=="option"&&x!=k[u])&&dt(t,u,x,k[u],a),u="checked",C!=null&&C!=t[u]&&dt(t,u,C,k[u],a))}return t}function Xt(t,e,n){try{if(typeof t=="function"){var i=typeof t.__u=="function";i&&t.__u(),i&&e==null||(t.__u=t(e))}else t.current=e}catch(a){$.__e(a,n)}}function Ue(t,e,n){var i,a;if($.unmount&&$.unmount(t),(i=t.ref)&&(i.current&&i.current!=t.__e||Xt(i,null,e)),(i=t.__c)!=null){if(i.componentWillUnmount)try{i.componentWillUnmount()}catch(s){$.__e(s,e)}i.base=i.__P=null}if(i=t.__k)for(a=0;a<i.length;a++)i[a]&&Ue(i[a],e,n||typeof t.type!="function");n||Vt(t.__e),t.__c=t.__=t.__e=void 0}function yn(t,e,n){return this.constructor(t,n)}function bn(t,e,n){var i,a,s,o;e==document&&(e=document.documentElement),$.__&&$.__(t,e),a=(i=!1)?null:e.__k,s=[],o=[],Jt(e,t=e.__k=Ee(ot,null,[t]),a||st,st,e.namespaceURI,a?null:e.firstChild?kt.call(e.childNodes):null,s,a?a.__e:e.firstChild,i,o),He(s,t,o)}kt=Re.slice,$={__e:function(t,e,n,i){for(var a,s,o;e=e.__;)if((a=e.__c)&&!a.__)try{if((s=a.constructor)&&s.getDerivedStateFromError!=null&&(a.setState(s.getDerivedStateFromError(t)),o=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,i||{}),o=a.__d),o)return a.__E=a}catch(c){t=c}throw t}},Te=0,Pe=function(t){return t!=null&&t.constructor===void 0},X.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=A({},this.state),typeof t=="function"&&(t=t(A({},n),this.props)),t&&A(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),oe(this))},X.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),oe(this))},X.prototype.render=ot,M=[],Ne=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ae=function(t,e){return t.__v.__b-e.__v.__b},mt.__r=0,Le=/(PointerCapture)$|Capture$/i,Kt=0,jt=le(!1),Ht=le(!0);var Ie=function(t,e,n,i){var a;e[0]=0;for(var s=1;s<e.length;s++){var o=e[s++],c=e[s]?(e[0]|=o?1:2,n[e[s++]]):e[++s];o===3?i[0]=c:o===4?i[1]=Object.assign(i[1]||{},c):o===5?(i[1]=i[1]||{})[e[++s]]=c:o===6?i[1][e[++s]]+=c+"":o?(a=t.apply(c,Ie(t,c,n,["",null])),i.push(a),c[0]?e[0]|=2:(e[s-2]=0,e[s]=a)):i.push(c)}return i},ce=new Map;function xn(t){var e=ce.get(this);return e||(e=new Map,ce.set(this,e)),(e=Ie(this,e.get(t)||(e.set(t,e=(function(n){for(var i,a,s=1,o="",c="",d=[0],u=function(f){s===1&&(f||(o=o.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,f,o):s===3&&(f||o)?(d.push(3,f,o),s=2):s===2&&o==="..."&&f?d.push(4,f,0):s===2&&o&&!f?d.push(5,0,!0,o):s>=5&&((o||!f&&s===5)&&(d.push(s,0,o,a),s=6),f&&(d.push(s,f,0,a),s=6)),o=""},v=0;v<n.length;v++){v&&(s===1&&u(),u(v));for(var l=0;l<n[v].length;l++)i=n[v][l],s===1?i==="<"?(u(),d=[d],s=3):o+=i:s===4?o==="--"&&i===">"?(s=1,o=""):o=i+o[0]:c?i===c?c="":o+=i:i==='"'||i==="'"?c=i:i===">"?(u(),s=1):s&&(i==="="?(s=5,a=o,o=""):i==="/"&&(s<5||n[v][l+1]===">")?(u(),s===3&&(d=d[0]),s=d,(d=d[0]).push(2,0,s),s=0):i===" "||i==="	"||i===`
`||i==="\r"?(u(),s=2):o+=i),s===3&&o==="!--"&&(s=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var r=xn.bind(Ee),gt,S,Nt,ue,de=0,ze=[],y=$,ve=y.__b,pe=y.__r,fe=y.diffed,_e=y.__c,he=y.unmount,$e=y.__;function Be(t,e){y.__h&&y.__h(S,t,de||e),de=0;var n=S.__H||(S.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function me(t,e){var n=Be(gt++,3);!y.__s&&qe(n.__H,e)&&(n.__=t,n.u=e,S.__H.__h.push(n))}function Fe(t,e){var n=Be(gt++,7);return qe(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function kn(){for(var t;t=ze.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ht),t.__H.__h.forEach(Ut),t.__H.__h=[]}catch(e){t.__H.__h=[],y.__e(e,t.__v)}}y.__b=function(t){S=null,ve&&ve(t)},y.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),$e&&$e(t,e)},y.__r=function(t){pe&&pe(t),gt=0;var e=(S=t.__c).__H;e&&(Nt===S?(e.__h=[],S.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ht),e.__h.forEach(Ut),e.__h=[],gt=0)),Nt=S},y.diffed=function(t){fe&&fe(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(ze.push(e)!==1&&ue===y.requestAnimationFrame||((ue=y.requestAnimationFrame)||wn)(kn)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Nt=S=null},y.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ht),n.__h=n.__h.filter(function(i){return!i.__||Ut(i)})}catch(i){e.some(function(a){a.__h&&(a.__h=[])}),e=[],y.__e(i,n.__v)}}),_e&&_e(t,e)},y.unmount=function(t){he&&he(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(i){try{ht(i)}catch(a){e=a}}),n.__H=void 0,e&&y.__e(e,n.__v))};var ge=typeof requestAnimationFrame=="function";function wn(t){var e,n=function(){clearTimeout(i),ge&&cancelAnimationFrame(e),setTimeout(t)},i=setTimeout(n,35);ge&&(e=requestAnimationFrame(n))}function ht(t){var e=S,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),S=e}function Ut(t){var e=S;t.__c=t.__(),S=e}function qe(t,e){return!t||t.length!==e.length||e.some(function(n,i){return n!==t[i]})}var Sn=Symbol.for("preact-signals");function St(){if(R>1)R--;else{for(var t,e=!1;Z!==void 0;){var n=Z;for(Z=void 0,It++;n!==void 0;){var i=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ke(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=i}}if(It=0,R--,e)throw t}}function Cn(t){if(R>0)return t();R++;try{return t()}finally{St()}}var _=void 0;function We(t){var e=_;_=void 0;try{return t()}finally{_=e}}var Z=void 0,R=0,It=0,yt=0;function Ge(t){if(_!==void 0){var e=t.n;if(e===void 0||e.t!==_)return e={i:0,S:t,p:_.s,n:void 0,t:_,e:void 0,x:void 0,r:e},_.s!==void 0&&(_.s.n=e),_.s=e,t.n=e,32&_.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=_.s,e.n=void 0,_.s.n=e,_.s=e),e}}function w(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}w.prototype.brand=Sn;w.prototype.h=function(){return!0};w.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:We(function(){var i;(i=e.W)==null||i.call(e)}))};w.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,i=t.x;n!==void 0&&(n.x=i,t.e=void 0),i!==void 0&&(i.e=n,t.x=void 0),t===this.t&&(this.t=i,i===void 0&&We(function(){var a;(a=e.Z)==null||a.call(e)}))}};w.prototype.subscribe=function(t){var e=this;return rt(function(){var n=e.value,i=_;_=void 0;try{t(n)}finally{_=i}},{name:"sub"})};w.prototype.valueOf=function(){return this.value};w.prototype.toString=function(){return this.value+""};w.prototype.toJSON=function(){return this.value};w.prototype.peek=function(){var t=_;_=void 0;try{return this.value}finally{_=t}};Object.defineProperty(w.prototype,"value",{get:function(){var t=Ge(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(It>100)throw new Error("Cycle detected");this.v=t,this.i++,yt++,R++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{St()}}}});function h(t,e){return new w(t,e)}function Ke(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ve(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Je(t){for(var e=t.s,n=void 0;e!==void 0;){var i=e.p;e.i===-1?(e.S.U(e),i!==void 0&&(i.n=e.n),e.n!==void 0&&(e.n.p=i)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=i}t.s=n}function H(t,e){w.call(this,void 0),this.x=t,this.s=void 0,this.g=yt-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}H.prototype=new w;H.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===yt))return!0;if(this.g=yt,this.f|=1,this.i>0&&!Ke(this))return this.f&=-2,!0;var t=_;try{Ve(this),_=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return _=t,Je(this),this.f&=-2,!0};H.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}w.prototype.S.call(this,t)};H.prototype.U=function(t){if(this.t!==void 0&&(w.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};H.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(H.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ge(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function bt(t,e){return new H(t,e)}function Xe(t){var e=t.u;if(t.u=void 0,typeof e=="function"){R++;var n=_;_=void 0;try{e()}catch(i){throw t.f&=-2,t.f|=8,Zt(t),i}finally{_=n,St()}}}function Zt(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Xe(t)}function Tn(t){if(_!==this)throw new Error("Out-of-order effect");Je(this),_=t,this.f&=-2,8&this.f&&Zt(this),St()}function q(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}q.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};q.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Xe(this),Ve(this),R++;var t=_;return _=this,Tn.bind(this,t)};q.prototype.N=function(){2&this.f||(this.f|=2,this.o=Z,Z=this)};q.prototype.d=function(){this.f|=8,1&this.f||Zt(this)};q.prototype.dispose=function(){this.d()};function rt(t,e){var n=new q(t,e);try{n.c()}catch(a){throw n.d(),a}var i=n.d.bind(n);return i[Symbol.dispose]=i,i}var Ze,vt,Pn=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Qe=[];rt(function(){Ze=this.N})();function W(t,e){$[t]=e.bind(null,$[t]||function(){})}function xt(t){if(vt){var e=vt;vt=void 0,e()}vt=t&&t.S()}function Ye(t){var e=this,n=t.data,i=An(n);i.value=n;var a=Fe(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=bt(function(){var p=i.value.value;return p===0?0:p===!0?"":p||""}),v=bt(function(){return!Array.isArray(u.value)&&!Pe(u.value)}),l=rt(function(){if(this.N=tn,v.value){var p=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=p)}}),f=e.__$u.d;return e.__$u.d=function(){l(),f.call(this)},[v,u]},[]),s=a[0],o=a[1];return s.value?o.peek():o.value}Ye.displayName="ReactiveTextNode";Object.defineProperties(w.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ye},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});W("__b",function(t,e){if(typeof e.type=="string"){var n,i=e.props;for(var a in i)if(a!=="children"){var s=i[a];s instanceof w&&(n||(e.__np=n={}),n[a]=s,i[a]=s.peek())}}t(e)});W("__r",function(t,e){if(t(e),e.type!==ot){xt();var n,i=e.__c;i&&(i.__$f&=-2,(n=i.__$u)===void 0&&(i.__$u=n=(function(a,s){var o;return rt(function(){o=this},{name:s}),o.c=a,o})(function(){var a;Pn&&((a=n.y)==null||a.call(n)),i.__$f|=1,i.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),xt(n)}});W("__e",function(t,e,n,i){xt(),t(e,n,i)});W("diffed",function(t,e){xt();var n;if(typeof e.type=="string"&&(n=e.__e)){var i=e.__np,a=e.props;if(i){var s=n.U;if(s)for(var o in s){var c=s[o];c!==void 0&&!(o in i)&&(c.d(),s[o]=void 0)}else s={},n.U=s;for(var d in i){var u=s[d],v=i[d];u===void 0?(u=Nn(n,d,v),s[d]=u):u.o(v,a)}for(var l in i)a[l]=i[l]}}t(e)});function Nn(t,e,n,i){var a=e in t&&t.ownerSVGElement===void 0,s=h(n),o=n.peek();return{o:function(c,d){s.value=c,o=c.peek()},d:rt(function(){this.N=tn;var c=s.value.value;o!==c?(o=void 0,a?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):o=void 0})}}W("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var i=n.U;if(i){n.U=void 0;for(var a in i){var s=i[a];s&&s.d()}}}e.__np=void 0}else{var o=e.__c;if(o){var c=o.__$u;c&&(o.__$u=void 0,c.d())}}t(e)});W("__h",function(t,e,n,i){(i<3||i===9)&&(e.__$f|=2),t(e,n,i)});X.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,i=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var s=2&this.__$f;if(!(i||s||4&this.__$f)||1&this.__$f)return!0}else if(!(i||4&this.__$f)||3&this.__$f)return!0;for(var o in t)if(o!=="__source"&&t[o]!==this.props[o])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function An(t,e){return Fe(function(){return h(t,e)},[])}var Ln=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Rn(){Cn(function(){for(var t;t=Qe.shift();)Ze.call(t)})}function tn(){Qe.push(this)===1&&($.requestAnimationFrame||Ln)(Rn)}const En=["overview","board","activity","agents","tasks","journal","trpg"];function Qt(t){const e=(t||"").replace(/^#/,"");if(!e)return{tab:"overview",params:{},postId:null};const[n,i]=e.split("?"),a=n.split("/"),s=En.includes(a[0])?a[0]:"overview";let o=null;a[0]==="board"&&a[1]==="post"&&a[2]&&(o=a[2]);const c={};return i&&new URLSearchParams(i).forEach((u,v)=>{c[v]=u}),{tab:s,params:c,postId:o}}const j=h(Qt(window.location.hash));window.addEventListener("hashchange",()=>{j.value=Qt(window.location.hash)});function Yt(t,e){let n=`#${t}`;window.location.hash=n}function Dn(t){window.location.hash=`#board/post/${t}`}function Mn(){(!window.location.hash||window.location.hash==="#")&&(window.location.hash="#overview"),j.value=Qt(window.location.hash)}const jn=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Hn(){const t=j.value.tab;return r`
    <div class="main-tab-bar">
      ${jn.map(e=>r`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Yt(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const ye="masc_dashboard_sse_session_id",On=1e3,Un=15e3,at=h(!1),zt=h(0),en=h(null),Bt=h([]);function In(){let t=sessionStorage.getItem(ye);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ye,t)),t}const zn=200;function D(t,e){const n={agent:t,text:e,timestamp:Date.now()};Bt.value=[n,...Bt.value].slice(0,zn)}let P=null,B=null,Ft=0;function nn(){B&&(clearTimeout(B),B=null)}function Bn(){if(B)return;Ft++;const t=Math.min(Ft,5),e=Math.min(Un,On*Math.pow(2,t));B=setTimeout(()=>{B=null,sn()},e)}function sn(){nn(),P&&(P.close(),P=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),i=t.get("token");n&&e.set("agent",n),i&&e.set("token",i),e.set("session_id",In());const a=e.toString()?`/sse?${e.toString()}`:"/sse",s=new EventSource(a);P=s,s.onopen=()=>{P===s&&(Ft=0,at.value=!0)},s.onerror=()=>{P===s&&(at.value=!1,s.close(),P=null,Bn())},s.onmessage=o=>{try{const c=JSON.parse(o.data);zt.value++,en.value=c,Fn(c)}catch{}}}function Fn(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":D(n,"Joined");break;case"agent_left":D(n,"Left");break;case"broadcast":D(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":D(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":D(n,"New post");break;case"board_comment":D(n,"New comment");break;default:D(n,e)}}function qn(){nn(),P&&(P.close(),P=null),at.value=!1}function Wn(){return new URLSearchParams(window.location.search)}function an(){const t=Wn(),e={},n=t.get("token"),i=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),i&&(e["X-MASC-Agent"]=i),e}function Gn(){return{...an(),"Content-Type":"application/json"}}async function Ct(t){const e=await fetch(t,{headers:an()});if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function lt(t,e){const n=await fetch(t,{method:"POST",headers:Gn(),body:JSON.stringify(e)});if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}function Kn(){return Ct("/api/v1/dashboard")}function Vn(){return Ct("/api/v1/board")}function Jn(t){return Ct(`/api/v1/board/${t}`)}function on(t,e){return lt(`/api/v1/board/${t}/vote`,{direction:e})}function Xn(t,e,n){return lt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Zn(t){const e=t?`?room=${encodeURIComponent(t)}`:"";return Ct(`/api/v1/trpg/state${e}`)}function Qn(t){return lt("/api/v1/trpg/rounds/run",{room:t})}function Yn(t,e){return lt("/api/v1/trpg/dice/roll",{room:t,notation:e})}function ti(t){return lt("/api/v1/trpg/turns/advance",{room:t})}const Tt=h([]),te=h([]),rn=h([]),ee=h([]),ln=h(null),J=h(null),cn=h([]),be=h("hot"),un=h(null),dn=h(""),qt=h(!1),Wt=h(!1),Gt=h(!1),ei=bt(()=>Tt.value.filter(t=>t.status==="active"||t.status==="idle")),vn=bt(()=>{const t=te.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let $t=null;const ni=5e3;function pn(){$t=null}function ii(t){return Array.isArray(t)?t:t&&Array.isArray(t.keepers)?t.keepers:[]}async function ne(){var e,n,i;const t=Date.now();if(!($t&&t-$t.time<ni)){qt.value=!0;try{const a=await Kn();$t={data:a,time:t},Tt.value=((e=a.agents)==null?void 0:e.agents)??[],te.value=((n=a.tasks)==null?void 0:n.tasks)??[],rn.value=((i=a.messages)==null?void 0:i.messages)??[],ee.value=ii(a.keepers),ln.value=a.status??null,J.value=a.perpetual??null}catch(a){console.error("Dashboard fetch error:",a)}finally{qt.value=!1}}}async function G(){Wt.value=!0;try{const t=await Vn();cn.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Wt.value=!1}}async function Q(){Gt.value=!0;try{const t=dn.value||void 0,e=await Zn(t);un.value=e}catch(t){console.error("TRPG fetch error:",t)}finally{Gt.value=!1}}let At=null,Lt=null;function si(){return en.subscribe(e=>{e&&(pn(),At||(At=setTimeout(()=>{ne(),At=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Lt||(Lt=setTimeout(()=>{G(),Lt=null},500))))})}let Y=null;function ai(){Y||(Y=setInterval(()=>{pn(),ne()},1e4))}function oi(){Y&&(clearInterval(Y),Y=null)}function b({title:t,class:e,children:n}){return r`
    <div class="card ${e??""}">
      ${t?r`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function O({status:t,label:e}){return r`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function z({label:t,value:e,color:n}){return r`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function ri({agent:t}){return r`
    <div class="agent">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${O} status=${t.status} />
      ${t.current_task?r`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function li({keeper:t}){return r`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${O} status=${t.status} />
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>
        ${t.generation!=null?r`<div class="live-agent-meta">
              <span>Gen ${t.generation}</span>
              <span>Turn ${t.turn_count??0}</span>
              ${t.context_ratio!=null?r`<span class=${t.context_ratio>.7?"warn-metric":""}>
                    Ctx ${Math.round(t.context_ratio*100)}%
                  </span>`:null}
            </div>`:null}
      </div>
    </div>
  `}function xe(){const t=ln.value,e=Tt.value,n=ee.value,i=vn.value;return r`
    <div class="stats-grid">
      <${z} label="Agents" value=${e.length} />
      <${z} label="Active" value=${ei.value.length} color="#4ade80" />
      <${z} label="Keepers" value=${n.length} color="#22d3ee" />
      <${z} label="Tasks" value=${te.value.length} />
      <${z} label="In Progress" value=${i.inProgress.length} color="#fbbf24" />
      <${z} label="Done" value=${i.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?r`<div class="empty-state">No agents connected</div>`:e.map(a=>r`<${ri} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?r`<div class="empty-state">No keepers active</div>`:n.map(a=>r`<${li} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${J.value?r`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${J.value.running?"Running":"Stopped"}</span>
            ${J.value.goal?r`<span>Goal: ${J.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?r`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${ci(t.uptime_seconds)}</span>
          </div>
        <//>
      `:null}
  `}function ci(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ui(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),i=Math.floor((e-n)/1e3);if(i<60)return`${i}s ago`;const a=Math.floor(i/60);if(a<60)return`${a}m ago`;const s=Math.floor(a/60);return s<24?`${s}h ago`:`${Math.floor(s/24)}d ago`}function U({timestamp:t}){const e=ui(t);return r`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}function di({text:t}){if(!t)return null;const e=vi(t);return r`<div class="markdown-content">${e}</div>`}function vi(t){const e=t.split(`
`),n=[];let i=0;for(;i<e.length;){const a=e[i];if(/^(`{3,}|~{3,})/.test(a)){const o=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(o.length).trim(),d=[];for(i++;i<e.length&&!e[i].startsWith(o);)d.push(e[i]),i++;i++,n.push(r`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const o=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&o.push(c),i++;i<e.length&&!e[i].includes("</think>");)o.push(e[i]),i++;if(i<e.length){const u=e[i].replace("</think>","").trim();u&&o.push(u),i++}const d=o.join(`
`).trim();n.push(r`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Rt(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const o=[];for(;i<e.length&&e[i].startsWith("> ");)o.push(e[i].slice(2)),i++;n.push(r`<blockquote>${Rt(o.join(`
`))}</blockquote>`);continue}if(a.trim()===""){i++;continue}const s=[];for(;i<e.length;){const o=e[i];if(o.trim()===""||/^(`{3,}|~{3,})/.test(o)||o.startsWith("> ")||o.trim().startsWith("<think>"))break;s.push(o),i++}s.length>0&&n.push(r`<p>${Rt(s.join(`
`))}</p>`)}return n}function Rt(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let i=0,a;for(;(a=n.exec(t))!==null;){if(a.index>i&&e.push(t.slice(i,a.index)),a[1]){const s=a[1].slice(1,-1);e.push(r`<code>${s}</code>`)}else if(a[2]){const s=a[2].slice(2,-2);e.push(r`<strong>${s}</strong>`)}else if(a[3]){const s=a[3].slice(1,-1);e.push(r`<em>${s}</em>`)}else a[4]&&a[5]&&e.push(r`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);i=a.index+a[0].length}return i<t.length&&e.push(t.slice(i)),e.length>0?e:[t]}let pi=0;const pt=h([]);function N(t,e="success",n=4e3){const i=++pi;pt.value=[...pt.value,{id:i,message:t,type:e}],setTimeout(()=>{pt.value=pt.value.filter(a=>a.id!==i)},n)}const fi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],tt=h([]),et=h(!1),nt=h(""),_i=h("dashboard-user"),it=h(!1);async function fn(t){et.value=!0,tt.value=[];try{const e=await Jn(t);tt.value=e.comments??[]}catch{}finally{et.value=!1}}async function ke(t){const e=nt.value.trim();if(e){it.value=!0;try{await Xn(t,_i.value,e),nt.value="",N("Comment posted","success"),await fn(t),G()}catch{N("Failed to post comment","error")}finally{it.value=!1}}}function hi(){const t=be.value;return r`
    <div class="board-controls">
      ${fi.map(e=>r`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{be.value=e.id,G()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function _n({flair:t}){return t?r`<span class="post-flair ${t}">${t}</span>`:null}function $i({post:t}){const e=async(n,i)=>{i.stopPropagation(),await on(t.id,n),G()};return r`
    <div class="board-post" onClick=${()=>Dn(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${_n} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${U} timestamp=${t.created_at} />
          ${t.comment_count>0?r`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function mi({comments:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No comments yet</div>`:r`
    <div class="comment-thread">
      ${t.map(e=>r`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${U} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function gi({postId:t}){return r`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${nt.value}
        onInput=${e=>{nt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ke(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${it.value}
      />
      <button
        onClick=${()=>ke(t)}
        disabled=${it.value||nt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${it.value?"...":"Post"}
      </button>
    </div>
  `}function yi({post:t}){tt.value.length===0&&!et.value&&fn(t.id);const e=async n=>{await on(t.id,n),G()};return r`
    <div>
      <button class="back-btn" onClick=${()=>Yt("board")}>← Back to Board</button>
      <${b} title=${r`${t.title} <${_n} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${di} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${U} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?r`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${et.value?"...":tt.value.length})">
        ${et.value?r`<div class="loading-indicator">Loading comments...</div>`:r`<${mi} comments=${tt.value} />`}
        <${gi} postId=${t.id} />
      <//>
    </div>
  `}function bi(){const t=cn.value,e=Wt.value,n=j.value.postId;if(n){const i=t.find(a=>a.id===n);return i?r`<${yi} post=${i} />`:r`
          <div>
            <button class="back-btn" onClick=${()=>Yt("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return r`
    <${hi} />
    ${e?r`<div class="loading-indicator">Loading board...</div>`:t.length===0?r`<div class="empty-state">No posts yet</div>`:r`<div class="board-post-list">
            ${t.map(i=>r`<${$i} key=${i.id} post=${i} />`)}
          </div>`}
  `}function xi({msg:t}){return r`
    <div class="message-row">
      <span class="message-author">${t.from??"system"}</span>
      <span class="message-content">${t.content}</span>
      <${U} timestamp=${t.timestamp} />
    </div>
  `}function ki(){const t=rn.value;return r`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${t.length===0?r`<div class="empty-state">No recent activity</div>`:t.slice(0,50).map((e,n)=>r`<${xi} key=${n} msg=${e} />`)}
      </div>
    </div>
  `}const ie=h(null);function wi(t){ie.value=t}function we(){ie.value=null}function Si({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return r`
    <div class="keeper-kpis">
      ${e.map(n=>r`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?r`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function Ci({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),i=n>80?"bad":n>60?"warn":"";return r`
    <div class="keeper-chart-card">
      <div class="keeper-chart-container" style="display: flex; align-items: flex-end; gap: 2px; padding: 0 20px;">
        <div style="flex:1; background: rgba(74,222,128,0.3); height: ${Math.min(n,100)}%; border-radius: 4px 4px 0 0; min-height: 4px; transition: height 0.3s;" />
        <div style="flex:1; background: rgba(255,255,255,0.06); height: 100%; border-radius: 4px 4px 0 0;" />
      </div>
      <div class="keeper-chart-meta">
        Context usage: <span class=${i}>${n}%</span>
        ${n>70?r` — <span class="warn">Compaction soon</span>`:null}
        ${n>85?r` — <span class="bad">Handoff imminent</span>`:null}
      </div>
    </div>
  `}const Et=h("");function Ti({keeper:t}){var a,s;const e=Et.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((s=t.interests)==null?void 0:s.join(", "))||"-"}],i=e?n.filter(o=>o.title.toLowerCase().includes(e)||o.key.includes(e)||o.value.toLowerCase().includes(e)):n;return r`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Et.value}
        onInput=${o=>{Et.value=o.target.value}}
      />
      ${i.map(o=>r`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${o.title}</span>
          <span class="keeper-field-key">${o.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${o.value}</span>
        </div>
      `)}
    </div>
  `}function Pi({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return r`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(i=>r`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${i.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${i.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Ni({items:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No equipment</div>`:r`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>r`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Ai({rels:t}){const e=Object.entries(t);return e.length===0?r`<div class="empty-state" style="font-size:13px">No relationships</div>`:r`
    <div class="keeper-k2k-list">
      ${e.map(([n,i])=>r`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${i}</span>
        </div>
      `)}
    </div>
  `}function Se({traits:t,label:e}){return t.length===0?null:r`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>r`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Li(){const t=ie.value;return t?r`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${e=>{e.target.classList.contains("keeper-detail-overlay")&&we()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?r`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${O} status=${t.status} />
            ${t.model?r`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>we()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Si} keeper=${t} />

        ${""}
        <${Ci} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Ti} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Se} traits=${t.traits??[]} label="Traits" />
            <${Se} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?r`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.last_heartbeat?r`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${U} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?r`
              <${b} title="TRPG Stats">
                <${Pi} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?r`
              <${b} title="Equipment (${t.inventory.length})">
                <${Ni} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?r`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${Ai} rels=${t.relationships} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `:null}function Ri({agent:t}){return r`
    <div class="agent-card ${t.status}">
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?r`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${O} status=${t.status} />
      </div>
      ${t.current_task?r`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?r`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </div>
  `}function Ei({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return r`
    <div class="live-agent keeper-card" onClick=${()=>wi(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${O} status=${t.status} />
          ${t.model?r`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?r`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?r`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?r`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?r`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?r`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function Di(){const t=Tt.value,e=ee.value;return r`
    <div>
      ${e.length>0?r`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>r`<${Ei} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?r`<div class="empty-state">No agents registered</div>`:r`
            <div class="agent-grid">
              ${t.map(n=>r`<${Ri} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Dt({task:t}){return r`
    <div class="task-row">
      <${O} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?r`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?r`<${U} timestamp=${t.created_at} />`:null}
    </div>
  `}function Mi(){const{todo:t,inProgress:e,done:n}=vn.value;return r`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?r`<div class="empty-state">No tasks in progress</div>`:e.map(i=>r`<${Dt} key=${i.id} task=${i} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?r`<div class="empty-state">No pending tasks</div>`:t.map(i=>r`<${Dt} key=${i.id} task=${i} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?r`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(i=>r`<${Dt} key=${i.id} task=${i} />`)}
            ${n.length>20?r`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function ji({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",i=t.message??t.content??t.status??"";return r`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${i}</span>
    </div>
  `}function Hi(){const t=Bt.value;return r`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?r`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>r`<${ji} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Mt=h("1d20"),ft=h("idle");function Oi(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ui(t,e){return e>0?Math.round(t/e*100):0}function Ii({hp:t,max:e}){const n=Ui(t,e),i=Oi(t,e);return r`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${i}" style="width:${n}%" />
    </div>
  `}function zi({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return r`
    <div class="trpg-actor-stats">
      ${e.map(n=>r`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Bi({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return r`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Fi({actor:t}){return r`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${O} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${Bi} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?r`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?r`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ii} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${zi} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function qi({mapStr:t}){return r`<pre class="trpg-map">${t}</pre>`}function Wi({events:t}){return t.length===0?r`<div class="empty-state" style="font-size:13px">No story events yet</div>`:r`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var i;return r`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?r`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?r`<span class="trpg-dice">[${e.dice_roll.notation}: ${(i=e.dice_roll.rolls)==null?void 0:i.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${U} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Gi({state:t}){const e=t.history??[];return e.length===0?null:r`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>r`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Ki({state:t}){var o;const e=dn.value||((o=t.session)==null?void 0:o.room)||"",n=ft.value,i=async()=>{if(!e){N("No room set","error");return}ft.value="running";try{await Qn(e),ft.value="ok",N("Round executed","success"),Q()}catch{ft.value="error",N("Round failed","error")}},a=async()=>{if(e)try{await ti(e),N("Turn advanced","success"),Q()}catch{N("Advance failed","error")}},s=async()=>{const c=Mt.value.trim();if(!(!e||!c))try{await Yn(e,c),N(`Rolled ${c}`,"success"),Q()}catch{N("Dice roll failed","error")}};return r`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:flex; gap:4px;">
            <input
              type="text"
              value=${Mt.value}
              onInput=${c=>{Mt.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&s()}}
              placeholder="1d20+3"
              style="flex:1;"
            />
            <button class="trpg-run-btn secondary" onClick=${s}>Roll</button>
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button
              class="trpg-run-btn recommend"
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${a}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?r`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function Vi({state:t}){var n;const e=t.current_round;return e?r`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?r`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ji(){var a,s;const t=un.value;if(Gt.value&&!t)return r`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return r`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Q()}>Refresh</button>
      </div>
    `;const n=t.party??[],i=t.story_log??[];return r`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((a=t.session)==null?void 0:a.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((s=t.current_round)==null?void 0:s.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${i.length}</div>
        </div>
      </div>

      ${""}
      <${Vi} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${i.length})">
            <${Wi} events=${i} />
          <//>

          ${""}
          ${t.map?r`
              <${b} title="Map" style="margin-top:16px;">
                <${qi} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${Ki} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(o=>r`<${Fi} key=${o.id??o.name} actor=${o} />`)}
              ${n.length===0?r`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?r`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${Gi} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}function Xi(){const t=at.value;return r`
    <div class="connection-status">
      <span class="status-dot ${t?"connected":""}"></span>
      <span class="status-text">${t?"Live":"Connecting..."}</span>
      ${zt.value>0?r`<span class="event-count">${zt.value} events</span>`:null}
    </div>
  `}function Zi(){switch(j.value.tab){case"overview":return r`<${xe} />`;case"board":return r`<${bi} />`;case"activity":return r`<${ki} />`;case"agents":return r`<${Di} />`;case"tasks":return r`<${Mi} />`;case"journal":return r`<${Hi} />`;case"trpg":return r`<${Ji} />`;default:return r`<${xe} />`}}function Qi(){return me(()=>{Mn(),sn(),ne();const t=si();return ai(),()=>{qn(),t(),oi()}},[]),me(()=>{const t=j.value.tab;t==="board"&&G(),t==="trpg"&&Q()},[j.value.tab]),r`
    <div class="container">
      <header>
        <h1>
          MASC Dashboard
          <span class="version-badge">SPA</span>
        </h1>
        <${Xi} />
      </header>

      <${Hn} />

      <main>
        ${qt.value&&!at.value?r`<div class="loading-indicator">Loading dashboard...</div>`:r`<${Zi} />`}
      </main>

      <${Li} />
    </div>
  `}const Ce=document.getElementById("app");Ce&&bn(r`<${Qi} />`,Ce);
