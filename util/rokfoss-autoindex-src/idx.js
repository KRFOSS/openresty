(function () {
    var container = document.querySelector('.autoindex-container');
    var raw = document.getElementById('idx-data').textContent;
    var entries;
    try { entries = JSON.parse(raw); } catch (e) { entries = []; }

    // ── 다국어 사전 ─────────────────────────────────────────────
    // 각 언어의 UI 문구 + 대표 국가 법령 근거.
    var I18N = {
        ko: {
            label: '한국어',
            search: '이 디렉터리에서 검색 (파일명 입력)',
            colName: '파일 이름', colSize: '크기', colDate: '수정일',
            parent: '상위 디렉토리',
            noResults: '검색 결과가 없습니다.',
            perPage: '페이지당',
            total: function (n, s, e) {
                return '총 ' + n.toLocaleString() + '개 · '
                     + s.toLocaleString() + '-' + e.toLocaleString();
            },
            date: function (d, p) {
                return d.getFullYear() + '년 ' + p(d.getMonth() + 1) + '월 '
                     + p(d.getDate()) + '일 ' + p(d.getHours()) + '시 '
                     + p(d.getMinutes()) + '분';
            },
            links: {
                mail: '공식메일로 문의하기', dist: '분산미러 이용하기',
                community: '커뮤니티에 가입하기', kali: '칼리 리눅스 한국어 문서',
                docs: 'ROKFOSS Docs(문서)', news: 'ROKFOSS 프로젝트 뉴스룸',
                status: 'ROKFOSS 및 참여 미러 서비스 상태'
            },
            sponsors: '후원사',
            copyright: '© 2025-2026 ROKFOSS. 모든 권리 보유 | ROKFOSS PROJECT',
            legal: '이메일 무단수집 거부 — 본 사이트에 게시된 이메일 주소가 전자우편 수집 프로그램 등을 통해 무단으로 수집되는 것을 거부하며, 위반 시 「정보통신망 이용촉진 및 정보보호 등에 관한 법률」 제50조의2에 따라 처벌될 수 있습니다.'
        },
        en: {
            label: 'English',
            search: 'Search in this directory (type a file name)',
            colName: 'Name', colSize: 'Size', colDate: 'Modified',
            parent: 'Parent directory',
            noResults: 'No results found.',
            perPage: 'Per page',
            total: function (n, s, e) {
                return n.toLocaleString() + ' items · '
                     + s.toLocaleString() + '-' + e.toLocaleString();
            },
            date: function (d, p) {
                return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
                     + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
            },
            links: {
                mail: 'Contact by e-mail', dist: 'Use the distributed mirror',
                community: 'Join the community', kali: 'Kali Linux Korean docs',
                docs: 'ROKFOSS Docs', news: 'ROKFOSS Newsroom',
                status: 'ROKFOSS & partner mirror status'
            },
            sponsors: 'Sponsors',
            copyright: '© 2025-2026 ROKFOSS. All rights reserved | ROKFOSS PROJECT',
            legal: 'No unauthorized e-mail collection — Automated harvesting of e-mail addresses posted on this site is refused and is prohibited under the U.S. CAN-SPAM Act of 2003 and the UK Privacy and Electronic Communications Regulations 2003 (PECR).'
        },
        ja: {
            label: '日本語',
            search: 'このディレクトリ内を検索（ファイル名を入力）',
            colName: 'ファイル名', colSize: 'サイズ', colDate: '更新日時',
            parent: '親ディレクトリ',
            noResults: '検索結果がありません。',
            perPage: '1ページ',
            total: function (n, s, e) {
                return '全 ' + n.toLocaleString() + '件 · '
                     + s.toLocaleString() + '-' + e.toLocaleString();
            },
            date: function (d, p) {
                return d.getFullYear() + '年' + p(d.getMonth() + 1) + '月'
                     + p(d.getDate()) + '日 ' + p(d.getHours()) + '時'
                     + p(d.getMinutes()) + '分';
            },
            links: {
                mail: '公式メールで問い合わせ', dist: '分散ミラーを利用する',
                community: 'コミュニティに参加する', kali: 'Kali Linux 韓国語ドキュメント',
                docs: 'ROKFOSS Docs（ドキュメント）', news: 'ROKFOSS プロジェクトニュース',
                status: 'ROKFOSS および参加ミラーの稼働状況'
            },
            sponsors: '後援',
            copyright: '© 2025-2026 ROKFOSS. All rights reserved | ROKFOSS PROJECT',
            legal: '電子メールの無断収集お断り — 当サイトに掲載された電子メールアドレスを、メール収集プログラム等を用いて無断で収集することを拒否します。違反した場合、「特定電子メールの送信の適正化等に関する法律」（特定電子メール法）により処罰される場合があります。'
        },
        ru: {
            label: 'Русский',
            search: 'Поиск в этом каталоге (введите имя файла)',
            colName: 'Имя', colSize: 'Размер', colDate: 'Изменён',
            parent: 'Родительский каталог',
            noResults: 'Ничего не найдено.',
            perPage: 'На странице',
            total: function (n, s, e) {
                return 'Всего ' + n.toLocaleString() + ' · '
                     + s.toLocaleString() + '-' + e.toLocaleString();
            },
            date: function (d, p) {
                return p(d.getDate()) + '.' + p(d.getMonth() + 1) + '.' + d.getFullYear()
                     + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
            },
            links: {
                mail: 'Связаться по эл. почте', dist: 'Использовать распределённое зеркало',
                community: 'Присоединиться к сообществу', kali: 'Документация Kali Linux (кор.)',
                docs: 'ROKFOSS Docs', news: 'Новости проекта ROKFOSS',
                status: 'Статус ROKFOSS и зеркал-участников'
            },
            sponsors: 'Спонсоры',
            copyright: '© 2025-2026 ROKFOSS. Все права защищены | ROKFOSS PROJECT',
            legal: 'Отказ от несанкционированного сбора адресов эл. почты — Автоматизированный сбор адресов электронной почты, размещённых на этом сайте, не допускается и запрещён в соответствии с Федеральным законом РФ № 152-ФЗ «О персональных данных» и № 38-ФЗ «О рекламе».'
        }
    };

    function pickLang() {
        var saved = null;
        try { saved = localStorage.getItem('rokfoss_lang'); } catch (e) {}
        if (saved && I18N[saved]) return saved;
        var nav = (navigator.language || 'ko').toLowerCase();
        if (nav.indexOf('ja') === 0) return 'ja';
        if (nav.indexOf('ru') === 0) return 'ru';
        if (nav.indexOf('en') === 0) return 'en';
        return 'ko';
    }

    var lang = pickLang();
    var t = I18N[lang];

    // ── 데이터 ──────────────────────────────────────────────────
    var path = decodeURIComponent(location.pathname);

    function fmtSize(n) {
        if (typeof n !== 'number' || n < 0) return '-';
        if (n < 1024) return String(n);
        var u = ['K', 'M', 'G', 'T'], i = -1, v = n;
        do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
        return (v < 10 ? v.toFixed(1) : Math.round(v)) + u[i];
    }
    function pad(x) { return x < 10 ? '0' + x : x; }
    function fmtDate(iso) {
        var ms = Date.parse(iso);
        if (isNaN(ms)) return '';
        return t.date(new Date(ms), pad);
    }

    var items = [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var isDir = e.type === 'directory';
        items.push({
            href: encodeURIComponent(e.name) + (isDir ? '/' : ''),
            name: e.name,
            lower: e.name.toLowerCase(),
            isDirectory: isDir,
            sizeRaw: isDir ? -1 : (typeof e.size === 'number' ? e.size : -1),
            mtime: e.mtime
        });
    }
    items.sort(function (a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.localeCompare(b.name);
    });

    var hasParent = (path !== '/' && path !== '');

    // ── DOM 골격 ────────────────────────────────────────────────
    var titleEl = document.createElement('div');
    titleEl.className = 'idx-path-title';
    titleEl.textContent = path;
    container.appendChild(titleEl);

    var toolbar = document.createElement('div');
    toolbar.className = 'idx-toolbar';
    var search = document.createElement('input');
    search.type = 'search';
    search.className = 'idx-search';
    search.setAttribute('aria-label', 'search');
    toolbar.appendChild(search);
    container.appendChild(toolbar);

    var table = document.createElement('table');
    table.className = 'file-table';
    var thead = document.createElement('thead');
    var headRow = document.createElement('tr');
    var thName = document.createElement('th'); thName.className = 'file-name-header'; thName.setAttribute('scope', 'col');
    var thSize = document.createElement('th'); thSize.className = 'file-size-header'; thSize.setAttribute('scope', 'col');
    var thDate = document.createElement('th'); thDate.className = 'file-date-header'; thDate.setAttribute('scope', 'col');
    headRow.appendChild(thName); headRow.appendChild(thSize); headRow.appendChild(thDate);
    thead.appendChild(headRow); table.appendChild(thead);
    var tbody = document.createElement('tbody'); table.appendChild(tbody);

    var empty = document.createElement('div');
    empty.className = 'idx-empty';
    empty.hidden = true;

    function iconClass(it) {
        if (it.isDirectory) return 'fas fa-folder file-icon dir-icon';
        var ext = it.href.split('.').pop().toLowerCase();
        if (['jpg', 'jpeg', 'png', 'gif', 'svg'].indexOf(ext) >= 0) return 'fas fa-file-image file-icon';
        if (['mp4', 'webm', 'avi', 'mov'].indexOf(ext) >= 0) return 'fas fa-file-video file-icon';
        if (['mp3', 'wav', 'ogg'].indexOf(ext) >= 0) return 'fas fa-file-audio file-icon';
        if (ext === 'pdf') return 'fas fa-file-pdf file-icon';
        if (['zip', 'rar', 'tar', 'gz', 'xz', '7z', 'zst', 'bz2'].indexOf(ext) >= 0) return 'fas fa-file-archive file-icon';
        if (['exe', 'msi', 'deb', 'rpm', 'pkg', 'apk'].indexOf(ext) >= 0) return 'fas fa-cog file-icon';
        if (['iso', 'img'].indexOf(ext) >= 0) return 'fas fa-compact-disc file-icon';
        if (['md', 'txt'].indexOf(ext) >= 0 || it.href.indexOf('README') >= 0) return 'fas fa-file-alt file-icon';
        return 'fas fa-file file-icon';
    }

    function buildRow(it, isParent) {
        var row = document.createElement('tr');
        if (!isParent && it.href.toLowerCase().indexOf('readme') >= 0) row.classList.add('readme-file');
        var nameCell = document.createElement('td');
        var nameDiv = document.createElement('div'); nameDiv.className = 'file-name';
        var icon = document.createElement('i'); icon.setAttribute('aria-hidden', 'true');
        icon.className = isParent ? 'fas fa-folder file-icon dir-icon' : iconClass(it);
        nameDiv.appendChild(icon);
        var link = document.createElement('a'); link.className = 'file-link';
        link.href = isParent ? '../' : it.href;
        link.textContent = isParent ? t.parent : it.name;
        link.title = link.textContent;
        nameDiv.appendChild(link);
        nameCell.appendChild(nameDiv); row.appendChild(nameCell);
        var sizeCell = document.createElement('td'); sizeCell.className = 'file-size';
        sizeCell.textContent = isParent ? '-' : fmtSize(it.sizeRaw); row.appendChild(sizeCell);
        var dateCell = document.createElement('td'); dateCell.className = 'file-date';
        dateCell.textContent = isParent ? '' : fmtDate(it.mtime); row.appendChild(dateCell);
        return row;
    }

    // ── 페이지네이션 ────────────────────────────────────────────
    var PAGE_SIZES = [100, 200];
    var pageSize = 200, currentPage = 1, query = '', view = items;

    var bar = document.createElement('div'); bar.className = 'pagination-bar';
    var info = document.createElement('div'); info.className = 'pagination-info';
    var sizeBox = document.createElement('div'); sizeBox.className = 'page-size';
    var sizeLabel = document.createElement('span'); sizeLabel.className = 'ps-label';
    sizeBox.appendChild(sizeLabel);
    var sizeButtons = PAGE_SIZES.map(function (size) {
        var btn = document.createElement('button'); btn.type = 'button'; btn.textContent = size;
        btn.addEventListener('click', function () {
            if (pageSize === size) return;
            var first = (currentPage - 1) * pageSize;
            pageSize = size; currentPage = Math.floor(first / pageSize) + 1; renderPage();
        });
        sizeBox.appendChild(btn); return { size: size, btn: btn };
    });
    var nav = document.createElement('div'); nav.className = 'pagination';
    nav.setAttribute('role', 'navigation');
    bar.appendChild(info); bar.appendChild(sizeBox); bar.appendChild(nav);
    container.appendChild(bar); container.appendChild(table); container.appendChild(empty);

    function totalPages() { return Math.max(1, Math.ceil(view.length / pageSize)); }
    function pageNumbers(page, pages) {
        var r = [], span = 2, last = 0;
        for (var i = 1; i <= pages; i++) {
            if (i === 1 || i === pages || (i >= page - span && i <= page + span)) {
                if (last && i - last > 1) r.push('...');
                r.push(i); last = i;
            }
        }
        return r;
    }
    function navButton(label, target, opts) {
        var btn = document.createElement('button'); btn.type = 'button'; btn.textContent = label;
        if (opts && opts.disabled) btn.disabled = true;
        if (opts && opts.active) { btn.classList.add('active'); btn.setAttribute('aria-current', 'page'); }
        if (!(opts && opts.disabled) && !(opts && opts.active))
            btn.addEventListener('click', function () { goToPage(target); });
        return btn;
    }
    function renderControls() {
        var pages = totalPages();
        sizeButtons.forEach(function (it) { it.btn.classList.toggle('active', it.size === pageSize); });
        var start = view.length ? (currentPage - 1) * pageSize + 1 : 0;
        var end = Math.min(view.length, currentPage * pageSize);
        info.textContent = t.total(view.length, start, end);
        nav.replaceChildren();
        if (pages <= 1) return;
        nav.appendChild(navButton('«', currentPage - 1, { disabled: currentPage === 1 }));
        pageNumbers(currentPage, pages).forEach(function (n) {
            if (n === '...') {
                var s = document.createElement('span'); s.className = 'ellipsis'; s.textContent = '…';
                nav.appendChild(s);
            } else nav.appendChild(navButton(String(n), n, { active: n === currentPage }));
        });
        nav.appendChild(navButton('»', currentPage + 1, { disabled: currentPage === pages }));
    }
    function renderPage() {
        var pages = totalPages();
        if (currentPage < 1) currentPage = 1;
        if (currentPage > pages) currentPage = pages;
        var start = (currentPage - 1) * pageSize, end = Math.min(view.length, start + pageSize);
        var frag = document.createDocumentFragment();
        if (hasParent && !query && currentPage === 1) frag.appendChild(buildRow(null, true));
        for (var i = start; i < end; i++) frag.appendChild(buildRow(view[i], false));
        tbody.replaceChildren(frag);
        empty.hidden = view.length > 0 || !query;
        renderControls();
    }
    function goToPage(p) { if (p !== currentPage) { currentPage = p; renderPage(); } }

    var timer = null;
    search.addEventListener('input', function () {
        clearTimeout(timer);
        timer = setTimeout(function () {
            query = search.value.trim().toLowerCase();
            view = query ? items.filter(function (d) { return d.lower.indexOf(query) >= 0; }) : items;
            currentPage = 1; renderPage();
        }, 90);
    });

    // ── 언어 전환 (그 자리에서, 이동 없음) ───────────────────────
    function applyLang() {
        t = I18N[lang];
        document.documentElement.lang = lang;
        document.title = 'ROKFOSS | ' + path;
        search.placeholder = t.search;
        thName.textContent = t.colName; thSize.textContent = t.colSize; thDate.textContent = t.colDate;
        sizeLabel.textContent = t.perPage;
        empty.textContent = t.noResults;
        // 푸터/공통 요소 (data-i18n)
        applyChrome();
        renderPage();
        // 활성 버튼 표시
        var btns = document.querySelectorAll('[data-lang]');
        for (var i = 0; i < btns.length; i++)
            btns[i].classList.toggle('active', btns[i].getAttribute('data-lang') === lang);
    }
    function applyChrome() {
        var map = {
            'link-mail': t.links.mail, 'link-dist': t.links.dist,
            'link-community': t.links.community, 'link-kali': t.links.kali,
            'link-docs': t.links.docs, 'link-news': t.links.news,
            'link-status': t.links.status,
            'foot-sponsors-title': t.sponsors,
            'foot-copyright': t.copyright, 'foot-legal': t.legal
        };
        for (var id in map) {
            var el = document.getElementById(id);
            if (el) el.textContent = map[id];
        }
    }
    function setLang(l) {
        if (!I18N[l]) return;
        lang = l;
        try { localStorage.setItem('rokfoss_lang', l); } catch (e) {}
        applyLang();
    }
    // 네비게이션의 언어 버튼 연결 (mirror 로 이동하지 않음)
    var langBtns = document.querySelectorAll('[data-lang]');
    for (var b = 0; b < langBtns.length; b++) {
        (function (btn) {
            btn.addEventListener('click', function (ev) {
                ev.preventDefault();
                setLang(btn.getAttribute('data-lang'));
            });
        })(langBtns[b]);
    }

    applyLang();
})();
