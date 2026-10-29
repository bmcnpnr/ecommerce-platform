// Builds every Markdown file under ../docs into one navigable PDF:
//   cover → contents (every document and its sections, all clickable) → one part per
//   group of documents, each document on a new page. Mermaid diagrams are rendered,
//   links between docs become in-PDF jumps, and the PDF gets a bookmark tree
//   (Part > Document > Section) for the viewer's sidebar.
//
//   npm run build                 # once
//   npm run watch                 # rebuild whenever a file under docs/ changes
//   node build-pdf.mjs --out some/file.pdf
//
// Adding or removing a doc needs no change here: documents are discovered from the
// folder. PARTS below only decides grouping and order; anything it doesn't name is
// added at the end of its folder's part, or under "Other documents".
//
// Needs a local Chrome or Edge (set CHROME_PATH to override the lookup).
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';
import GithubSlugger from 'github-slugger';
import puppeteer from 'puppeteer-core';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DOCS = path.resolve(HERE, '../docs');
const PLATFORM = path.resolve(HERE, '..');
const WORKSPACE = path.resolve(PLATFORM, '..');
const GITHUB_OWNER = 'bmcnpnr';
const TITLE = 'Ecommerce platform documentation';

const args = process.argv.slice(2);
const OUT = path.resolve(args.includes('--out') ? args[args.indexOf('--out') + 1] : path.join(PLATFORM, 'dist/ecommerce-platform-documentation.pdf'));
const WATCH = args.includes('--watch');
const HTML_OUT = args.includes('--html') ? path.resolve(args[args.indexOf('--html') + 1]) : null; // debug: also save the HTML

// Grouping and order. A name ending in "/" means "every document in that folder":
// the ones listed in `order` first, then the rest alphabetically. Missing files are skipped.
const PARTS = [
  { title: 'Start here', entries: ['README.md', 'architecture.md', 'communication.md', 'flows.md', 'onboarding.md'] },
  {
    title: 'Services',
    entries: ['services/'],
    order: ['api-gateway.md', 'service-discovery.md', 'user-service.md', 'product-service.md', 'catalog-service.md',
      'order-service.md', 'payment-service.md', 'shipping-service.md', 'review-service.md', 'notification-service.md'],
  },
  { title: 'Frontend', entries: ['frontend.md'] },
  {
    title: 'API reference',
    entries: ['api/'],
    order: ['README.md', 'user-service.md', 'product-service.md', 'catalog-service.md', 'order-service.md',
      'payment-service.md', 'shipping-service.md', 'review-service.md'],
  },
  { title: 'Events, data and security', entries: ['events.md', 'data-model.md', 'security.md'] },
  { title: 'Operations', entries: ['observability.md', 'runbook.md', 'testing.md'] },
  { title: 'Decisions and findings', entries: ['findings.md', 'adr/'], order: ['README.md'] },
];

// ── Discover and group documents ───────────────────────────────────────────────

const listMarkdown = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  const full = path.join(dir, e.name);
  if (e.isDirectory()) return listMarkdown(full);
  return e.name.endsWith('.md') ? [path.relative(DOCS, full).split(path.sep).join('/')] : [];
});

function planParts() {
  const all = listMarkdown(DOCS);
  const claimed = new Set();
  const parts = PARTS.map((part) => {
    const docs = [];
    for (const entry of part.entries) {
      if (entry.endsWith('/')) {
        const inDir = all.filter((f) => path.posix.dirname(f) === entry.slice(0, -1));
        const rank = (f) => {
          const i = (part.order ?? []).indexOf(path.posix.basename(f));
          return i === -1 ? Infinity : i;
        };
        inDir.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
        docs.push(...inDir.filter((f) => !claimed.has(f)));
      } else if (all.includes(entry) && !claimed.has(entry)) {
        docs.push(entry);
      }
      docs.forEach((f) => claimed.add(f));
    }
    return { title: part.title, docs };
  });
  const rest = all.filter((f) => !claimed.has(f)).sort();
  if (rest.length) parts.push({ title: 'Other documents', docs: rest });
  return parts.filter((p) => p.docs.length);
}

// ── Markdown → HTML with in-PDF links ──────────────────────────────────────────

const docId = (rel) => 'doc-' + rel.replace(/\.md$/, '').replace(/[^a-zA-Z0-9]+/g, '-').toLowerCase();
const escapeHtml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const plain = (md) => md.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[`*_]/g, '').trim();

function githubUrl(absPath) {
  const rel = path.relative(WORKSPACE, absPath).split(path.sep);
  if (rel[0] === '..' || rel.length < 1) return null;
  const [repo, ...rest] = rel;
  return `https://github.com/${GITHUB_OWNER}/${repo}/blob/develop/${rest.join('/')}`;
}

function renderDoc(rel, knownDocs) {
  const id = docId(rel);
  const slugger = new GithubSlugger();
  const sections = [];
  let title = null;

  const resolveLink = (href) => {
    if (/^[a-z]+:/i.test(href)) return href;
    const [target, anchor] = href.split('#');
    if (!target) return `#${id}--${anchor}`;
    const abs = path.resolve(DOCS, path.posix.dirname(rel), decodeURI(target));
    const relToDocs = path.relative(DOCS, abs).split(path.sep).join('/');
    if (knownDocs.has(relToDocs)) return anchor ? `#${docId(relToDocs)}--${anchor}` : `#${docId(relToDocs)}`;
    // A folder inside docs/: jump to its first document, if it has one.
    const firstInDir = [...knownDocs].find((d) => d.startsWith(relToDocs.replace(/\/?$/, '/')));
    if (!relToDocs.startsWith('..') && firstInDir) return `#${docId(firstInDir)}`;
    return githubUrl(abs) ?? href;
  };

  const marked = new Marked({ gfm: true });
  marked.use({
    renderer: {
      heading({ tokens, depth, text }) {
        const slug = slugger.slug(plain(text));
        const inner = this.parser.parseInline(tokens);
        if (depth === 1 && !title) {
          title = plain(text);
          return `<h2 class="doc-title" id="${id}--${slug}">${inner}</h2>`;
        }
        if (depth === 2) sections.push({ text: plain(text), anchor: `${id}--${slug}` });
        const level = Math.min(depth + 1, 6); // h1 = part, h2 = document, h3+ = its sections
        return `<h${level} id="${id}--${slug}">${inner}</h${level}>`;
      },
      link({ href, title: t, tokens }) {
        const target = resolveLink(href);
        const external = /^https?:/.test(target);
        return `<a href="${escapeHtml(target)}"${t ? ` title="${escapeHtml(t)}"` : ''}${external ? ' class="ext"' : ''}>${this.parser.parseInline(tokens)}</a>`;
      },
      code({ text, lang }) {
        if (lang === 'mermaid') return `<pre class="mermaid">${escapeHtml(text)}</pre>`;
        return `<pre><code>${escapeHtml(text)}</code></pre>`;
      },
    },
  });

  const body = marked.parse(fs.readFileSync(path.join(DOCS, rel), 'utf8'));
  return { rel, id, title: title ?? rel, sections, body };
}

// ── Page assembly ──────────────────────────────────────────────────────────────

function gitRevision() {
  try {
    return execSync('git rev-parse --short HEAD', { cwd: PLATFORM, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
  } catch {
    return 'unknown';
  }
}

function buildHtml(parts) {
  const knownDocs = new Set(parts.flatMap((p) => p.docs));
  const rendered = parts.map((p, i) => ({ ...p, number: i + 1, docs: p.docs.map((d) => renderDoc(d, knownDocs)) }));
  const date = new Date().toISOString().slice(0, 10);

  const contents = rendered.map((p) => `
    <section class="toc-part">
      <h3><a href="#part-${p.number}">Part ${p.number} · ${escapeHtml(p.title)}</a></h3>
      <ol>${p.docs.map((d) => `
        <li><a class="toc-doc" href="#${d.id}">${escapeHtml(d.title)}</a>
          ${d.sections.length ? `<div class="toc-sections">${d.sections.map((s) => `<a href="#${s.anchor}">${escapeHtml(s.text)}</a>`).join('<span>·</span>')}</div>` : ''}
        </li>`).join('')}
      </ol>
    </section>`).join('');

  const body = rendered.map((p) => `
    <section class="part" id="part-${p.number}">
      <div class="part-label">Part ${p.number}</div>
      <h1>${escapeHtml(p.title)}</h1>
      <ol class="part-docs">${p.docs.map((d) => `<li><a href="#${d.id}">${escapeHtml(d.title)}</a></li>`).join('')}</ol>
    </section>
    ${p.docs.map((d) => `
    <article class="doc" id="${d.id}">
      <div class="crumb">Part ${p.number} · ${escapeHtml(p.title)} &nbsp;›&nbsp; <span>${escapeHtml(d.rel)}</span></div>
      ${d.body}
    </article>`).join('')}`).join('');

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${TITLE}</title>
<style>${fs.readFileSync(path.join(HERE, 'pdf.css'), 'utf8')}</style></head><body>
<section class="cover">
  <div class="cover-kicker">ecommerce-platform</div>
  <h1 class="cover-title">${TITLE}</h1>
  <p class="cover-sub">Architecture, services, APIs, events, data, security, operations and decisions.</p>
  <p class="cover-meta">Built ${date} from <code>docs/</code> at commit <code>${gitRevision()}</code></p>
  <p class="cover-hint">Use the contents on the next page, or open your PDF viewer's bookmarks panel: every part, document and section is listed there.</p>
</section>
<section class="toc"><h1 class="toc-title">Contents</h1>${contents}</section>
${body}
</body></html>`;
}

// ── Rendering ──────────────────────────────────────────────────────────────────

function findBrowser() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ].filter(Boolean);
  const found = candidates.find((p) => fs.existsSync(p));
  if (!found) throw new Error('No Chrome or Edge found. Set CHROME_PATH to a Chromium-based browser executable.');
  return found;
}

async function render(browser) {
  const started = Date.now();
  const parts = planParts();
  const html = buildHtml(parts);
  if (HTML_OUT) fs.writeFileSync(HTML_OUT, html);
  const page = await browser.newPage();
  try {
    await page.setContent(html, { waitUntil: 'load', timeout: 120_000 });
    await page.addScriptTag({ path: path.join(HERE, 'node_modules/mermaid/dist/mermaid.min.js') });
    const failures = await page.evaluate(async () => {
      /* global mermaid */
      mermaid.initialize({ startOnLoad: false, theme: 'neutral', securityLevel: 'loose',
        flowchart: { useMaxWidth: true }, sequence: { useMaxWidth: true }, er: { useMaxWidth: true } });
      const failed = [];
      for (const el of document.querySelectorAll('pre.mermaid')) {
        try {
          await mermaid.run({ nodes: [el] });
        } catch (e) {
          failed.push(String(e?.message ?? e).split('\n')[0]);
        }
      }
      await document.fonts.ready;
      return failed;
    });
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    await page.pdf({
      path: OUT,
      format: 'A4',
      printBackground: true,
      outline: true, // bookmarks from h1 (part) > h2 (document) > h3 (section)
      tagged: true,
      displayHeaderFooter: true,
      margin: { top: '18mm', bottom: '16mm', left: '15mm', right: '15mm' },
      headerTemplate: `<div style="font-size:7.5px;color:#888;width:100%;padding:0 15mm;font-family:Segoe UI,Arial,sans-serif">${TITLE}</div>`,
      footerTemplate: '<div style="font-size:7.5px;color:#888;width:100%;padding:0 15mm;text-align:right;font-family:Segoe UI,Arial,sans-serif">Page <span class="pageNumber"></span> of <span class="totalPages"></span></div>',
      timeout: 300_000,
    });
    const docs = parts.reduce((n, p) => n + p.docs.length, 0);
    const kb = Math.round(fs.statSync(OUT).size / 1024);
    console.log(`${OUT}\n  ${parts.length} parts, ${docs} documents, ${kb} KB, ${((Date.now() - started) / 1000).toFixed(1)}s`);
    if (failures.length) console.warn(`  ${failures.length} diagram(s) failed to render:\n  - ${failures.join('\n  - ')}`);
  } finally {
    await page.close();
  }
}

const browser = await puppeteer.launch({ executablePath: findBrowser(), headless: true });
try {
  await render(browser);
  if (WATCH) {
    console.log(`Watching ${DOCS} for changes (Ctrl+C to stop)...`);
    let timer = null;
    let running = Promise.resolve();
    fs.watch(DOCS, { recursive: true }, (_event, file) => {
      if (!file || !file.endsWith('.md')) return;
      clearTimeout(timer);
      timer = setTimeout(() => {
        running = running.then(() => render(browser)).catch((e) => console.error(e.message));
      }, 800);
    });
    await new Promise(() => {});
  }
} finally {
  if (!WATCH) await browser.close();
}
