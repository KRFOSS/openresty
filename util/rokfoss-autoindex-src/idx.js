(function(){
'use strict';

var ROW_H = 34, OVERSCAN = 8;

var raw = document.getElementById('idx-data').textContent;
var all;
try { all = JSON.parse(raw); } catch (e) { all = []; }

// 제목과 빵부스러기는 현재 경로에서 만든다 (서버가 주입하지 않는다).
var path = decodeURIComponent(location.pathname);
document.title = path + ' · ROKFOSS Mirror';
(function(){
  var nav = document.getElementById('idx-crumbs');
  var html = ['<a href="/">/</a>'], acc = '';
  var segs = path.split('/').filter(Boolean);
  for (var i = 0; i < segs.length; i++) {
    acc += '/' + segs[i];
    html.push('<span class="idx-sep">/</span><a href="' +
              esc(acc + '/') + '">' + esc(segs[i]) + '</a>');
  }
  nav.innerHTML = html.join('');
})();

var viewport = document.getElementById('idx-viewport');
var spacer   = document.getElementById('idx-spacer');
var rowsBox  = document.getElementById('idx-rows');
var stats    = document.getElementById('idx-stats');
var empty    = document.getElementById('idx-empty');
var search   = document.getElementById('idx-search');

var items = [];
for (var i = 0; i < all.length; i++) {
  var e = all[i];
  var dir = e.type === 'directory';
  var t = Date.parse(e.mtime);
  items.push({
    name: e.name,
    lower: e.name.toLowerCase(),
    dir: dir,
    size: dir ? -1 : (typeof e.size === 'number' ? e.size : -1),
    time: isNaN(t) ? 0 : t
  });
}

function fmtSize(n){
  if (n < 0) return '-';
  if (n < 1024) return n + ' B';
  var u = ['KB','MB','GB','TB'], i = -1, v = n;
  do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
  return (v < 10 ? v.toFixed(1) : Math.round(v)) + ' ' + u[i];
}

function fmtDate(ms){
  if (!ms) return '';
  var d = new Date(ms), p = function(x){ return x < 10 ? '0' + x : x; };
  return d.getFullYear() + '-' + p(d.getMonth()+1) + '-' + p(d.getDate())
         + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function icon(it){
  if (it.dir) return '\u{1F4C1}';
  var n = it.lower, dot = n.lastIndexOf('.'), ext = dot < 0 ? '' : n.slice(dot+1);
  if (ext === 'iso' || ext === 'img') return '\u{1F4BF}';
  if (ext === 'deb' || ext === 'rpm' || ext === 'pkg' || ext === 'apk') return '\u{1F4E6}';
  if (ext === 'gz'||ext==='xz'||ext==='zst'||ext==='bz2'||ext==='zip'||ext==='tar'||ext==='7z') return '\u{1F5DC}';
  if (ext === 'asc'||ext==='sig'||ext==='gpg'||ext==='sha256'||ext==='sha512') return '\u{1F511}';
  if (n.indexOf('readme') >= 0 || ext === 'txt' || ext === 'md') return '\u{1F4C4}';
  return '\u{1F4C4}';
}

var sortKey = 'name', sortAsc = true;

function cmp(a, b){
  if (a.dir !== b.dir) return a.dir ? -1 : 1;
  var r = 0;
  if (sortKey === 'size') r = a.size - b.size;
  else if (sortKey === 'mtime') r = a.time - b.time;
  else r = a.lower < b.lower ? -1 : (a.lower > b.lower ? 1 : 0);
  return sortAsc ? r : -r;
}

var view = items.slice().sort(cmp);
var query = '';

function applyFilter(){
  if (!query) {
    view = items.slice().sort(cmp);
  } else {
    var q = query.toLowerCase(), out = [];
    for (var i = 0; i < items.length; i++) {
      if (items[i].lower.indexOf(q) >= 0) out.push(items[i]);
    }
    view = out.sort(cmp);
  }
  viewport.scrollTop = 0;
  layout();
  render(true);
}

function layout(){
  spacer.style.height = (view.length * ROW_H) + 'px';
  stats.textContent = query
    ? view.length.toLocaleString() + ' / ' + items.length.toLocaleString() + '개'
    : items.length.toLocaleString() + '개 항목';
  empty.hidden = view.length > 0;
}

var lastStart = -1, lastEnd = -1;

function render(force){
  var top = viewport.scrollTop;
  var h = viewport.clientHeight || 600;
  var start = Math.max(0, Math.floor(top / ROW_H) - OVERSCAN);
  var end = Math.min(view.length, Math.ceil((top + h) / ROW_H) + OVERSCAN);

  if (!force && start === lastStart && end === lastEnd) return;
  lastStart = start; lastEnd = end;

  var html = [];
  for (var i = start; i < end; i++) {
    var it = view[i];
    var href = encodeURIComponent(it.name) + (it.dir ? '/' : '');
    html.push(
      '<div class="idx-row', it.dir ? ' idx-dir' : '', '" role="row">',
        '<div class="idx-name"><span class="idx-ico">', icon(it), '</span>',
          '<a href="', href, '" title="', esc(it.name), '">', mark(it.name), '</a>',
        '</div>',
        '<div class="idx-size">', fmtSize(it.size), '</div>',
        '<div class="idx-date">', fmtDate(it.time), '</div>',
      '</div>'
    );
  }

  rowsBox.style.transform = 'translateY(' + (start * ROW_H) + 'px)';
  rowsBox.innerHTML = html.join('');
}

function esc(s){
  return s.replace(/[&<>"']/g, function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}

function mark(name){
  if (!query) return esc(name);
  var i = name.toLowerCase().indexOf(query.toLowerCase());
  if (i < 0) return esc(name);
  return esc(name.slice(0, i))
       + '<span class="idx-hit">' + esc(name.slice(i, i + query.length)) + '</span>'
       + esc(name.slice(i + query.length));
}

var ticking = false;
viewport.addEventListener('scroll', function(){
  if (ticking) return;
  ticking = true;
  requestAnimationFrame(function(){ render(); ticking = false; });
}, { passive: true });

window.addEventListener('resize', function(){ render(true); });

var timer = null;
search.addEventListener('input', function(){
  clearTimeout(timer);
  timer = setTimeout(function(){
    query = search.value.trim();
    applyFilter();
  }, 90);
});

document.addEventListener('keydown', function(e){
  if (e.key === '/' && document.activeElement !== search) {
    e.preventDefault();
    search.focus();
    search.select();
  } else if (e.key === 'Escape' && document.activeElement === search) {
    search.value = ''; query = ''; applyFilter(); search.blur();
  }
});

var heads = document.querySelectorAll('.idx-h');
for (var k = 0; k < heads.length; k++) {
  (function(btn){
    btn.addEventListener('click', function(){
      var key = btn.getAttribute('data-sort');
      if (sortKey === key) { sortAsc = !sortAsc; }
      else { sortKey = key; sortAsc = true; }
      for (var j = 0; j < heads.length; j++) heads[j].removeAttribute('aria-sort');
      btn.setAttribute('aria-sort', sortAsc ? 'ascending' : 'descending');
      applyFilter();
    });
  })(heads[k]);
}

layout();
render(true);
})();
