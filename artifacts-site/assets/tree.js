/* Sidebar file tree for the GPUWorks artifacts browser.
   Loads tree.json (generated at build time), renders a collapsible tree,
   highlights and expands the path to the current page, and wires the
   mobile drawer. Also marks framed documents (rendered pages opened
   inside a wrapper iframe) so CSS can hide the duplicate chrome. */
(function () {
  'use strict';

  var script = document.currentScript;
  var base = '/artifacts/';
  if (script && script.src) {
    var m = script.src.match(/^(.*)\/_assets\/tree\.js/);
    if (m) base = m[1] + '/';
  }

  if (window.self !== window.top) {
    document.documentElement.classList.add('framed');
  }

  var tree = document.getElementById('tree');
  if (tree) {
    fetch(base + '_assets/tree.json', { credentials: 'same-origin' })
      .then(function (r) { if (!r.ok) throw new Error(String(r.status)); return r.json(); })
      .then(function (data) {
        renderRoot(data, tree);
        revealCurrent(tree);
      })
      .catch(function () {
        tree.textContent = '目录加载失败';
      });
  }

  function renderRoot(data, container) {
    var ul = document.createElement('ul');
    if (data.t === 'd' && data.ch) {
      for (var i = 0; i < data.ch.length; i++) ul.appendChild(node(data.ch[i]));
    }
    container.appendChild(ul);
  }

  function node(n) {
    var li = document.createElement('li');
    if (n.t === 'd') {
      li.className = 'node-dir';
      var row = document.createElement('div');
      row.className = 'row';
      var tgl = document.createElement('button');
      tgl.className = 'tgl';
      tgl.type = 'button';
      tgl.textContent = '▶';
      tgl.setAttribute('aria-expanded', 'false');
      tgl.setAttribute('aria-label', '展开 ' + n.n);
      var a = document.createElement('a');
      a.className = 'dir-link';
      a.href = n.h;
      a.textContent = n.n;
      if (n.title) a.title = n.title;
      row.appendChild(tgl);
      row.appendChild(a);
      li.appendChild(row);
      var ul = document.createElement('ul');
      ul.className = 'children';
      (n.ch || []).forEach(function (c) { ul.appendChild(node(c)); });
      li.appendChild(ul);
      tgl.addEventListener('click', function () {
        var open = li.classList.toggle('open');
        tgl.setAttribute('aria-expanded', open ? 'true' : 'false');
      });
    } else {
      var a2 = document.createElement('a');
      a2.className = 'row leaf';
      a2.href = n.h;
      a2.textContent = n.n;
      if (n.title) a2.title = n.title;
      li.appendChild(a2);
    }
    return li;
  }

  function revealCurrent(container) {
    var here = location.pathname;
    var links = container.querySelectorAll('a');
    var best = null;
    for (var i = 0; i < links.length; i++) {
      if (links[i].getAttribute('href') === here) { best = links[i]; break; }
    }
    if (!best) {
      // rendered markdown page URL vs tree entry: allow /x/y -> /x/y/ and index.html forms
      var alt = here.replace(/index\.html$/, '');
      for (var j = 0; j < links.length; j++) {
        if (links[j].getAttribute('href') === alt) { best = links[j]; break; }
      }
    }
    if (!best) {
      var first = container.querySelector('li.node-dir');
      if (first) first.classList.add('open');
      return;
    }
    best.classList.add('current');
    var p = best.closest ? best.closest('li') : null;
    while (p) {
      if (p.classList.contains('node-dir')) {
        p.classList.add('open');
        var b = p.querySelector('.tgl');
        if (b) b.setAttribute('aria-expanded', 'true');
      }
      p = p.parentElement ? (p.parentElement.closest ? p.parentElement.closest('li') : null) : null;
    }
    if (best.scrollIntoView) {
      try { best.scrollIntoView({ block: 'center' }); } catch (e) { /* older engines */ }
    }
  }

  // mobile drawer
  var menuBtn = document.getElementById('menu-btn');
  var closeBtn = document.getElementById('sidebar-close');
  var backdrop = document.getElementById('sidebar-backdrop');
  function closeDrawer() { document.body.classList.remove('sidebar-open'); }
  if (menuBtn) menuBtn.addEventListener('click', function () {
    document.body.classList.toggle('sidebar-open');
  });
  if (closeBtn) closeBtn.addEventListener('click', closeDrawer);
  if (backdrop) backdrop.addEventListener('click', closeDrawer);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeDrawer();
  });
})();
