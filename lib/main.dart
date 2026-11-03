import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
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
  bool get needsLocation => mode == 'vtex' || mode == 'generic';
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

  const StoreResult({
    this.phase = Phase.idle,
    this.items = const [],
    this.message = '',
    this.cep,
    this.ms = 0,
    this.debug = '',
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
var items=[],seenEl=[],seenKey={};
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

  var extra=[],seenP=[price];
  live.forEach(function(x){
    if(seenP.indexOf(x.p)<0&&extra.length<3){seenP.push(x.p);extra.push(x.ctx);}
  });

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
  var img=found.querySelector('img');
  items.push({
    name:name.slice(0,140),
    url:a.href,
    price:price,
    old:old.length?old[0].p:null,
    extra:extra,
    raw:norm(found.innerText||found.textContent).slice(0,160),
    img:img?(img.currentSrc||img.src||''):''
  });
});
var m=((document.body&&document.body.innerText)||'').match(/\b\d{5}-?\d{3}\b/);
var bodyText=(document.body&&document.body.innerText)||'';
var noRes=/nenhum (produto|resultado)|n[ãa]o encontramos|0 produtos? encontrad/i.test(bodyText);
return JSON.stringify({items:items,cep:m?m[0]:'',url:location.href,title:document.title,noRes:noRes,links:links.length});
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
  const ScrapeResult({
    required this.items,
    this.cep,
    this.title = '',
    this.url = '',
    this.blocked = false,
    this.noRes = false,
    this.links = 0,
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
      _expanded.clear();
      for (final s in kStores) {
        _results[s.id] = const StoreResult(phase: Phase.loading);
      }
    });
    await Future.wait(kStores.map((s) => _searchStore(s, q, token)));
    var total = 0;
    for (final s in kStores) {
      total += _results[s.id]?.items.length ?? 0;
    }
    return total;
  }

  Future<void> _searchStore(Store s, String q, int token) async {
    final sw = Stopwatch()..start();
    final dbg = StringBuffer('Loja: ${s.name}\nBusca: ${s.searchUrl(q)}\n');
    try {
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
        if (r == null || token != _token) return;
        items = r.items;
        cep = r.cep;
        dbg.writeln('WebView: ${r.items.length} itens | links de produto: '
            '${r.links} | título: ${r.title} | url final: ${r.url}');
        if (r.blocked) {
          forced = Phase.blocked;
          msg = 'Bloqueado pelo site (anti-robô)';
        }
      }
      if (token != _token || !mounted) return;
      sw.stop();
      for (final it in items.take(3)) {
        dbg.writeln('• ${it.name} | ${brl(it.price)} | ${it.raw}');
      }
      setState(() {
        _results[s.id] = StoreResult(
          phase: forced ?? (items.isEmpty ? Phase.empty : Phase.ok),
          items: items,
          message: msg,
          cep: cep,
          ms: sw.elapsedMilliseconds,
          debug: dbg.toString(),
        );
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
      });
    }
  }

  Future<void> _scan() async {
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
        avatar = const Icon(Icons.check_circle, size: 16, color: Colors.green);
        break;
      case Phase.empty:
        avatar = const Icon(Icons.remove_circle_outline, size: 16);
        break;
      default:
        avatar = const Icon(Icons.error_outline, size: 16, color: Colors.red);
    }
    return FilterChip(
      avatar: avatar,
      label: Text(s.name),
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
      cands.addAll(r.items.take(5));
    }
    if (cands.isEmpty) return const SizedBox.shrink();

    final byPrice = [...cands]..sort((a, b) => a.price.compareTo(b.price));
    final best = byPrice.first;
    final lines = <String>[
      'Menor preço: ${brl(best.price)} no ${best.store.name}',
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
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500)),
            const SizedBox(height: 2),
            const Text(
              'Considera os 5 primeiros resultados de cada mercado.',
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
      } else if (r.items.isNotEmpty) {
        final expanded = _expanded.contains(s.id);
        final shown = expanded ? r.items : r.items.take(5).toList();
        for (final it in shown) {
          out.add(_tile(it, showStore: false));
        }
        if (r.items.length > 5) {
          out.add(TextButton(
            onPressed: () => setState(() {
              if (expanded) {
                _expanded.remove(s.id);
              } else {
                _expanded.add(s.id);
              }
            }),
            child: Text(expanded
                ? 'Mostrar menos'
                : 'Ver mais (${r.items.length - 5})'),
          ));
        }
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
        status = '${r.items.length} resultados · ${(r.ms / 1000).toStringAsFixed(1)}s';
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
      all.addAll(r.items.take(12));
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
                        child: Text(it.store.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
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
                leading: CircleAvatar(backgroundColor: s.color),
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
