// JavaScript injected into browser pages, kept as Swift literals so BrowserKit needs no
// resource bundle.
//
// Two worlds:
// - `consoleCapture` runs in the *page* world at document start: it must wrap the page's own
//   `console`, `fetch` and `XMLHttpRequest`.
// - `automation` and `picker` run in an isolated content world: the page can't see or
//   tamper with them (no clobbered globals, no fake `__mship`), while the DOM is shared, so
//   events they dispatch reach the page's listeners normally.

enum BrowserScripts {
    static let consoleHandler = "mshipConsole"
    static let pickerHandler = "mshipPicker"
    static let worldName = "mothership"

    static let consoleCapture = #"""
    (() => {
      if (window.__mshipConsoleInstalled) return;
      Object.defineProperty(window, '__mshipConsoleInstalled', { value: true });
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mshipConsole;
      if (!handler) return;
      const format = (value) => {
        if (typeof value === 'string') return value;
        if (value === undefined) return 'undefined';
        if (value instanceof Error) {
          const stack = value.stack || '';
          return stack.includes(value.message) ? stack : `${value.name}: ${value.message}${stack ? '\n' + stack : ''}`;
        }
        if (typeof value === 'function') return `[Function ${value.name || 'anonymous'}]`;
        if (typeof value === 'symbol' || typeof value === 'bigint') return value.toString();
        if (typeof Element !== 'undefined' && value instanceof Element) {
          return `<${value.tagName.toLowerCase()}${value.id ? '#' + value.id : ''}>`;
        }
        try {
          const seen = new WeakSet();
          return JSON.stringify(value, (key, item) => {
            if (typeof item === 'bigint') return item.toString() + 'n';
            if (typeof item === 'object' && item !== null) {
              if (seen.has(item)) return '[Circular]';
              seen.add(item);
            }
            return item;
          });
        } catch (_) {
          return String(value);
        }
      };
      const post = (level, parts) => {
        try {
          const message = parts.map(format).join(' ');
          handler.postMessage({ level, message: message.length > 8000 ? message.slice(0, 8000) + '…' : message, time: Date.now() });
        } catch (_) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        if (typeof original !== 'function') continue;
        console[level] = function (...args) {
          post(level, args);
          return original.apply(this, args);
        };
      }
      window.addEventListener('error', (event) => {
        const target = event.target;
        if (target && target !== window && (target.src || target.href)) {
          post('network', [`Failed to load ${target.tagName.toLowerCase()} ${target.src || target.href}`]);
          return;
        }
        if (event.error instanceof Error) {
          post('exception', [event.error]);
        } else {
          const where = event.filename ? ` (${event.filename}:${event.lineno}:${event.colno})` : '';
          post('exception', [`${event.message}${where}`]);
        }
      }, true);
      window.addEventListener('unhandledrejection', (event) => {
        post('rejection', ['Unhandled promise rejection:', event.reason]);
      });
      const originalFetch = window.fetch;
      if (typeof originalFetch === 'function') {
        window.fetch = function (input, init) {
          const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
          const url = typeof input === 'string' ? input : (input && input.url) || String(input);
          return originalFetch.apply(this, arguments).then((response) => {
            if (!response.ok && response.type !== 'opaque') {
              post('network', [`${method} ${url} → ${response.status} ${response.statusText || ''}`.trim()]);
            }
            return response;
          }, (error) => {
            if (!(error && error.name === 'AbortError')) {
              post('network', [`${method} ${url} failed: ${(error && error.message) || error}`]);
            }
            throw error;
          });
        };
      }
      const XHR = window.XMLHttpRequest;
      if (XHR && XHR.prototype) {
        const open = XHR.prototype.open;
        const send = XHR.prototype.send;
        XHR.prototype.open = function (method, url) {
          this.__mship = { method: String(method || 'GET').toUpperCase(), url: String(url), aborted: false };
          return open.apply(this, arguments);
        };
        XHR.prototype.send = function () {
          const info = this.__mship || { method: 'GET', url: '?' };
          this.addEventListener('abort', () => { info.aborted = true; });
          this.addEventListener('loadend', () => {
            if (info.aborted) return;
            if (this.status === 0) post('network', [`${info.method} ${info.url} failed (network error)`]);
            else if (this.status >= 400) post('network', [`${info.method} ${info.url} → ${this.status} ${this.statusText || ''}`.trim()]);
          });
          return send.apply(this, arguments);
        };
      }
    })();
    """#

    /// Defines `window.__mship` in the isolated world on first use; later calls reuse it (and
    /// its ref table) for as long as the document lives.
    static let automation = #"""
    if (!window.__mship) {
      window.__mship = (() => {
        const REF_ATTR = 'data-mship-ref';
        const refs = new Map();
        let counter = 0;
        const MAX_LINES = 1500;
        const MAX_CHARS = 60000;
        const MAX_TEXT = 300;

        const collapse = (text) => String(text || '').replace(/\s+/g, ' ').trim();
        const clip = (text, max) => text.length > max ? text.slice(0, max - 1) + '…' : text;
        const quote = (text) => JSON.stringify(text);

        function refFor(el) {
          let ref = el.getAttribute(REF_ATTR);
          if (ref && refs.has(ref)) {
            const known = refs.get(ref).deref();
            if (known === el) return ref;
            if (known && known.isConnected) ref = null;  // copied attribute (cloneNode): mint a new ref
          }
          if (!ref || !/^e\d+$/.test(ref)) ref = 'e' + (++counter);
          else counter = Math.max(counter, parseInt(ref.slice(1), 10) || 0);
          el.setAttribute(REF_ATTR, ref);
          refs.set(ref, new WeakRef(el));
          return ref;
        }

        const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'META', 'LINK', 'HEAD', 'TITLE', 'BASE', 'MSHIP-PICKER']);
        const BLOCK = new Set(['P', 'DIV', 'LI', 'SECTION', 'ARTICLE', 'HEADER', 'FOOTER', 'UL', 'OL', 'TABLE', 'TR', 'TD', 'TH',
          'BLOCKQUOTE', 'PRE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'FORM', 'FIELDSET', 'DL', 'DT', 'DD', 'FIGURE',
          'FIGCAPTION', 'BR', 'HR', 'MAIN', 'NAV', 'ASIDE', 'DETAILS', 'SUMMARY', 'LABEL', 'BODY', 'DIALOG']);
        const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox',
          'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
          'treeitem', 'clickable']);
        const LEAF = new Set([...INTERACTIVE, 'heading', 'img', 'progressbar', 'meter', 'separator', 'iframe', 'video', 'audio']);
        const NAME_FROM_CONTENT = new Set(['button', 'link', 'heading', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
          'option', 'treeitem', 'switch', 'checkbox', 'radio', 'cell', 'columnheader', 'rowheader', 'clickable']);
        const SECTIONING = new Set(['ARTICLE', 'ASIDE', 'MAIN', 'NAV', 'SECTION']);
        const TEXT_INPUTS = new Set(['', 'text', 'email', 'tel', 'url', 'password', 'date', 'datetime-local', 'month', 'time', 'week', 'color']);

        function inputRole(el) {
          const type = (el.getAttribute('type') || '').toLowerCase();
          if (type === 'hidden') return null;
          if (['button', 'submit', 'reset', 'image', 'file'].includes(type)) return 'button';
          if (type === 'checkbox') return el.getAttribute('role') === 'switch' ? 'switch' : 'checkbox';
          if (type === 'radio') return 'radio';
          if (type === 'range') return 'slider';
          if (type === 'number') return 'spinbutton';
          if (type === 'search') return 'searchbox';
          if (el.list) return 'combobox';
          return 'textbox';
        }

        function insideSectioning(el) {
          for (let node = el.parentElement; node; node = node.parentElement) {
            if (SECTIONING.has(node.tagName)) return true;
          }
          return false;
        }

        function roleOf(el) {
          const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
          if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
          if (explicit === 'presentation' || explicit === 'none') return null;
          switch (el.tagName) {
            case 'A': return el.hasAttribute('href') ? 'link' : null;
            case 'AREA': return el.hasAttribute('href') ? 'link' : null;
            case 'BUTTON': return 'button';
            case 'SUMMARY': return 'button';
            case 'INPUT': return inputRole(el);
            case 'TEXTAREA': return 'textbox';
            case 'SELECT': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
            case 'OPTION': return 'option';
            case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': return 'heading';
            case 'NAV': return 'navigation';
            case 'MAIN': return 'main';
            case 'ASIDE': return 'complementary';
            case 'HEADER': return insideSectioning(el) ? null : 'banner';
            case 'FOOTER': return insideSectioning(el) ? null : 'contentinfo';
            case 'FORM': return 'form';
            case 'SEARCH': return 'search';
            case 'DIALOG': return 'dialog';
            case 'SECTION': return (el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby')) ? 'region' : null;
            case 'ARTICLE': return 'article';
            case 'UL': case 'OL': case 'MENU': return 'list';
            case 'LI': return 'listitem';
            case 'TABLE': return 'table';
            case 'TR': return 'row';
            case 'TH': return 'columnheader';
            case 'TD': return 'cell';
            case 'FIELDSET': return 'group';
            case 'IMG': return el.getAttribute('alt') === '' ? null : 'img';
            case 'SVG': case 'svg': return (el.getAttribute('aria-label') || el.querySelector(':scope > title')) ? 'img' : null;
            case 'PROGRESS': return 'progressbar';
            case 'METER': return 'meter';
            case 'HR': return 'separator';
            case 'IFRAME': return 'iframe';
            case 'VIDEO': return 'video';
            case 'AUDIO': return 'audio';
          }
          if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return 'textbox';
          return null;
        }

        function isVisible(el) {
          if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
          if (typeof el.checkVisibility === 'function') {
            return el.checkVisibility({ checkOpacity: false, checkVisibilityCSS: true });
          }
          const style = getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden';
        }

        // Elements the page made clickable with JS (React onClick on a div) have no semantic
        // role; the tell is a pointer cursor its parent doesn't have (or onclick / tabindex).
        function isClickable(el, cursor, parentCursor) {
          if (el.hasAttribute('onclick')) return true;
          const tabindex = el.getAttribute('tabindex');
          if (tabindex !== null && parseInt(tabindex, 10) >= 0) return true;
          return cursor === 'pointer' && parentCursor !== 'pointer';
        }

        function textOf(node) {
          return clip(collapse(node.innerText !== undefined ? node.innerText : node.textContent), 200);
        }

        function nameOf(el, role) {
          const root = el.getRootNode();
          const labelledBy = el.getAttribute('aria-labelledby');
          if (labelledBy) {
            const label = labelledBy.split(/\s+/).map((id) => {
              const target = (root.getElementById ? root.getElementById(id) : null) || document.getElementById(id);
              return target ? textOf(target) : '';
            }).join(' ').trim();
            if (label) return label;
          }
          const aria = collapse(el.getAttribute('aria-label'));
          if (aria) return aria;
          const tag = el.tagName;
          if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
            const type = (el.getAttribute('type') || '').toLowerCase();
            if (['button', 'submit', 'reset'].includes(type)) return el.value || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : '');
            if (type === 'image') return el.alt || 'Submit';
            if (el.labels && el.labels.length) {
              const label = [...el.labels].map((l) => {
                const clone = l.cloneNode(true);
                clone.querySelectorAll('input, select, textarea').forEach((c) => c.remove());
                return collapse(clone.textContent);
              }).join(' ').trim();
              if (label) return clip(label, 200);
            }
            return collapse(el.getAttribute('placeholder')) || collapse(el.getAttribute('title'));
          }
          if (tag === 'IMG' || tag === 'AREA') return collapse(el.getAttribute('alt')) || collapse(el.getAttribute('title'));
          if (tag === 'svg' || tag === 'SVG') {
            const title = el.querySelector(':scope > title');
            return title ? collapse(title.textContent) : '';
          }
          if (tag === 'IFRAME') return collapse(el.getAttribute('title')) || collapse(el.getAttribute('name'));
          if (tag === 'FIELDSET') {
            const legend = el.querySelector(':scope > legend');
            if (legend) return textOf(legend);
          }
          if (tag === 'TABLE') {
            const caption = el.querySelector(':scope > caption');
            if (caption) return textOf(caption);
          }
          if (NAME_FROM_CONTENT.has(role)) {
            const text = textOf(el);
            if (text) return text;
            const inner = el.querySelector('img[alt], [aria-label], svg title');
            if (inner) return collapse(inner.getAttribute('alt') || inner.getAttribute('aria-label') || inner.textContent);
          }
          return collapse(el.getAttribute('title'));
        }

        function statesOf(el, role) {
          const states = [];
          const aria = (name) => el.getAttribute('aria-' + name);
          if (role === 'heading') {
            const level = aria('level') || (/^H[1-6]$/.test(el.tagName) ? el.tagName[1] : null);
            if (level) states.push(`level=${level}`);
          }
          if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox' || role === 'menuitemradio') {
            const checked = el.indeterminate ? 'mixed' : (el.checked !== undefined && el.tagName === 'INPUT' ? String(el.checked) : aria('checked'));
            if (checked === 'true') states.push('checked');
            if (checked === 'mixed') states.push('mixed');
          }
          if (el.disabled || aria('disabled') === 'true') states.push('disabled');
          if (aria('expanded') === 'true') states.push('expanded');
          if (aria('expanded') === 'false') states.push('collapsed');
          if (aria('pressed') === 'true') states.push('pressed');
          if (aria('selected') === 'true' || (el.tagName === 'OPTION' && el.selected)) states.push('selected');
          if (aria('current') && aria('current') !== 'false') states.push('current');
          if (el.required || aria('required') === 'true') states.push('required');
          if (el.readOnly || aria('readonly') === 'true') states.push('readonly');
          if (aria('invalid') === 'true') states.push('invalid');
          if (el.tagName === 'DETAILS') states.push(el.open ? 'expanded' : 'collapsed');
          if (document.activeElement === el) states.push('focused');
          return states;
        }

        function valueOf(el, role) {
          if (el.tagName === 'SELECT') {
            const selected = [...el.selectedOptions].map((o) => collapse(o.textContent));
            return selected.length ? selected.join(', ') : null;
          }
          if (role === 'textbox' || role === 'searchbox' || role === 'combobox' || role === 'spinbutton' || role === 'slider') {
            if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') {
              return el.value ? '[hidden]' : null;  // never put secrets in the outline
            }
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return el.value ? clip(el.value, 100) : null;
            if (el.isContentEditable) {
              const text = collapse(el.innerText);
              return text ? clip(text, 100) : null;
            }
            const now = el.getAttribute('aria-valuenow');
            return now;
          }
          if (role === 'progressbar' || role === 'meter') {
            return el.value !== undefined ? String(el.value) : el.getAttribute('aria-valuenow');
          }
          return null;
        }

        function hrefOf(el) {
          const href = el.getAttribute('href');
          if (!href) return null;
          try {
            const url = new URL(href, location.href);
            const display = url.origin === location.origin ? url.pathname + url.search + url.hash : url.href;
            return clip(display, 120);
          } catch (_) {
            return clip(href, 120);
          }
        }

        function snapshot() {
          const lines = [];
          let chars = 0;
          let truncated = 0;
          let breakText = true;

          const push = (depth, text, kind) => {
            if (lines.length >= MAX_LINES || chars > MAX_CHARS) { truncated++; return null; }
            const line = { depth, text, kind };
            lines.push(line);
            chars += text.length + depth * 2 + 3;
            return line;
          };

          const addText = (depth, raw) => {
            const text = collapse(raw);
            if (!text) return;
            const last = lines[lines.length - 1];
            if (!breakText && last && last.kind === 'text' && last.depth === depth && last.raw.length < MAX_TEXT) {
              last.raw = clip(last.raw + ' ' + text, MAX_TEXT);
              last.text = 'text: ' + quote(last.raw);
              return;
            }
            const line = push(depth, '', 'text');
            if (line) {
              line.raw = clip(text, MAX_TEXT);
              line.text = 'text: ' + quote(line.raw);
            }
            breakText = false;
          };

          const children = (el) => {
            if (el.shadowRoot) return [...el.shadowRoot.childNodes];
            if (el.tagName === 'SLOT') return el.assignedNodes({ flatten: true }).length ? el.assignedNodes({ flatten: true }) : [...el.childNodes];
            if (el.tagName === 'IFRAME') {
              try {
                const doc = el.contentDocument;
                return doc && doc.body ? [doc.body] : [];
              } catch (_) { return []; }
            }
            return [...el.childNodes];
          };

          // `quiet`: inside a <label> bound to a control. Its text already names that control.
          const walk = (node, depth, parentCursor, quiet) => {
            if (lines.length >= MAX_LINES || chars > MAX_CHARS) { truncated++; return; }
            if (node.nodeType === Node.TEXT_NODE) { if (!quiet) addText(depth, node.textContent); return; }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            const el = node;
            const tag = el.tagName.toUpperCase();
            if (SKIP.has(tag)) return;
            if (!isVisible(el)) return;
            const block = BLOCK.has(tag);
            if (block) breakText = true;

            const cursor = getComputedStyle(el).cursor;
            const clickable = tag !== 'BODY' && tag !== 'HTML' && isClickable(el, cursor, parentCursor);
            let role = roleOf(el);
            if (!role && clickable && collapse(el.textContent)) role = 'clickable';

            let childDepth = depth;
            let line = null;
            if (role) {
              const name = nameOf(el, role);
              let text = role + (name ? ' ' + quote(name) : '');
              const value = valueOf(el, role);
              if (value !== null && value !== undefined && value !== '') text += ' value=' + quote(String(value));
              if (role === 'link') {
                const href = hrefOf(el);
                if (href) text += ` (${href})`;
              }
              for (const state of statesOf(el, role)) text += ` [${state}]`;
              const clickableContainer = clickable && !INTERACTIVE.has(role) && !LEAF.has(role);
              if (clickableContainer) text += ' [clickable]';
              if (INTERACTIVE.has(role) || clickableContainer || role === 'heading' || role === 'img' || role === 'dialog' || role === 'iframe' || el.isContentEditable) {
                text += ` [ref=${refFor(el)}]`;
              }
              line = push(depth, text, LEAF.has(role) && role !== 'iframe' ? 'leaf' : 'container');
              if (line) line.name = name;
              breakText = true;
              if (LEAF.has(role) && role !== 'iframe') return;
              childDepth = depth + 1;
            }
            const before = lines.length;
            // Text that names something else (a bound label, a caption, a legend) is already shown as that name.
            const namesSomething = (tag === 'LABEL' && el.control && isVisible(el.control)) || tag === 'CAPTION' || tag === 'LEGEND';
            for (const child of children(el)) walk(child, childDepth, cursor, quiet || namesSomething);
            if (block) breakText = true;
            if (line && line.kind === 'container') {
              const added = lines.length - before;
              if (added === 0 && !line.text.includes('[ref=') && !/"/.test(line.text)) {
                lines.splice(lines.indexOf(line), 1);  // empty, unnamed container: noise
              } else if (added === 1 && lines[before].kind === 'text') {
                if (lines[before].raw !== line.name) line.text += ': ' + quote(lines[before].raw);
                lines.splice(before, 1);
              } else if (added > 0) {
                line.text += ':';
              }
            }
          };

          if (document.body) walk(document.body, 0, 'auto', false);
          let outline = lines.map((l) => '  '.repeat(l.depth) + '- ' + l.text).join('\n');
          if (truncated > 0) outline += `\n- … (outline truncated; ${truncated} more nodes. Use browser_eval for specific parts.)`;
          return { url: location.href, title: document.title, outline };
        }

        function deepQueryRef(ref, root) {
          const found = root.querySelector(`[${REF_ATTR}="${ref}"]`);
          if (found) return found;
          for (const host of root.querySelectorAll('*')) {
            if (host.shadowRoot) {
              const inner = deepQueryRef(ref, host.shadowRoot);
              if (inner) return inner;
            }
          }
          return null;
        }

        function resolve(input) {
          const raw = String(input || '').trim();
          const match = raw.match(/^\[?(?:ref=)?(e\d+)\]?$/);
          if (match) {
            const ref = match[1];
            const weak = refs.get(ref);
            const known = weak && weak.deref();
            if (known && known.isConnected) return known;
            const found = deepQueryRef(ref, document);
            if (found) return found;
            throw new Error(`No element with ref ${ref} on the page any more. Take a new snapshot to get current refs.`);
          }
          let el;
          try {
            el = document.querySelector(raw);
          } catch (_) {
            throw new Error(`"${raw}" is neither a snapshot ref (like e12) nor a valid CSS selector.`);
          }
          if (!el) throw new Error(`No element matches the CSS selector ${raw}.`);
          return el;
        }

        const describe = (el) => {
          const name = collapse(el.getAttribute('aria-label')) || clip(collapse(el.innerText || el.value || ''), 60);
          return `<${el.tagName.toLowerCase()}>` + (name ? ` ${quote(name)}` : '');
        };

        function assertEnabled(el, input) {
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') {
            throw new Error(`${describe(el)} (${input}) is disabled.`);
          }
        }

        function center(el) {
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const rect = el.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        }

        function click(input) {
          const el = resolve(input);
          assertEnabled(el, input);
          const { x, y } = center(el);
          const base = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, screenX: x, screenY: y, view: window, button: 0 };
          const pointer = { ...base, pointerId: 1, pointerType: 'mouse', isPrimary: true };
          el.dispatchEvent(new PointerEvent('pointerover', { ...pointer, buttons: 0 }));
          el.dispatchEvent(new PointerEvent('pointerenter', { ...pointer, buttons: 0, bubbles: false }));
          el.dispatchEvent(new MouseEvent('mouseover', { ...base, buttons: 0 }));
          el.dispatchEvent(new MouseEvent('mouseenter', { ...base, buttons: 0, bubbles: false }));
          const downAllowed = el.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1 }))
            & el.dispatchEvent(new MouseEvent('mousedown', { ...base, buttons: 1, detail: 1 }));
          if (downAllowed && typeof el.focus === 'function') el.focus({ preventScroll: true });
          el.dispatchEvent(new PointerEvent('pointerup', { ...pointer, buttons: 0 }));
          el.dispatchEvent(new MouseEvent('mouseup', { ...base, buttons: 0, detail: 1 }));
          // A synthetic click still runs activation behavior: links navigate, checkboxes toggle,
          // submit buttons submit.
          el.dispatchEvent(new MouseEvent('click', { ...base, buttons: 0, detail: 1 }));
          return describe(el);
        }

        function setNativeValue(el, value) {
          const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
            : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, value);
        }

        function pressEnter(el) {
          const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: 13, bubbles: true, cancelable: true, composed: true };
          const allowed = el.dispatchEvent(new KeyboardEvent('keydown', init));
          el.dispatchEvent(new KeyboardEvent('keypress', init));
          el.dispatchEvent(new KeyboardEvent('keyup', init));
          if (allowed && el.form && el.tagName !== 'TEXTAREA') {
            if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
            else el.form.submit();
          }
        }

        function fill(input, text, submit) {
          const el = resolve(input);
          assertEnabled(el, input);
          if (el.readOnly) throw new Error(`${describe(el)} (${input}) is read-only.`);
          center(el);
          if (typeof el.focus === 'function') el.focus({ preventScroll: true });
          const tag = el.tagName;
          const type = (el.getAttribute('type') || '').toLowerCase();
          if (tag === 'SELECT') {
            const options = [...el.options];
            const wanted = String(text).trim();
            const option = options.find((o) => o.value === wanted)
              || options.find((o) => collapse(o.textContent) === wanted)
              || options.find((o) => collapse(o.textContent).toLowerCase().includes(wanted.toLowerCase()));
            if (!option) {
              throw new Error(`No option "${wanted}" in ${describe(el)}. Options: ${options.map((o) => collapse(o.textContent)).slice(0, 25).join(', ')}`);
            }
            setNativeValue(el, option.value);
            el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (tag === 'INPUT' && (type === 'checkbox' || type === 'radio')) {
            const want = /^(true|1|yes|on|checked)$/i.test(String(text).trim());
            if (el.checked !== want) click(el.hasAttribute('data-mship-ref') ? el.getAttribute('data-mship-ref') : input);
          } else if (tag === 'INPUT' || tag === 'TEXTAREA') {
            if (tag === 'INPUT' && !TEXT_INPUTS.has(type) && !['search', 'number', 'range'].includes(type)) {
              throw new Error(`${describe(el)} is an <input type=${type}>; it can't be filled with text.`);
            }
            try { el.select(); } catch (_) {}
            el.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, composed: true, inputType: 'insertReplacementText', data: String(text) }));
            setNativeValue(el, String(text));
            el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: String(text) }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (el.isContentEditable) {
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(el);
            selection.removeAllRanges();
            selection.addRange(range);
            if (!document.execCommand('insertText', false, String(text))) {
              el.textContent = String(text);
              el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: String(text) }));
            }
          } else {
            throw new Error(`${describe(el)} (${input}) isn't a form field. Click it, or fill the input inside it.`);
          }
          if (submit) pressEnter(el);
          return describe(el);
        }

        return { snapshot, click, fill, resolve, refFor, describe };
      })();
    }
    """#

    /// Hover highlight + click-to-pick. Lives in the isolated world; posts to `mshipPicker`.
    static let picker = #"""
    if (!window.__mshipPicker) {
      window.__mshipPicker = (() => {
        let active = false;
        let host = null;
        let box = null;
        let label = null;
        let current = null;
        let savedCursor = '';
        const post = (message) => {
          try { window.webkit.messageHandlers.mshipPicker.postMessage(message); } catch (_) {}
        };
        const clip = (text, max) => text.length > max ? text.slice(0, max - 1) + '…' : text;

        function ensureOverlay() {
          if (host) return;
          host = document.createElement('mship-picker');
          host.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;';
          const shadow = host.attachShadow({ mode: 'closed' });
          box = document.createElement('div');
          box.style.cssText = 'position: fixed; pointer-events: none; border: 2px solid #0a84ff; background: rgba(10,132,255,0.14);'
            + 'border-radius: 3px; box-sizing: border-box; transition: all 60ms ease-out; display: none;';
          label = document.createElement('div');
          label.style.cssText = 'position: fixed; pointer-events: none; font: 600 11px/1.4 -apple-system, system-ui, sans-serif;'
            + 'color: #fff; background: #0a84ff; padding: 2px 7px; border-radius: 5px; white-space: nowrap;'
            + 'box-shadow: 0 2px 8px rgba(0,0,0,0.25); display: none; max-width: 70vw; overflow: hidden; text-overflow: ellipsis;';
          shadow.append(box, label);
        }

        function describe(el) {
          let text = el.tagName.toLowerCase();
          if (el.id) text += '#' + el.id;
          const classes = [...el.classList].slice(0, 2);
          if (classes.length) text += '.' + classes.join('.');
          return text;
        }

        function draw(el) {
          const rect = el.getBoundingClientRect();
          box.style.display = 'block';
          box.style.left = rect.left + 'px';
          box.style.top = rect.top + 'px';
          box.style.width = rect.width + 'px';
          box.style.height = rect.height + 'px';
          label.style.display = 'block';
          label.textContent = `${describe(el)}  ${Math.round(rect.width)}×${Math.round(rect.height)}`;
          const above = rect.top - 24;
          label.style.top = (above >= 4 ? above : Math.min(rect.bottom + 6, innerHeight - 24)) + 'px';
          label.style.left = Math.max(4, Math.min(rect.left, innerWidth - 200)) + 'px';
        }

        function targetOf(event) {
          const path = typeof event.composedPath === 'function' ? event.composedPath() : [event.target];
          for (const node of path) {
            if (node instanceof Element && node !== host) return node;
          }
          return null;
        }

        const unique = (selector) => {
          try { return document.querySelectorAll(selector).length === 1; } catch (_) { return false; }
        };

        function cssPath(el) {
          if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
          const tag = el.tagName.toLowerCase();
          for (const attribute of ['data-testid', 'data-test', 'data-cy', 'name', 'aria-label']) {
            const value = el.getAttribute(attribute);
            if (value) {
              const selector = `${tag}[${attribute}="${CSS.escape(value)}"]`;
              if (unique(selector)) return selector;
            }
          }
          const parts = [];
          let node = el;
          while (node && node.nodeType === 1 && node !== document.documentElement) {
            if (node !== el && node.id && unique('#' + CSS.escape(node.id))) {
              parts.unshift('#' + CSS.escape(node.id));
              break;
            }
            let part = node.tagName.toLowerCase();
            const classes = [...node.classList]
              .filter((c) => c.length < 32 && !/[:\[\]\/]/.test(c) && !/^(css|sc|jsx|emotion)-/.test(c) && !/\d{4,}/.test(c))
              .slice(0, 2);
            if (classes.length) part += '.' + classes.map((c) => CSS.escape(c)).join('.');
            const parent = node.parentElement;
            if (parent) {
              const same = [...parent.children].filter((child) => child.tagName === node.tagName);
              if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
            }
            parts.unshift(part);
            if (unique(parts.join(' > '))) return parts.join(' > ');
            node = parent;
          }
          return parts.join(' > ');
        }

        const STYLE_KEYS = ['display', 'position', 'width', 'height', 'margin', 'padding', 'color', 'background-color',
          'background-image', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'text-align',
          'text-transform', 'border', 'border-radius', 'box-shadow', 'gap', 'flex-direction', 'justify-content',
          'align-items', 'grid-template-columns', 'opacity', 'z-index', 'cursor'];
        const BORING = new Set(['none', 'normal', 'auto', '0px', 'rgba(0, 0, 0, 0)', 'static', 'start', '1', 'visible']);

        function collect(el) {
          const rect = el.getBoundingClientRect();
          const computed = getComputedStyle(el);
          const styles = {};
          for (const key of STYLE_KEYS) {
            const value = computed.getPropertyValue(key);
            if (value && !BORING.has(value.trim()) && !(key === 'border' && /^0px/.test(value))) styles[key] = value.trim();
          }
          let ref = null;
          try { if (window.__mship) ref = window.__mship.refFor(el); } catch (_) {}
          return {
            selector: cssPath(el),
            tag: el.tagName.toLowerCase(),
            outerHTML: clip(el.outerHTML.replace(/\sdata-mship-ref="e\d+"/g, ''), 3000),
            text: clip(String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim(), 500),
            styles,
            x: rect.left, y: rect.top, width: rect.width, height: rect.height,
            ref,
            url: location.href,
            title: document.title,
          };
        }

        const swallow = (event) => {
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
        };

        const onMove = (event) => {
          const el = targetOf(event);
          if (!el || el === current) return;
          current = el;
          draw(el);
        };

        const onClick = (event) => {
          swallow(event);
          const el = targetOf(event) || current;
          if (!el) return;
          box.style.display = 'none';
          label.style.display = 'none';
          const info = collect(el);
          stop();
          post({ picked: info });
        };

        const onKey = (event) => {
          if (event.key === 'Escape') {
            swallow(event);
            stop();
            post({ cancelled: true });
          }
        };

        const LISTENERS = [['mousemove', onMove], ['click', onClick], ['keydown', onKey],
          ['mousedown', swallow], ['mouseup', swallow], ['pointerdown', swallow], ['pointerup', swallow],
          ['auxclick', swallow], ['contextmenu', swallow], ['dblclick', swallow]];

        function start() {
          if (active) return true;
          active = true;
          ensureOverlay();
          document.documentElement.appendChild(host);
          for (const [type, listener] of LISTENERS) window.addEventListener(type, listener, true);
          savedCursor = document.documentElement.style.cursor;
          document.documentElement.style.cursor = 'crosshair';
          return true;
        }

        function stop() {
          if (!active) return false;
          active = false;
          current = null;
          for (const [type, listener] of LISTENERS) window.removeEventListener(type, listener, true);
          if (host) host.remove();
          if (box) box.style.display = 'none';
          if (label) label.style.display = 'none';
          document.documentElement.style.cursor = savedCursor;
          return true;
        }

        return { start, stop, isActive: () => active };
      })();
    }
    """#
}
