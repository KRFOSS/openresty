(function () {
    // 데이터 소스: 서버가 심은 JSON (fancyindex 표 대신)
    var container = document.querySelector('.autoindex-container');
    var raw = document.getElementById('idx-data').textContent;
    var entries;
    try { entries = JSON.parse(raw); } catch (e) { entries = []; }

    var path = decodeURIComponent(location.pathname);
    document.title = 'ROKFOSS PROJECT | ' + path;

    // 크기: fancyindex 스타일 (K/M/G)
    function fmtSize(n) {
        if (typeof n !== 'number' || n < 0) return '-';
        if (n < 1024) return String(n);
        var u = ['K', 'M', 'G', 'T'], i = -1, v = n;
        do { v /= 1024; i++; } while (v >= 1024 && i < u.length - 1);
        return (v < 10 ? v.toFixed(1) : Math.round(v)) + u[i];
    }

    // 날짜: 기존 형식 "YYYY년 MM월 DD일 HH시 MM분"
    function fmtDate(iso) {
        var t = Date.parse(iso);
        if (isNaN(t)) return '';
        var d = new Date(t), p = function (x) { return x < 10 ? '0' + x : x; };
        return d.getFullYear() + '년 ' + p(d.getMonth() + 1) + '월 ' + p(d.getDate())
             + '일 ' + p(d.getHours()) + '시 ' + p(d.getMinutes()) + '분';
    }

    var data = [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var isDir = e.type === 'directory';
        var href = encodeURIComponent(e.name) + (isDir ? '/' : '');
        data.push({
            href: href,
            name: e.name,
            lower: e.name.toLowerCase(),
            isDirectory: isDir,
            size: isDir ? '-' : fmtSize(e.size),
            date: fmtDate(e.mtime)
        });
    }

    data.sort(function (a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.localeCompare(b.name);
    });

    // 상위 디렉토리 (루트가 아니면)
    var parent = null;
    if (path !== '/' && path !== '') {
        parent = { href: '../', name: '상위 디렉토리', isDirectory: true, size: '-', date: '' };
    }

    // 현재 경로 타이틀
    var title = document.createElement('div');
    title.className = 'idx-path-title';
    title.textContent = path;
    container.appendChild(title);

    // 검색창
    var toolbar = document.createElement('div');
    toolbar.className = 'idx-toolbar';
    var search = document.createElement('input');
    search.type = 'search';
    search.className = 'idx-search';
    search.placeholder = '이 디렉터리에서 검색 (파일명 입력)';
    search.setAttribute('aria-label', '파일 검색');
    toolbar.appendChild(search);
    container.appendChild(toolbar);

    var table = document.createElement('table');
    table.className = 'file-table';
    table.setAttribute('aria-label', '파일 목록');

    var thead = document.createElement('thead');
    var headerRow = document.createElement('tr');
    [
        { name: '파일 이름', class: 'file-name-header' },
        { name: '크기', class: 'file-size-header' },
        { name: '수정일', class: 'file-date-header' }
    ].forEach(function (h) {
        var th = document.createElement('th');
        th.setAttribute('scope', 'col');
        th.textContent = h.name;
        th.className = h.class;
        headerRow.appendChild(th);
    });
    thead.appendChild(headerRow);
    table.appendChild(thead);
    var tbody = document.createElement('tbody');
    table.appendChild(tbody);

    var empty = document.createElement('div');
    empty.className = 'idx-empty';
    empty.textContent = '검색 결과가 없습니다.';
    empty.hidden = true;

    function buildRow(d) {
        var row = document.createElement('tr');
        if (d.href.toLowerCase().indexOf('readme') >= 0) {
            row.classList.add('readme-file');
        }

        var nameCell = document.createElement('td');
        var nameDiv = document.createElement('div');
        nameDiv.className = 'file-name';

        var icon = document.createElement('i');
        icon.setAttribute('aria-hidden', 'true');

        if (d.isDirectory) {
            icon.className = 'fas fa-folder file-icon dir-icon';
        } else {
            var ext = d.href.split('.').pop().toLowerCase();
            var iconClass = 'fas fa-file file-icon';
            if (['jpg', 'jpeg', 'png', 'gif', 'svg'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-file-image file-icon';
            } else if (['mp4', 'webm', 'avi', 'mov'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-file-video file-icon';
            } else if (['mp3', 'wav', 'ogg'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-file-audio file-icon';
            } else if (['pdf'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-file-pdf file-icon';
            } else if (['zip', 'rar', 'tar', 'gz', 'xz', '7z', 'zst', 'bz2'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-file-archive file-icon';
            } else if (['exe', 'msi', 'deb', 'rpm', 'pkg', 'apk'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-cog file-icon';
            } else if (['iso', 'img'].indexOf(ext) >= 0) {
                iconClass = 'fas fa-compact-disc file-icon';
            } else if (['md', 'txt'].indexOf(ext) >= 0 || d.href.indexOf('README') >= 0) {
                iconClass = 'fas fa-file-alt file-icon';
            }
            icon.className = iconClass;
        }
        nameDiv.appendChild(icon);

        var link = document.createElement('a');
        link.href = d.href;
        link.className = 'file-link';
        link.textContent = d.name;
        link.title = d.name;
        nameDiv.appendChild(link);

        nameCell.appendChild(nameDiv);
        row.appendChild(nameCell);

        var sizeCell = document.createElement('td');
        sizeCell.className = 'file-size';
        sizeCell.textContent = d.size;
        row.appendChild(sizeCell);

        var dateCell = document.createElement('td');
        dateCell.className = 'file-date';
        dateCell.textContent = d.date;
        row.appendChild(dateCell);

        return row;
    }

    // 페이지네이션
    var PAGE_SIZES = [100, 200];
    var pageSize = 200;
    var currentPage = 1;
    var query = '';
    var view = data;

    var bar = document.createElement('div');
    bar.className = 'pagination-bar';
    var info = document.createElement('div');
    info.className = 'pagination-info';
    var sizeBox = document.createElement('div');
    sizeBox.className = 'page-size';
    var sizeLabel = document.createElement('span');
    sizeLabel.className = 'ps-label';
    sizeLabel.textContent = '페이지당';
    sizeBox.appendChild(sizeLabel);
    var sizeButtons = PAGE_SIZES.map(function (size) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.textContent = size;
        btn.addEventListener('click', function () {
            if (pageSize === size) return;
            var firstIndex = (currentPage - 1) * pageSize;
            pageSize = size;
            currentPage = Math.floor(firstIndex / pageSize) + 1;
            renderPage();
        });
        sizeBox.appendChild(btn);
        return { size: size, btn: btn };
    });
    var nav = document.createElement('div');
    nav.className = 'pagination';
    nav.setAttribute('role', 'navigation');
    nav.setAttribute('aria-label', '페이지 탐색');
    bar.appendChild(info);
    bar.appendChild(sizeBox);
    bar.appendChild(nav);

    container.appendChild(bar);
    container.appendChild(table);
    container.appendChild(empty);

    function totalPages() {
        return Math.max(1, Math.ceil(view.length / pageSize));
    }

    function pageNumbers(page, pages) {
        var result = [], span = 2, last = 0;
        for (var i = 1; i <= pages; i++) {
            if (i === 1 || i === pages || (i >= page - span && i <= page + span)) {
                if (last && i - last > 1) result.push('...');
                result.push(i);
                last = i;
            }
        }
        return result;
    }

    function navButton(label, targetPage, opts) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.textContent = label;
        if (opts && opts.disabled) btn.disabled = true;
        if (opts && opts.active) {
            btn.classList.add('active');
            btn.setAttribute('aria-current', 'page');
        }
        if (opts && opts.ariaLabel) btn.setAttribute('aria-label', opts.ariaLabel);
        if (!(opts && opts.disabled) && !(opts && opts.active)) {
            btn.addEventListener('click', function () { goToPage(targetPage); });
        }
        return btn;
    }

    function renderControls() {
        var pages = totalPages();
        sizeButtons.forEach(function (item) {
            item.btn.classList.toggle('active', item.size === pageSize);
        });
        var start = view.length ? (currentPage - 1) * pageSize + 1 : 0;
        var end = Math.min(view.length, currentPage * pageSize);
        info.textContent = '총 ' + view.length.toLocaleString() + '개 · '
                         + start.toLocaleString() + '-' + end.toLocaleString();
        nav.replaceChildren();
        if (pages <= 1) return;
        nav.appendChild(navButton('«', currentPage - 1, {
            disabled: currentPage === 1, ariaLabel: '이전 페이지'
        }));
        pageNumbers(currentPage, pages).forEach(function (n) {
            if (n === '...') {
                var span = document.createElement('span');
                span.className = 'ellipsis';
                span.textContent = '…';
                nav.appendChild(span);
            } else {
                nav.appendChild(navButton(String(n), n, { active: n === currentPage }));
            }
        });
        nav.appendChild(navButton('»', currentPage + 1, {
            disabled: currentPage === pages, ariaLabel: '다음 페이지'
        }));
    }

    function renderPage() {
        var pages = totalPages();
        if (currentPage < 1) currentPage = 1;
        if (currentPage > pages) currentPage = pages;

        var start = (currentPage - 1) * pageSize;
        var end = Math.min(view.length, start + pageSize);

        var frag = document.createDocumentFragment();
        // 검색 중이 아니고 첫 페이지면 상위 디렉토리를 맨 위에
        if (parent && !query && currentPage === 1) {
            frag.appendChild(buildRow(parent));
        }
        for (var i = start; i < end; i++) {
            frag.appendChild(buildRow(view[i]));
        }
        tbody.replaceChildren(frag);
        empty.hidden = view.length > 0 || !query;
        renderControls();
    }

    function goToPage(page) {
        if (page === currentPage) return;
        currentPage = page;
        renderPage();
    }

    var timer = null;
    search.addEventListener('input', function () {
        clearTimeout(timer);
        timer = setTimeout(function () {
            query = search.value.trim().toLowerCase();
            if (!query) {
                view = data;
            } else {
                view = data.filter(function (d) { return d.lower.indexOf(query) >= 0; });
            }
            currentPage = 1;
            renderPage();
        }, 90);
    });

    renderPage();
})();
