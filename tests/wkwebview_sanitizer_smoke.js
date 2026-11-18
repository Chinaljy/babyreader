(async () => {
  const failures = [];
  const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const assert = (condition, message) => { if (!condition) failures.push(message); };

  window.__probe = [];
  // Payloads call this; if anything fires, the document ran script.
  window.__hit = (tag) => window.__probe.push(tag);

  // 1. Markdown with raw HTML event handlers and script URLs.
  const markdown = [
    '# Sanitizer smoke',
    '',
    '<img src="x" onerror="__hit(\'md-img\')">',
    '<details open ontoggle="__hit(\'md-details\')"><summary>s</summary>d</details>',
    '<svg><animate onbegin="__hit(\'md-animate\')" attributeName="x" dur="1s"/></svg>',
    '<iframe src="javascript:__hit(\'md-iframe\')"></iframe>',
    '[link](javascript:__hit(\'md-link\'))',
    '<a href="java&#115;cript:__hit(\'md-entity\')">entity</a>',
    '',
    'Body **kept**.'
  ].join('\n');

  await window.appHost.receiveDocument({
    path: '/tmp/babyreader-sanitizer-smoke.md',
    name: 'babyreader-sanitizer-smoke.md',
    type: 'text',
    content: markdown
  });
  await sleep(400);

  const article = document.querySelector('#article');
  assert(article && article.innerText.includes('Body kept.'), 'Markdown body text was not rendered');
  assert(article.querySelector('h1, .is-title'), 'Markdown heading was lost');
  assert(!article.querySelector('[onerror],[ontoggle],[onbegin],iframe,animate'), 'Dangerous markup survived in Markdown');
  for (const a of article.querySelectorAll('a[href]')) {
    assert(!/^\s*javascript:/i.test(a.getAttribute('href')), 'javascript: href survived in Markdown');
  }

  // 2. EPUB-style payloads that bypassed the old regex sanitizer.
  const epubOut = window.sanitizeDocumentHtml(
    '<p>ch1</p><svg/onload="__hit(\'ep-svg\')"></svg>' +
    '<img/src="x"/onerror="__hit(\'ep-img\')">' +
    '<a href="#br-chapter-2">next</a>' +
    '<img src="data:image/png;base64,iVBORw0KGgo=">' +
    '<a href="data:text/html,<script>__hit(1)</script>">d</a>'
  );
  assert(!/onload|onerror/i.test(epubOut), 'EPUB event handler survived sanitizeDocumentHtml');
  assert(/href="#br-chapter-2"/.test(epubOut), 'Internal EPUB link was removed');
  assert(/src="data:image\/png/.test(epubOut), 'Inline EPUB image was removed');
  assert(!/data:text\/html/.test(epubOut), 'data:text/html link survived');

  // 3. CSP blocks inline script even if markup slipped through.
  const s = document.createElement('script');
  s.textContent = "__hit('csp-inline')";
  document.head.appendChild(s);

  await sleep(400);
  assert(window.__probe.length === 0, 'Document script executed: ' + JSON.stringify(window.__probe));

  return { ok: failures.length === 0, failures, probe: window.__probe };
})()
