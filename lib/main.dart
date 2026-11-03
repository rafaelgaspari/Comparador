import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------

const String kUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

const String kDefaultCep = '13807-646';

String _enc(String q) => Uri.encodeQueryComponent(q);

class Store {
  final String id;
  final String name;
  final Color color;

  /// vtex = sites FastStore/VTEX (Atacadão, Pague Menos)
  /// goodbom = Mercafacil
  /// generic = detecção genérica de cards com preço (Tenda)
  final String mode;
  final String home;
  final String Function(String query) searchUrl;

  const Store({
    required this.id,
    required this.name,
    required this.color,
    required this.mode,
    required this.home,
    required this.searchUrl,
  });

  /// Sites em que o preço depende de CEP/loja escolhidos no próprio site.
  bool get needsLocation => mode == 'vtex';

  /// Ícone do site (favicon), servido pelo Google.
  String get logoUrl =>
      'https://www.google.com/s2/favicons?domain=${Uri.parse(home).host}&sz=128';
}

final List<Store> kStores = [
  Store(
    id: 'goodbom',
    name: 'Good Bom',
    color: const Color(0xFF2E7D32),
    mode: 'goodbom',
    home: 'https://www.goodbom.com.br/goodbom-mogi-mirim-sp',
    searchUrl: (q) =>
        'https://www.goodbom.com.br/goodbom-mogi-mirim-sp/busca?q=${_enc(q)}',
  ),
  Store(
    id: 'tenda',
    name: 'Tenda',
    color: const Color(0xFF1E3469),
    mode: 'generic',
    home: 'https://www.tendaatacado.com.br/',
    searchUrl: (q) => 'https://www.tendaatacado.com.br/busca?q=${_enc(q)}',
  ),
  Store(
    id: 'atacadao',
    name: 'Atacadão',
    color: const Color(0xFFE65100),
    mode: 'vtex',
    home: 'https://www.atacadao.com.br/',
    searchUrl: (q) =>
        'https://www.atacadao.com.br/s?q=${_enc(q)}&sort=score_desc&page=0',
  ),
  Store(
    id: 'paguemenos',
    name: 'Pague Menos',
    color: const Color(0xFFC62828),
    mode: 'vtex',
    home: 'https://www.superpaguemenos.com.br/',
    searchUrl: (q) =>
        'https://www.superpaguemenos.com.br/s?q=${_enc(q)}&sort=score_desc&page=0',
  ),
];

// ---------------------------------------------------------------------------
// Modelos
// ---------------------------------------------------------------------------

String brl(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

final RegExp kPriceRe = RegExp(r'R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})');

List<double> findPrices(String t) => kPriceRe
    .allMatches(t)
    .map((m) => double.parse('${m.group(1)!.replaceAll('.', '')}.${m.group(2)}'))
    .toList();

class UnitInfo {
  final double value; // preço por kg ou L
  final String label; // 'kg' ou 'L'
  const UnitInfo(this.value, this.label);
}

UnitInfo? unitInfo(String name, double price) {
  final n = name.toLowerCase();
  final re = RegExp(
      r'(?:(\d+)\s*x\s*)?(\d+(?:[.,]\d+)?)\s*(kg|gr|g|ml|litros?|lt|l)\b');
  final m = re.firstMatch(n);
  if (m == null) return null;
  var qty = double.tryParse(m.group(2)!.replaceAll(',', '.'));
  if (qty == null || qty <= 0) return null;
  if (m.group(1) != null) qty *= double.parse(m.group(1)!);
  final u = m.group(3)!;
  double base;
  String label;
  if (u == 'kg') {
    base = qty;
    label = 'kg';
  } else if (u == 'g' || u == 'gr') {
    base = qty / 1000;
    label = 'kg';
  } else if (u == 'ml') {
    base = qty / 1000;
    label = 'L';
  } else {
    base = qty;
    label = 'L';
  }
  if (base <= 0) return null;
  return UnitInfo(price / base, label);
}

class Item {
  final Store store;
  final String name;
  final double price;
  final double? oldPrice;
  final String url;
  final List<String> extra;
  final String raw;
  final String? img;
  final bool unavailable;
  late final UnitInfo? unit = unitInfo(name, price);

  Item({
    required this.store,
    required this.name,
    required this.price,
    required this.url,
    this.oldPrice,
    this.extra = const [],
    this.raw = '',
    this.img,
    this.unavailable = false,
  });

  static Item? fromJson(Store s, Map j) {
    final name = (j['name'] ?? '').toString().trim();
    final price = (j['price'] as num?)?.toDouble();
    if (name.isEmpty || price == null || price <= 0) return null;
    return Item(
      store: s,
      name: name,
      price: price,
      oldPrice: (j['old'] as num?)?.toDouble(),
      url: (j['url'] ?? '').toString(),
      extra: ((j['extra'] as List?) ?? []).map((e) => e.toString()).toList(),
      raw: (j['raw'] ?? '').toString(),
      img: j['img']?.toString(),
      unavailable: j['unavail'] == true,
    );
  }
}

enum Phase { idle, loading, ok, empty, error, blocked }

class StoreResult {
  final Phase phase;
  final List<Item> items;
  final String message;
  final String? cep;
  final int ms;
  final String debug;
  final String note;

  const StoreResult({
    this.phase = Phase.idle,
    this.items = const [],
    this.message = '',
    this.cep,
    this.ms = 0,
    this.debug = '',
    this.note = '',
  });
}

// ---------------------------------------------------------------------------
// Good Bom: requisição direta + leitura do HTML
// ---------------------------------------------------------------------------

String _joinText(dom.Node root) {
  final b = StringBuffer();
  void walk(dom.Node x) {
    if (x is dom.Text) {
      b.write(' ${x.text} ');
    } else {
      for (final c in x.nodes) {
        walk(c);
      }
    }
  }

  walk(root);
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

Future<List<Item>> fetchGoodBom(Store s, String q) async {
  final uri = Uri.parse(s.searchUrl(q));
  final r = await http.get(uri, headers: {
    'User-Agent': kUserAgent,
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'pt-BR,pt;q=0.9',
  }).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final body = utf8.decode(r.bodyBytes, allowMalformed: true);
  final doc = html_parser.parse(body);
  final out = <Item>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a')) {
    final href = a.attributes['href'] ?? '';
    if (!href.contains('/produto/')) continue;
    final url = uri.resolve(href).toString();
    if (!seen.add(url)) continue;
    final text = _joinText(a);
    final prices = findPrices(text).where((p) => p > 0).toList();
    if (prices.isEmpty) continue;

    String name;
    final addIdx = text.indexOf(' Add ');
    if (addIdx >= 0) {
      name = text.substring(addIdx + 5);
    } else {
      name = text;
    }
    final rIdx = name.indexOf('R\$');
    if (rIdx > 0) name = name.substring(0, rIdx);
    name = name
        .replaceAll(RegExp(r'\+\d+'), ' ')
        .replaceAll('Clube Oferta do clube', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty) {
      name = (a.attributes['title'] ?? '').trim();
    }
    if (name.isEmpty) {
      final segs = Uri.parse(url).pathSegments.where((e) => e.isNotEmpty);
      name = segs.isEmpty ? 'Produto' : segs.last.replaceAll('-', ' ');
    }
    final price = prices.first;
    final old = (prices.length > 1 && prices[1] > price) ? prices[1] : null;
    final src = a.querySelector('img')?.attributes['src'];
    out.add(Item(
      store: s,
      name: name,
      price: price,
      oldPrice: old,
      url: url,
      raw: text.length > 160 ? text.substring(0, 160) : text,
      img: src == null ? null : uri.resolve(src).toString(),
    ));
    if (out.length >= 40) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Leitura via WebView invisível (Atacadão, Pague Menos, Tenda e reserva do Good Bom)
// ---------------------------------------------------------------------------

const String _jsTemplate = r'''
(function(){
try{
var MODE='__MODE__';
function norm(s){return (s||'').replace(/\s+/g,' ').trim();}
function prices(t){var out=[],m,re=/R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})/g;while((m=re.exec(t||''))){out.push(parseFloat(m[1].replace(/\./g,'')+'.'+m[2]));}return out;}
function hasPrice(t){var p=prices(t);for(var i=0;i<p.length;i++){if(p[i]>0)return true;}return false;}
function imgUrl(root){
  var out='';
  var imgs=root.querySelectorAll('img');
  for(var i=0;i<imgs.length&&!out;i++){
    var im=imgs[i];
    try{var w=im.getBoundingClientRect().width;if(w>0&&w<30)continue;}catch(e){}
    var c=[im.currentSrc,im.getAttribute('src'),im.getAttribute('data-src'),im.getAttribute('data-lazy-src'),im.getAttribute('data-original')];
    var ss=im.getAttribute('srcset')||im.getAttribute('data-srcset');
    if(ss)c.push(ss.split(',')[0].trim().split(' ')[0]);
    for(var j=0;j<c.length&&!out;j++){
      var v=c[j];
      if(v&&v.indexOf('data:')!==0){try{out=new URL(v,location.href).href;}catch(e){}}
    }
  }
  if(!out){
    var so=root.querySelector('source[srcset]');
    if(so){var v2=(so.getAttribute('srcset')||'').split(',')[0].trim().split(' ')[0];if(v2){try{out=new URL(v2,location.href).href;}catch(e){}}}
  }
  if(!out){
    var bg=root.querySelector('[style*="background-image"]');
    if(bg){var mm=(bg.getAttribute('style')||'').match(/url\(["']?([^"')]+)["']?\)/);if(mm){try{out=new URL(mm[1],location.href).href;}catch(e){}}}
  }
  return out;
}
function cardImg(found){
  var u=imgUrl(found);
  var up=found.parentElement;
  for(var i=0;!u&&i<3&&up&&up!==document.body;i++){
    var ks={},n=0;
    [].forEach.call(up.querySelectorAll('a[href]'),function(x){if(!isProd(x))return;var kk=key(x);if(!ks[kk]){ks[kk]=1;n++;}});
    if(n>1)break;
    u=imgUrl(up);
    up=up.parentElement;
  }
  if(!u){
    var els=found.querySelectorAll('*');
    for(var j=0;j<els.length&&!u;j++){
      try{
        var bi=getComputedStyle(els[j]).backgroundImage;
        var mm=bi&&bi.match(/url\(["']?([^"')]+)["']?\)/);
        if(mm&&mm[1].indexOf('data:')!==0)u=new URL(mm[1],location.href).href;
      }catch(e){}
    }
  }
  return u;
}
try{[].forEach.call(document.querySelectorAll('img[loading="lazy"]'),function(i){i.loading='eager';});}catch(e){}
function key(a){try{var u=new URL(a.href,location.href);return u.origin+u.pathname;}catch(e){return a.href;}}
function isProd(a){
  var k=key(a);
  if(MODE==='vtex')return /\/p$/.test(k);
  if(MODE==='goodbom')return k.indexOf('/produto/')>-1;
  if(a.href.indexOf('javascript:')===0)return false;
  if(k===location.origin+'/'||k===location.origin+location.pathname)return false;
  return true;
}
var links=[].slice.call(document.querySelectorAll('a[href]')).filter(function(a){
  if(a.closest&&a.closest('header,nav,footer'))return false;
  return isProd(a);
});
var items=[],seenEl=[],seenKey={},sample='';
links.forEach(function(a){
  if(items.length>=40)return;
  var k=key(a);
  if(seenKey[k])return;
  var el=a,found=null;
  for(var i=0;i<8&&el&&el!==document.body;i++){
    if(hasPrice(el.textContent)){found=el;break;}
    el=el.parentElement;
  }
  if(!found||seenEl.indexOf(found)>-1)return;
  var keys={},n=0;
  [].forEach.call(found.querySelectorAll('a[href]'),function(x){
    if(!isProd(x))return;
    var kk=key(x);
    if(!keys[kk]){keys[kk]=1;n++;}
  });
  if(n>(MODE==='generic'?2:1))return;
  if(MODE==='generic'&&(found.textContent||'').length>500)return;
  seenEl.push(found);
  seenKey[k]=1;

  var leaves=[].filter.call(found.querySelectorAll('*'),function(d){
    if(!hasPrice(d.textContent))return false;
    for(var c=d.firstElementChild;c;c=c.nextElementSibling){if(hasPrice(c.textContent))return false;}
    return true;
  });
  var live=[],old=[];
  leaves.forEach(function(d){
    var ps=prices(d.textContent).filter(function(p){return p>0;});
    if(!ps.length)return;
    var struck=false;
    try{
      var e=d;
      while(e&&e!==found.parentElement){
        var cs=getComputedStyle(e);
        var td=(cs.textDecorationLine||'')+' '+(cs.textDecoration||'');
        if(td.indexOf('line-through')>-1||e.tagName==='S'||e.tagName==='DEL'){struck=true;break;}
        e=e.parentElement;
      }
    }catch(x){}
    var ctxEl=(d.parentElement&&d.parentElement!==found)?d.parentElement:d;
    var ctx=norm(ctxEl.innerText||ctxEl.textContent).slice(0,70);
    (struck?old:live).push({p:ps[0],ctx:ctx});
  });

  var price=0;
  var sel=found.querySelector('[data-fs-price-variant="selling"]');
  if(sel){var sp=prices(sel.textContent);if(sp.length)price=sp[0];}
  if(!price&&live.length)price=live[0].p;
  if(!price&&old.length)price=old[0].p;
  if(!price){var ap=prices(found.textContent).filter(function(x){return x>0;});if(ap.length)price=ap[0];}
  if(!price)return;

  var txt=norm(found.innerText||found.textContent);
  var oldP=old.length?old[0].p:null;
  var extra=[],seenP=[price];
  live.forEach(function(x){
    if(seenP.indexOf(x.p)<0&&extra.length<3){seenP.push(x.p);extra.push(x.ctx);}
  });
  function num(i,d){return parseFloat(i.replace(/\./g,'')+'.'+d);}
  var tm=txt.match(/a partir de\s*(\d+)\s*unid\w*\.?\s*R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})/i);
  var um=txt.match(/ou\s*R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})\s*\/\s*cada/i);
  if(tm&&um&&num(um[1],um[2])>0){
    price=num(um[1],um[2]);
    extra=['A partir de '+tm[1]+' un: R$ '+num(tm[2],tm[3]).toFixed(2).replace('.',',')];
    oldP=null;
  }else if(live.length>=2&&/\d+\s*%\s*(off|de desconto)|-\s*\d+\s*%/i.test(txt)){
    var dp=[];
    live.forEach(function(x){if(dp.indexOf(x.p)<0)dp.push(x.p);});
    if(dp.length>=2){
      var lo=Math.min(dp[0],dp[1]),hi=Math.max(dp[0],dp[1]);
      price=lo;oldP=hi;extra=[];
    }
  }
  var fmt=function(v){return v.toFixed(2).replace('.',',');};
  var cm=txt.match(/cart[a\u00e3]o\s*tenda\s*R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})/i);
  var qm=txt.match(/a partir de\s*(\d+)\s*unidades?\s*R\$\s*(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})/i);
  if((cm||qm)&&!(tm&&um)){
    extra=[];
    if(cm)extra.push('No Cart\u00e3o Tenda: R$ '+fmt(num(cm[1],cm[2])));
    if(qm)extra.push('A partir de '+qm[1]+' un: R$ '+fmt(num(qm[2],qm[3])));
  }
  var unavail=/indispon[i\u00ed]vel|esgotad|sem estoque/i.test(txt);

  var name='';
  var t=found.querySelector('[data-fs-product-card-title],h1,h2,h3,h4,[class*="title" i],[class*="name" i]');
  if(t)name=norm(t.textContent);
  if(!name||hasPrice(name))name=norm(a.getAttribute('title')||a.getAttribute('aria-label')||'');
  if(!name||hasPrice(name)){var im=found.querySelector('img[alt]');if(im)name=norm(im.alt);}
  if(!name||hasPrice(name)){
    var at=norm(a.textContent);
    if(at.length>5&&!hasPrice(at))name=at;
  }
  if(!name||hasPrice(name)){
    var lines=(found.innerText||'').split('\n').map(function(l){return norm(l.replace(/R\$\s*[\d.]+,\d{2}/g,' '));}).filter(function(l){return l.length>8&&l.length<130;});
    lines.sort(function(x,y){return y.length-x.length;});
    name=lines[0]||'';
  }
  if(!name)return;
  var im=cardImg(found);
  if(!items.length&&!im){sample=(found.parentElement||found).outerHTML.replace(/<svg[\s\S]*?<\/svg>/gi,'<svg/>').replace(/\s+/g,' ').slice(0,1500);}
  items.push({
    name:name.slice(0,140),
    url:a.href,
    price:price,
    old:oldP,
    unavail:unavail,
    extra:extra,
    raw:norm(found.innerText||found.textContent).slice(0,160),
    img:im
  });
});
var m=((document.body&&document.body.innerText)||'').match(/\b\d{5}-?\d{3}\b/);
var bodyText=(document.body&&document.body.innerText)||'';
var noRes=/nenhum (produto|resultado)|n[ãa]o encontramos|0 produtos? encontrad/i.test(bodyText);
var withImg=items.filter(function(x){return x.img;}).length;
return JSON.stringify({items:items,withImg:withImg,sample:sample,cep:m?m[0]:'',url:location.href,title:document.title,noRes:noRes,links:links.length});
}catch(e){
return JSON.stringify({items:[],err:String(e),title:'',url:'',cep:''});
}
})()
''';

dynamic decodeJsResult(Object res) {
  dynamic d = res;
  for (var i = 0; i < 3; i++) {
    if (d is String) {
      try {
        d = jsonDecode(d);
      } catch (_) {
        return null;
      }
    } else {
      break;
    }
  }
  return d;
}

class ScrapeResult {
  final List<Item> items;
  final String? cep;
  final String title;
  final String url;
  final bool blocked;
  final bool noRes;
  final int links;
  final int withImg;
  final String sample;
  const ScrapeResult({
    required this.items,
    this.cep,
    this.title = '',
    this.url = '',
    this.blocked = false,
    this.noRes = false,
    this.links = 0,
    this.withImg = 0,
    this.sample = '',
  });
}

class WebScraper {
  final Store store;
  late final WebViewController controller;
  Completer<void>? _loaded;
  String? _navError;
  int _gen = 0;

  WebScraper(this.store) {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          final c = _loaded;
          if (c != null && !c.isCompleted) c.complete();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) {
            _navError = e.description;
            final c = _loaded;
            if (c != null && !c.isCompleted) c.complete();
          }
        },
      ));
  }

  /// Retorna null se uma busca mais nova substituiu esta.
  Future<ScrapeResult?> search(String q) async {
    final my = ++_gen;
    _navError = null;
    _loaded = Completer<void>();
    await controller.loadRequest(Uri.parse(store.searchUrl(q)));
    await _loaded!.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    if (my != _gen) return null;
    if (_navError != null) throw Exception('Falha ao carregar o site: $_navError');

    final started = DateTime.now();
    final end = started.add(const Duration(seconds: 22));
    ScrapeResult last = const ScrapeResult(items: []);
    var lastCount = -1;
    var stable = 0;
    while (DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 900));
      if (my != _gen) return null;
      final r = await _extract();
      if (r == null) continue;
      last = r;
      if (r.blocked) break;
      if (r.items.isNotEmpty) {
        if (r.items.length == lastCount) {
          stable++;
        } else {
          stable = 0;
        }
        lastCount = r.items.length;
        if (stable >= 1) break;
      } else if (r.noRes &&
          DateTime.now().difference(started).inSeconds >= 9) {
        break;
      }
    }
    return last;
  }

  Future<ScrapeResult?> _extract() async {
    try {
      final res = await controller
          .runJavaScriptReturningResult(_jsTemplate.replaceAll('__MODE__', store.mode));
      final d = decodeJsResult(res);
      if (d is! Map) return null;
      final items = <Item>[];
      for (final j in ((d['items'] as List?) ?? [])) {
        if (j is Map) {
          final it = Item.fromJson(store, j);
          if (it != null) items.add(it);
        }
      }
      final title = (d['title'] ?? '').toString();
      final blockedTitle = RegExp(
              r'just a moment|attention required|access denied|acesso negado|verifying',
              caseSensitive: false)
          .hasMatch(title);
      return ScrapeResult(
        items: items,
        cep: (d['cep'] ?? '').toString(),
        title: title,
        url: (d['url'] ?? '').toString(),
        blocked: blockedTitle && items.isEmpty,
        noRes: d['noRes'] == true,
        links: (d['links'] as num?)?.toInt() ?? 0,
        withImg: (d['withImg'] as num?)?.toInt() ?? 0,
        sample: (d['sample'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Código de barras -> nome do produto (Open Food Facts), usado só como reserva
// ---------------------------------------------------------------------------

Future<String?> lookupEanName(String ean) async {
  try {
    final r = await http.get(
      Uri.parse(
          'https://world.openfoodfacts.org/api/v2/product/$ean.json?fields=product_name,brands,quantity'),
      headers: {'User-Agent': 'ComparadorMercado/1.0'},
    ).timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j['status'] != 1) return null;
    final p = j['product'];
    if (p is! Map) return null;
    final name = (p['product_name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final brand = (p['brands'] ?? '').toString().split(',').first.trim();
    return brand.isEmpty ? name : '$name $brand';
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Relevância: esconde o que não tem relação com o que foi digitado
// ---------------------------------------------------------------------------

String _norm(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

const Set<String> _stopWords = {
  'de', 'da', 'do', 'das', 'dos', 'com', 'e', 'para', 'a', 'o', 'em', 'un',
  'und', 'unid', 'unidade', 'unidades', 'litro', 'litros', 'quilo', 'quilos',
  'kg', 'g', 'gr', 'l', 'lt', 'ml',
};

bool _isCode(String q) => RegExp(r'^\d{6,}$').hasMatch(q.trim());

List<String> queryTokens(String q) {
  final seen = <String>{};
  final out = <String>[];
  for (final w in _norm(q).split(' ')) {
    if (w.isEmpty || _stopWords.contains(w)) continue;
    if (w.length < 2 && !RegExp(r'\d').hasMatch(w)) continue;
    if (seen.add(w)) out.add(w);
  }
  return out;
}

class _Size {
  final double base; // em kg ou L
  final String label;
  const _Size(this.base, this.label);
}

final RegExp _sizeRe =
    RegExp(r'(?:(\d+)\s*x\s*)?(\d+(?:[.,]\d+)?)\s*(kg|gr|g|ml|litros?|lt|l)\b');

List<_Size> _sizesIn(String text, {bool packs = true}) {
  final out = <_Size>[];
  for (final m in _sizeRe.allMatches(text.toLowerCase())) {
    final q = double.tryParse(m.group(2)!.replaceAll(',', '.'));
    if (q == null || q <= 0) continue;
    final u = m.group(3)!;
    _Size conv(double v) {
      if (u == 'kg') return _Size(v, 'kg');
      if (u == 'g' || u == 'gr') return _Size(v / 1000, 'kg');
      if (u == 'ml') return _Size(v / 1000, 'L');
      return _Size(v, 'L');
    }

    out.add(conv(q));
    if (packs && m.group(1) != null) {
      out.add(conv(q * double.parse(m.group(1)!)));
    }
  }
  return out;
}

class _Query {
  final List<String> tokens;
  final List<_Size> sizes;
  final List<List<String>> joins; // [a, b, ab]
  _Query(this.tokens, this.sizes, this.joins);
  bool get isEmpty => tokens.isEmpty && sizes.isEmpty;
}

_Query parseQuery(String q) {
  final sizes = _sizesIn(q, packs: false);
  final stripped = q.toLowerCase().replaceAll(_sizeRe, ' ');
  final raw = _norm(stripped).split(' ').where((e) => e.isNotEmpty).toList();
  final joins = <List<String>>[
    for (var i = 0; i + 1 < raw.length; i++)
      [raw[i], raw[i + 1], raw[i] + raw[i + 1]]
  ];
  return _Query(queryTokens(stripped), sizes, joins);
}

/// Nota de 0 a 1: quanto o nome do produto bate com o que foi buscado
/// (palavras e tamanho, ex.: 100g não bate com 29g).
double relevance(_Query pq, String name) {
  final total = pq.tokens.length + pq.sizes.length;
  if (total == 0) return 1;
  final n = _norm(name);
  final words = n.split(' ');
  final compact = n.replaceAll(' ', '');
  final joined = <String>{};
  for (final j in pq.joins) {
    if (words.contains(j[2])) {
      joined.add(j[0]);
      joined.add(j[1]);
    }
  }
  var hit = 0.0;
  for (final t in pq.tokens) {
    if (RegExp(r'\d').hasMatch(t)) {
      if (compact.contains(t)) hit += 1;
      continue;
    }
    if (joined.contains(t)) {
      hit += 1;
      continue;
    }
    var best = 0.0;
    for (final w in words) {
      if (w == t) {
        best = 1;
        break;
      }
      if (w.startsWith(t)) {
        final v = t.length / w.length >= 0.5 ? 1.0 : 0.4;
        if (v > best) best = v;
      } else if (w.length >= 5 && t.startsWith(w)) {
        if (best < 0.7) best = 0.7;
      }
    }
    if (best == 0 && t.length >= 5 && compact.contains(t)) best = 1;
    hit += best;
  }
  if (pq.sizes.isNotEmpty) {
    final have = _sizesIn(name);
    for (final qs in pq.sizes) {
      final ok = have.any((h) =>
          h.label == qs.label && (h.base - qs.base).abs() / qs.base <= 0.12);
      if (ok) hit += 1;
    }
  }
  return hit / total;
}

double bestRelevance(String q, List<Item> items) {
  final pq = parseQuery(q);
  if (pq.isEmpty || _isCode(q)) return 1;
  var best = 0.0;
  for (final it in items) {
    final sc = relevance(pq, it.name);
    if (sc > best) best = sc;
  }
  return best;
}

/// "bom bom especialidades nestle" -> "bombom especialidades nestle"
String? joinedVariant(String q) {
  final w = _norm(q).split(' ').where((e) => e.isNotEmpty).toList();
  if (w.length < 2) return null;
  return [w[0] + w[1], ...w.sublist(2)].join(' ');
}

class _Fetched {
  final List<Item> items;
  final String? cep;
  final Phase? forced;
  final String msg;
  _Fetched(this.items, this.cep, this.forced, this.msg);
}

class StoreLogo extends StatelessWidget {
  final Store store;
  final double size;
  const StoreLogo({super.key, required this.store, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Container(
        width: size,
        height: size,
        color: Colors.white,
        padding: EdgeInsets.all(size * 0.1),
        child: Image.network(
          store.logoUrl,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            color: store.color,
            alignment: Alignment.center,
            child: Text(store.name.substring(0, 1),
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.45)),
          ),
        ),
      ),
    );
  }
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Comparador',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32), brightness: Brightness.dark),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _q = TextEditingController();
  final _shelf = TextEditingController();
  final Map<String, WebScraper> _scrapers = {
    for (final s in kStores) s.id: WebScraper(s)
  };
  final Map<String, StoreResult> _results = {};
  final Set<String> _hidden = {};
  final Set<String> _expanded = {};
  final Set<String> _showAll = {};
  final Map<Item, double> _scores = {};
  double _globalBest = 0;
  String _query = '';
  bool _ranking = false;
  int _token = 0;
  String _cep = kDefaultCep;

  @override
  void initState() {
    super.initState();
    _loadCep();
  }

  @override
  void dispose() {
    _q.dispose();
    _shelf.dispose();
    super.dispose();
  }

  Future<void> _loadCep() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _cep = p.getString('cep') ?? kDefaultCep);
  }

  double? _shelfValue() {
    final t = _shelf.text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  Future<int> _search([String? override]) async {
    final q = (override ?? _q.text).trim();
    if (q.isEmpty) return -1;
    FocusScope.of(context).unfocus();
    final token = ++_token;
    setState(() {
      _query = q;
      _expanded.clear();
      _showAll.clear();
      for (final s in kStores) {
        _results[s.id] = const StoreResult(phase: Phase.loading);
      }
      _recompute();
    });
    await Future.wait(kStores.map((s) => _searchStore(s, q, token)));
    var total = 0;
    for (final s in kStores) {
      total += _results[s.id]?.items.length ?? 0;
    }
    return total;
  }

  /// Recalcula a nota de cada item. O corte é global: se algum mercado tem
  /// um item que bate 100%, itens que só batem em parte somem de todos.
  void _recompute() {
    final pq = parseQuery(_query);
    final noFilter = pq.isEmpty || _isCode(_query);
    _scores.clear();
    var best = 0.0;
    for (final r in _results.values) {
      for (final it in r.items) {
        final sc = noFilter ? 1.0 : relevance(pq, it.name);
        _scores[it] = sc;
        if (sc > best) best = sc;
      }
    }
    _globalBest = best;
  }

  List<Item> _visible(Store s) {
    final r = _results[s.id];
    if (r == null) return const [];
    if (_showAll.contains(s.id)) return r.items;
    final thr = _globalBest < 0.8 ? _globalBest : 0.8;
    final scored = <MapEntry<int, double>>[];
    for (var i = 0; i < r.items.length; i++) {
      final sc = _scores[r.items[i]] ?? 0.0;
      if (sc >= 0.5 && sc >= thr - 1e-9) scored.add(MapEntry(i, sc));
    }
    scored.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return [for (final e in scored) r.items[e.key]];
  }

  Future<_Fetched?> _fetch(Store s, String q, int token, StringBuffer dbg) async {
    var items = <Item>[];
    String? cep;
    Phase? forced;
    var msg = '';
    if (s.id == 'goodbom') {
      try {
        items = await fetchGoodBom(s, q);
        dbg.writeln('Requisição direta: ${items.length} itens');
      } catch (e) {
        dbg.writeln('Requisição direta falhou: $e');
      }
    }
    if (items.isEmpty) {
      final r = await _scrapers[s.id]!.search(q);
      if (r == null || token != _token) return null;
      items = r.items;
      cep = r.cep;
      dbg.writeln('WebView: ${r.items.length} itens (${r.withImg} com foto) | '
          'links de produto: ${r.links} | título: ${r.title} | url final: ${r.url}');
      if (r.items.isNotEmpty && r.withImg == 0 && r.sample.isNotEmpty) {
        dbg.writeln('HTML do 1º card (sem foto): ${r.sample}');
      }
      if (r.blocked) {
        forced = Phase.blocked;
        msg = 'Bloqueado pelo site (anti-robô)';
      }
    }
    return _Fetched(items, cep, forced, msg);
  }

  Future<void> _searchStore(Store s, String q, int token) async {
    final sw = Stopwatch()..start();
    final dbg = StringBuffer('Loja: ${s.name}\nBusca: ${s.searchUrl(q)}\n');
    try {
      var f = await _fetch(s, q, token, dbg);
      if (f == null) return;
      var note = '';
      if (f.forced == null && bestRelevance(q, f.items) < 0.8) {
        final v = joinedVariant(q);
        if (v != null && !_isCode(q)) {
          dbg.writeln('Nada parecido. Tentando de novo: ${s.searchUrl(v)}');
          final f2 = await _fetch(s, v, token, dbg);
          if (f2 == null) return;
          if (bestRelevance(q, f2.items) > bestRelevance(q, f.items)) {
            f = f2;
            note = ' · buscou "$v"';
          }
        }
      }
      if (token != _token || !mounted) return;
      sw.stop();
      final _Fetched fin = f;
      dbg.writeln(
          'Melhor semelhança com a busca: ${bestRelevance(q, fin.items).toStringAsFixed(2)} | itens: ${fin.items.length}');
      for (final it in fin.items.take(3)) {
        dbg.writeln('• ${it.name} | ${brl(it.price)} | ${it.raw}');
      }
      setState(() {
        _results[s.id] = StoreResult(
          phase: fin.forced ?? (fin.items.isEmpty ? Phase.empty : Phase.ok),
          items: fin.items,
          message: fin.msg,
          cep: fin.cep,
          ms: sw.elapsedMilliseconds,
          debug: dbg.toString(),
          note: note,
        );
        _recompute();
      });
    } catch (e) {
      if (token != _token || !mounted) return;
      dbg.writeln('ERRO: $e');
      setState(() {
        _results[s.id] = StoreResult(
          phase: Phase.error,
          message: '$e'.replaceFirst('Exception: ', ''),
          ms: sw.elapsedMilliseconds,
          debug: dbg.toString(),
        );
        _recompute();
      });
    }
  }

  Future<void> _scan() async {
    var st = await Permission.camera.status;
    if (!st.isGranted) st = await Permission.camera.request();
    if (!st.isGranted) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Permissão da câmera'),
          content: Text(
              'O app precisa da câmera para ler o código de barras (situação atual: ${st.name}). '
              'Toque em "Abrir configurações", entre em Permissões > Câmera e escolha "Permitir".'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  openAppSettings();
                  Navigator.pop(ctx);
                },
                child: const Text('Abrir configurações')),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (code == null || !mounted) return;
    _q.text = code;
    final total = await _search(code);
    if (total == 0 && mounted) {
      final name = await lookupEanName(code);
      if (!mounted) return;
      if (name != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Código sem resultado. Buscando por nome: $name')));
        _q.text = name;
        await _search(name);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Nenhum mercado achou esse código. Tente digitar o nome do produto.')));
      }
    }
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SettingsPage(cep: _cep)));
    _loadCep();
  }

  void _openDiag() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DiagPage(results: Map.of(_results))));
  }

  // ----------------------------- UI --------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Comparador de preços'),
        actions: [
          IconButton(
              tooltip: 'Diagnóstico',
              icon: const Icon(Icons.bug_report_outlined),
              onPressed: _openDiag),
          IconButton(
              tooltip: 'Configurar mercados',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _openSettings),
        ],
      ),
      body: Stack(
        children: [
          // WebViews invisíveis (ficam atrás da tela principal).
          for (final s in kStores)
            Positioned.fill(
                child: WebViewWidget(controller: _scrapers[s.id]!.controller)),
          Positioned.fill(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(
                children: [
                  Expanded(child: _content()),
                  _searchBar(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton.filledTonal(
                  tooltip: 'Escanear código de barras',
                  iconSize: 28,
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _q,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: 'Produto ou código de barras',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                  tooltip: 'Buscar',
                  iconSize: 28,
                  onPressed: () => _search(),
                  icon: const Icon(Icons.search)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    final cs = Theme.of(context).colorScheme;
    final shelfField = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: _shelf,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Preço na prateleira (opcional)',
          prefixText: 'R\$ ',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );

    if (_results.isEmpty) {
      return Column(
        children: [
          shelfField,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shopping_cart_outlined,
                        size: 64, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(
                      'Escaneie o código de barras ou digite o nome do produto para comparar Good Bom, Tenda, Atacadão e Pague Menos.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        shelfField,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            children: [
              _statusChips(),
              _summary(),
              Row(
                children: [
                  const Text('Visualização:'),
                  const SizedBox(width: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Por mercado')),
                      ButtonSegment(value: true, label: Text('Ranking')),
                    ],
                    selected: {_ranking},
                    onSelectionChanged: (v) =>
                        setState(() => _ranking = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_ranking) ..._rankingList() else ..._storeSections(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 0,
      children: [
        for (final s in kStores) _chip(s),
      ],
    );
  }

  Widget _chip(Store s) {
    final r = _results[s.id];
    Widget avatar;
    switch (r?.phase ?? Phase.idle) {
      case Phase.loading:
        avatar = const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2));
        break;
      case Phase.ok:
        avatar = _visible(s).isEmpty
            ? const Icon(Icons.remove_circle_outline, size: 16)
            : const Icon(Icons.check_circle, size: 16, color: Colors.green);
        break;
      case Phase.empty:
        avatar = const Icon(Icons.remove_circle_outline, size: 16);
        break;
      default:
        avatar = const Icon(Icons.error_outline, size: 16, color: Colors.red);
    }
    return FilterChip(
      avatar: StoreLogo(store: s, size: 20),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s.name),
          const SizedBox(width: 6),
          SizedBox(width: 16, height: 16, child: Center(child: avatar)),
        ],
      ),
      selected: !_hidden.contains(s.id),
      onSelected: (v) => setState(() {
        if (v) {
          _hidden.remove(s.id);
        } else {
          _hidden.add(s.id);
        }
      }),
    );
  }

  Widget _summary() {
    final cands = <Item>[];
    var pending = false;
    for (final s in kStores) {
      if (_hidden.contains(s.id)) continue;
      final r = _results[s.id];
      if (r == null) continue;
      if (r.phase == Phase.loading) pending = true;
      cands.addAll(_visible(s).where((i) => !i.unavailable).take(5));
    }
    if (cands.isEmpty) return const SizedBox.shrink();

    final byPrice = [...cands]..sort((a, b) => a.price.compareTo(b.price));
    final best = byPrice.first;
    final bestName =
        best.name.length > 42 ? '${best.name.substring(0, 42)}…' : best.name;
    final lines = <String>[
      'Menor preço: ${brl(best.price)} no ${best.store.name}',
      bestName,
    ];
    for (final label in ['kg', 'L']) {
      final withUnit =
          cands.where((i) => i.unit != null && i.unit!.label == label).toList();
      if (withUnit.length >= 2) {
        withUnit.sort((a, b) => a.unit!.value.compareTo(b.unit!.value));
        final b = withUnit.first;
        lines.add(
            'Menor por $label: ${brl(b.unit!.value)}/$label no ${b.store.name}');
      }
    }
    final shelf = _shelfValue();
    if (shelf != null) {
      final d = best.price - shelf;
      if (d.abs() < 0.005) {
        lines.add('Igual ao preço da prateleira.');
      } else if (d < 0) {
        lines.add('${brl(-d)} mais barato que a prateleira (confira o tamanho).');
      } else {
        lines.add('A prateleira está ${brl(d)} mais barata que o melhor online.');
      }
    }
    if (pending) lines.add('Ainda buscando em alguns mercados...');

    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++)
              Text(lines[i],
                  style: TextStyle(
                      fontSize: i == 0 ? 16 : 13,
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                      fontStyle: i == 1 ? FontStyle.italic : FontStyle.normal)),
            const SizedBox(height: 2),
            const Text(
              'Considera só os resultados parecidos com a busca (até 5 por mercado).',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _storeSections() {
    final out = <Widget>[];
    for (final s in kStores) {
      if (_hidden.contains(s.id)) continue;
      final r = _results[s.id];
      if (r == null) continue;
      out.add(_sectionHeader(s, r));
      if (r.phase == Phase.loading) {
        out.add(const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator()));
        continue;
      }
      final vis = _visible(s);
      final hiddenCount = r.items.length - vis.length;
      final showingAll = _showAll.contains(s.id);
      if (vis.isEmpty && r.items.isNotEmpty) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('Nenhum resultado parecido com "$_query".'),
        ));
        out.add(TextButton(
          onPressed: () => setState(() => _showAll.add(s.id)),
          child: Text('Mostrar os ${r.items.length} resultados sem relação'),
        ));
        continue;
      }
      final expanded = _expanded.contains(s.id);
      final shown = expanded ? vis : vis.take(5).toList();
      for (final it in shown) {
        out.add(_tile(it, showStore: false));
      }
      if (vis.length > 5) {
        out.add(TextButton(
          onPressed: () => setState(() {
            if (expanded) {
              _expanded.remove(s.id);
            } else {
              _expanded.add(s.id);
            }
          }),
          child: Text(expanded ? 'Mostrar menos' : 'Ver mais (${vis.length - 5})'),
        ));
      }
      if (!showingAll && hiddenCount > 0) {
        out.add(TextButton(
          onPressed: () => setState(() => _showAll.add(s.id)),
          child: Text('Mostrar também $hiddenCount sem relação'),
        ));
      } else if (showingAll) {
        out.add(TextButton(
          onPressed: () => setState(() => _showAll.remove(s.id)),
          child: const Text('Ocultar resultados sem relação'),
        ));
      }
    }
    return out;
  }

  Widget _sectionHeader(Store s, StoreResult r) {
    final cs = Theme.of(context).colorScheme;
    String status;
    switch (r.phase) {
      case Phase.loading:
        status = 'buscando...';
        break;
      case Phase.ok:
        status =
            '${_visible(s).length} de ${r.items.length} parecidos · ${(r.ms / 1000).toStringAsFixed(1)}s${r.note}';
        break;
      case Phase.empty:
        status = 'nenhum resultado';
        break;
      case Phase.blocked:
        status = r.message;
        break;
      case Phase.error:
        status = 'indisponível: ${r.message}';
        break;
      default:
        status = '';
    }
    final digits = (r.cep ?? '').replaceAll(RegExp(r'\D'), '');
    final mine = _cep.replaceAll(RegExp(r'\D'), '');
    final showCep = s.needsLocation && digits.isNotEmpty && r.items.isNotEmpty;
    final cepDiffers = showCep && digits != mine;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StoreLogo(store: s, size: 30),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: s.color, borderRadius: BorderRadius.circular(8)),
                child: Text(s.name,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(status,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
            ],
          ),
          if (cepDiffers)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Atenção: o site mostra preços para o CEP ${r.cep}, não para $_cep. Ajuste em Configurar mercados (engrenagem).',
                style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _rankingList() {
    final all = <Item>[];
    for (final s in kStores) {
      if (_hidden.contains(s.id)) continue;
      final r = _results[s.id];
      if (r == null) continue;
      all.addAll(_visible(s).where((i) => !i.unavailable).take(12));
    }
    if (all.isEmpty) {
      return [
        const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Sem resultados ainda.')))
      ];
    }
    all.sort((a, b) {
      final ua = a.unit?.value;
      final ub = b.unit?.value;
      if (ua != null && ub != null) return ua.compareTo(ub);
      if (ua != null) return -1;
      if (ub != null) return 1;
      return a.price.compareTo(b.price);
    });
    return [
      const Padding(
        padding: EdgeInsets.only(bottom: 4),
        child: Text('Ordenado pelo menor preço por kg/L (itens sem peso no final).',
            style: TextStyle(fontSize: 12)),
      ),
      for (final it in all.take(40)) _tile(it, showStore: true),
    ];
  }

  Widget _deltaText(Item it) {
    final shelf = _shelfValue();
    if (shelf == null) return const SizedBox.shrink();
    final d = it.price - shelf;
    String t;
    Color c;
    if (d.abs() < 0.005) {
      t = 'igual à prateleira';
      c = Theme.of(context).colorScheme.onSurfaceVariant;
    } else if (d < 0) {
      t = '${brl(-d)} mais barato';
      c = Colors.green.shade700;
    } else {
      t = '${brl(d)} mais caro';
      c = Colors.red.shade700;
    }
    return Text(t,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c));
  }

  Widget _tile(Item it, {required bool showStore}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(it.url),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (it.img != null && it.img!.startsWith('http'))
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Image.network(
                    it.img!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const SizedBox(width: 56, height: 56),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showStore)
                      Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: it.store.color,
                            borderRadius: BorderRadius.circular(6)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StoreLogo(store: it.store, size: 16),
                            const SizedBox(width: 4),
                            Text(it.store.name,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    Text(it.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14)),
                    for (final e in it.extra)
                      Text(e,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    if (it.unavailable)
                      Text('Indisponível',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.red.shade700)),
                    _deltaText(it),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(brl(it.price),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  if (it.oldPrice != null && it.oldPrice! > it.price)
                    Text(brl(it.oldPrice!),
                        style: TextStyle(
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                            color: cs.onSurfaceVariant)),
                  if (it.unit != null)
                    Text('${brl(it.unit!.value)}/${it.unit!.label}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.primary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _c = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aponte para o código de barras'),
        actions: [
          IconButton(
              tooltip: 'Lanterna',
              icon: const Icon(Icons.flashlight_on_outlined),
              onPressed: () => _c.toggleTorch()),
        ],
      ),
      body: MobileScanner(
        controller: _c,
        errorBuilder: (context, error, child) {
          final msg = error.errorDetails?.message ?? '';
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    const Text('Não foi possível abrir a câmera',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    SelectableText('Motivo: ${error.errorCode.name} $msg',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                        onPressed: () => openAppSettings(),
                        child: const Text('Abrir configurações do app')),
                    TextButton(
                        onPressed: () => _c.start(),
                        child: const Text('Tentar de novo')),
                  ],
                ),
              ),
            ),
          );
        },
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.isNotEmpty) {
              _done = true;
              Navigator.of(context).pop(v);
              break;
            }
          }
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Configuração dos mercados (CEP / loja)
// ---------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  final String cep;
  const SettingsPage({super.key, required this.cep});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _cepC = TextEditingController(text: widget.cep);

  Future<void> _saveCep(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('cep', v.trim());
  }

  @override
  void dispose() {
    _cepC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar mercados')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Atacadão, Pague Menos e Tenda mostram preços conforme o CEP/loja escolhidos no próprio site. Faça isso uma vez em cada um: abra o site, informe o CEP e volte.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _cepC,
            onChanged: _saveCep,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Meu CEP',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _cepC.text.trim()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('CEP copiado')));
            },
            child: const Text('Copiar CEP (para colar no site)'),
          ),
          const SizedBox(height: 16),
          for (final s in kStores)
            Card(
              child: ListTile(
                leading: StoreLogo(store: s, size: 40),
                title: Text(s.name),
                subtitle: Text(s.id == 'goodbom'
                    ? 'Já fixo na loja de Mogi Mirim'
                    : 'Toque para abrir e definir CEP/loja'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        SitePage(store: s, cep: _cepC.text.trim()))),
              ),
            ),
        ],
      ),
    );
  }
}

class SitePage extends StatefulWidget {
  final Store store;
  final String cep;
  const SitePage({super.key, required this.store, required this.cep});

  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> {
  late final WebViewController _c = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setUserAgent(kUserAgent)
    ..loadRequest(Uri.parse(widget.store.home));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.store.name),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.cep));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('CEP ${widget.cep} copiado')));
            },
            child: const Text('Copiar CEP'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Concluído'),
          ),
        ],
      ),
      body: WebViewWidget(controller: _c),
    );
  }
}

// ---------------------------------------------------------------------------
// Diagnóstico
// ---------------------------------------------------------------------------

class DiagPage extends StatelessWidget {
  final Map<String, StoreResult> results;
  const DiagPage({super.key, required this.results});

  String _report() {
    final b = StringBuffer('RELATÓRIO DE DIAGNÓSTICO\n\n');
    for (final s in kStores) {
      final r = results[s.id];
      b.writeln('=== ${s.name} ===');
      if (r == null) {
        b.writeln('(sem busca ainda)\n');
        continue;
      }
      b.writeln('Situação: ${r.phase.name} | itens: ${r.items.length} | '
          '${r.ms}ms | CEP detectado: ${r.cep ?? '-'}');
      if (r.message.isNotEmpty) b.writeln('Mensagem: ${r.message}');
      b.writeln(r.debug);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico'),
        actions: [
          IconButton(
            tooltip: 'Copiar relatório',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _report()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Relatório copiado. Cole na conversa.')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
              'Faça uma busca e abra esta tela. Se algum mercado falhar, copie o relatório (ícone no topo) e cole na conversa.'),
          const SizedBox(height: 8),
          for (final s in kStores)
            ExpansionTile(
              title: Text(s.name),
              subtitle: Text(results[s.id] == null
                  ? 'sem busca'
                  : '${results[s.id]!.phase.name} · ${results[s.id]!.items.length} itens'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                      results[s.id]?.debug.isNotEmpty == true
                          ? results[s.id]!.debug
                          : (results[s.id]?.message ?? '-'),
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
