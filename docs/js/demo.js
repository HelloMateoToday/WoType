// 功能演示动画：按 scenes.js 的分镜一帧帧更新界面（编辑器窗口、候选窗、键帽、语音胶囊、中英提示、翻译窗口）。
// 尺寸、配色照 App 的真实界面（WoType/WoType/UI/CandidatePanel.swift、Theme.swift 的默认皮肤，
// UI/Voice/CapsuleView.swift、ModeToast.swift、TranslationWindow.swift），和实测截图核对过。
//
// 舞台按 640×260 设计，用 transform 缩放到容器宽度（字是矢量的，缩放后照样清楚）。窄屏上缩放最小 0.78，
// 舞台跟着变窄，候选窗按宽度少放几个候选（放的仍是实测的候选，实测的候选窗宽 548）。
// 只在滚动到屏幕里时播放，播完停一会儿再循环；系统打开了「减少动态效果」时只显示最有代表性的一帧。
// 调试：网址加 ?freeze=<秒> 时，每个演示停在那一刻（截图检查用）。
import { scenes } from './scenes.js';

const STAGE = { width: 640, height: 260 };
const TEXT = { left: 24, top: 44, line: 30, rows: 4 };
const PANEL = { width: 548, pad: 4, control: 24 };
const MIN_SCALE = 0.78;
const LOOP_PAUSE = 2000;

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const freeze = new URLSearchParams(location.search).get('freeze');

const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
};

const chevronSVG = '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M7 10l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const returnSVG = '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M18 6v8H6m3.5-3.5L6 14l3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

// 翻译窗口的图标：和 App 一样用 Lucide（ISC）
const lucide = (body, size = 10) => `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const ICON = {
  pin: '<path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z"/>',
  settings: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
  volume: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>',
  copy: '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
  info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  enter: '<path d="M20 4v7a4 4 0 0 1-4 4H4"/><path d="m9 10-5 5 5 5"/>',
};
/// 打字机：最新的几个字从浅到深
const TAIL = 6;

class Demo {
  constructor(root, frames) {
    this.root = root;
    this.frames = frames;
    let t = 0;
    for (const frame of frames) {
      frame.start = t;
      t += frame.hold;
    }
    this.duration = t;
    this.index = -1;
    this.timer = null;
    this.visible = false;
    this.build();
  }

  build() {
    this.root.classList.add('demo');
    this.frameBox = el('div', 'demo-frame');
    this.stage = el('div', 'demo-stage');
    this.stage.style.width = `${STAGE.width}px`;
    this.stage.style.height = `${STAGE.height}px`;

    const win = el('div', 'demo-window');
    const bar = el('div', 'demo-titlebar');
    bar.append(el('span', 'dot red'), el('span', 'dot yellow'), el('span', 'dot green'), el('span', 'demo-title', '备忘录'));
    this.lines = el('div', 'demo-lines');
    this.rows = el('div', 'demo-rows');
    this.lines.append(this.rows);
    win.append(bar, this.lines);

    this.panel = el('div', 'demo-panel');
    this.highlight = el('div', 'demo-highlight');
    this.cells = el('div', 'demo-cells');
    const chevron = el('div', 'demo-chevron');
    chevron.innerHTML = chevronSVG;
    this.translation = el('div', 'demo-translation');
    this.translationText = el('span');
    const ret = el('span', 'demo-return');
    ret.innerHTML = returnSVG;
    this.translation.append(this.translationText, ret);
    const row = el('div', 'demo-candidates');
    row.append(this.highlight, this.cells, chevron);
    this.panel.append(row, this.translation);

    this.key = el('div', 'demo-key');
    this.toast = el('div', 'demo-toast');
    this.tw = el('div', 'demo-tw');
    this.capsule = el('div', 'demo-capsule');
    const mark = el('div', 'demo-mark');
    mark.append(el('span', 'live'));
    for (let i = 0; i < 5; i++) mark.append(el('span', `bar b${i}`));
    this.draft = el('div', 'demo-draft');
    this.draftText = el('span');
    this.draft.append(this.draftText);
    this.capsule.append(mark, this.draft);

    this.stage.append(win, this.panel, this.toast, this.tw, this.key, this.capsule);
    this.frameBox.append(this.stage);
    this.caption = el('p', 'demo-caption');
    this.root.append(this.frameBox, this.caption);

    new ResizeObserver(() => this.fit()).observe(this.root);
    this.fit();
  }

  /// 舞台缩放到容器宽度
  fit() {
    const width = this.root.clientWidth;
    const scale = Math.min(1.25, Math.max(MIN_SCALE, width / STAGE.width));
    this.stageWidth = Math.min(STAGE.width, width / scale);
    this.panelWidth = Math.min(PANEL.width, this.stageWidth - 2 * TEXT.left + 12);
    this.stage.style.width = `${this.stageWidth}px`;
    this.panel.style.width = `${this.panelWidth}px`;
    this.stage.style.transform = `scale(${scale})`;
    this.frameBox.style.height = `${STAGE.height * scale}px`;
    if (this.index >= 0) this.show(this.index, true);
  }

  // ── 播放 ──

  start() {
    if (freeze != null) {
      const t = Number(freeze) % this.duration;
      this.show(this.frames.findLastIndex((f) => f.start <= t));
      return;
    }
    if (reduceMotion) {
      this.show(this.representative());
      return;
    }
    new IntersectionObserver(([entry]) => {
      this.visible = entry.isIntersecting;
      if (this.visible) this.resume(); else this.pause();
    }, { threshold: 0.25 }).observe(this.root);
  }

  resume() {
    if (this.timer) return;
    this.step(this.index < 0 || this.index >= this.frames.length - 1 ? 0 : this.index + 1);
  }

  pause() {
    clearTimeout(this.timer);
    this.timer = null;
  }

  step(index) {
    this.show(index);
    const last = index === this.frames.length - 1;
    this.timer = setTimeout(() => {
      this.timer = null;
      if (!this.visible) return;
      this.step(last ? 0 : index + 1);
    }, this.frames[index].hold * 1000 + (last ? LOOP_PAUSE : 0));
  }

  /// 减少动态效果时显示的那一帧：翻译窗口、译文、候选、语音草稿里最靠后、内容最全的
  representative() {
    const score = (f) => (f.key ? -1 : 0) + (f.tw ? 4 : 0) + (f.translation ? 3 : 0)
      + (f.candidates.length ? 2 : 0) + (f.voice ? 1 + f.voice.length / 100 : 0);
    let best = 0;
    this.frames.forEach((f, i) => { if (score(f) >= score(this.frames[best])) best = i; });
    return best;
  }

  // ── 画一帧 ──

  show(index, relayout = false) {
    if (relayout) this.lastCandidates = null;
    const frame = this.frames[index];
    const prev = index > 0 ? this.frames[index - 1] : null;
    this.index = index;
    this.renderRows(frame, prev);
    this.renderPanel(frame, prev);
    this.renderKey(frame, prev);
    this.renderToast(frame);
    this.renderTranslation(index);
    this.renderCapsule(frame, prev);
    this.renderCaption(frame);
  }

  renderRows(frame, prev) {
    const rows = [...frame.lines, null];
    this.rows.replaceChildren(...rows.map((text, i) => {
      const row = el('div', 'demo-row');
      if (text != null) {
        const span = el('span', i === frame.selection ? 'selected' : '', text);
        row.append(span);
        return row;
      }
      // 正在打的这一行：已上屏的字 + 标记文字（分段选好的 + 拼音，带下划线）+ 光标
      this.committedSpan = el('span', '', frame.committed);
      row.append(this.committedSpan);
      const marked = (frame.prefix ?? '') + frame.pinyin.replaceAll("'", ' ');
      if (marked) row.append(el('span', 'marked', marked));
      this.caret = el('span', 'caret');
      const typing = prev && (prev.pinyin !== frame.pinyin || prev.committed !== frame.committed);
      if (!typing) this.caret.classList.add('blink');
      if (frame.selection != null) this.caret.hidden = true;
      row.append(this.caret);
      return row;
    }));
    this.scroll = Math.max(0, rows.length - TEXT.rows);
    this.rows.style.transform = `translateY(${-this.scroll * TEXT.line}px)`;
    this.lineTop = TEXT.top + (rows.length - 1 - this.scroll) * TEXT.line;
  }

  renderPanel(frame, prev) {
    const open = frame.candidates.length > 0;
    this.panel.classList.toggle('open', open);
    if (!open) return;
    const list = frame.candidates.join('\n');
    const sameList = this.lastCandidates === list;
    this.lastCandidates = list;
    if (!sameList) {
      this.cells.replaceChildren(...frame.candidates.map((word, i) => {
        const cell = el('div', 'demo-cell');
        cell.append(el('span', 'label', String(i + 1)), el('span', 'word', word));
        return cell;
      }));
      // 横排按宽度放候选，放不下的不显示（实测的候选窗也是这样）
      const limit = this.panelWidth - 2 * PANEL.pad - PANEL.control;
      for (const cell of this.cells.children) cell.hidden = cell.offsetLeft + cell.offsetWidth > limit;
    }
    [...this.cells.children].forEach((cell, i) => cell.classList.toggle('selected', i === frame.highlight));
    const target = this.cells.children[frame.highlight];
    this.highlight.classList.toggle('instant', !sameList);
    this.highlight.style.left = `${target.offsetLeft}px`;
    this.highlight.style.width = `${target.offsetWidth}px`;

    this.translation.hidden = !frame.translation;
    this.translationText.textContent = frame.translation ?? '';

    // 候选窗在标记文字（这一段输入）的开头下面
    const x = TEXT.left + this.committedSpan.offsetWidth - 6;
    this.panel.style.left = `${Math.max(8, Math.min(x, this.stageWidth - this.panelWidth - 8))}px`;
    this.panel.style.top = `${this.lineTop + TEXT.line + 6}px`;
  }

  renderKey(frame, prev) {
    this.key.classList.toggle('show', !!frame.key);
    if (!frame.key) return;
    this.key.textContent = frame.key;
    if (prev?.key !== frame.key) {
      this.key.classList.remove('pop');
      void this.key.offsetWidth;
      this.key.classList.add('pop');
    }
  }

  renderToast(frame) {
    this.toast.classList.toggle('show', !!frame.toast);
    if (!frame.toast) return;
    this.toast.textContent = frame.toast;
    this.toast.style.left = `${TEXT.left + this.caret.offsetLeft - 10}px`;
    this.toast.style.top = `${this.lineTop + TEXT.line + 4}px`;
  }

  // ── 划词翻译的翻译窗口：贴舞台右边（App 里在屏幕右边），照 TranslationWindow 缩小 ──
  // 两张卡片先转加载点；机器翻译整段出来，AI 一个字一个字出、最新的几个字从浅到深，打完才出按钮。
  // 窗口开着的那几帧共用同一个 tw 对象，按打开以后过了多久逐帧画（requestAnimationFrame）

  renderTranslation(index) {
    const data = this.frames[index].tw;
    if (data === this.twData) return;
    cancelAnimationFrame(this.twFrame);
    this.twData = data;
    this.tw.classList.toggle('show', !!data);
    if (!data) return;
    this.buildTranslation(data);
    let opened = index;
    while (opened > 0 && this.frames[opened - 1].tw === data) opened--;
    if (freeze != null) {
      this.updateTranslation(Number(freeze) % this.duration - this.frames[opened].start);
    } else if (reduceMotion) {
      this.updateTranslation(99);
    } else {
      const start = performance.now();
      const tick = () => {
        const since = (performance.now() - start) / 1000;
        this.updateTranslation(since);
        if (since < 6) this.twFrame = requestAnimationFrame(tick);
      };
      tick();
    }
  }

  buildTranslation(data) {
    const tools = () => {
      const row = el('div', 'tw-tools');
      row.innerHTML = lucide(ICON.volume) + lucide(ICON.copy);
      return row;
    };
    const bar = el('div', 'tw-bar');
    bar.innerHTML = lucide(ICON.pin, 11) + lucide(ICON.settings, 11);
    const query = el('div', 'tw-box tw-query');
    const queryTools = tools();
    const tag = el('span', 'tw-tag', '识别为 ');
    tag.append(el('b', '', data.language));
    const enter = el('span', 'tw-enter');
    enter.innerHTML = lucide(ICON.enter);
    queryTools.append(tag, enter);
    query.append(el('div', 'tw-text', data.query), queryTools);
    const lang = el('div', 'tw-box tw-lang');
    lang.append(el('span', '', '自动检测 ▾'), el('span', '', '⇄'), el('span', '', '自动选择 ▾'));
    this.twCards = data.cards.map((card) => {
      const box = el('div', 'tw-box');
      const head = el('div', 'tw-head');
      head.append(el('span', '', card.name));
      if (card.info) {
        const info = el('span', 'tw-info');
        info.innerHTML = lucide(ICON.info, 9);
        head.append(info);
      }
      const dots = el('span', 'tw-dots');
      for (let i = 0; i < 5; i++) dots.append(el('i'));
      const chevron = el('span', 'tw-chevron');
      chevron.innerHTML = lucide(ICON.chevron);
      head.append(dots, chevron);
      const body = el('div', 'tw-body');
      const inner = el('div');
      const text = el('div', 'tw-text');
      const row = tools();
      row.hidden = true;
      inner.append(text, row);
      body.append(inner);
      box.append(head, body);
      return { card, dots, body, inner, text, tools: row, shown: -1 };
    });
    this.tw.replaceChildren(bar, query, lang, ...this.twCards.map((c) => c.body.parentNode));
  }

  /// since：窗口开了几秒
  updateTranslation(since) {
    for (const c of this.twCards) {
      const { card } = c;
      const local = since - card.at;
      const length = card.text.length;
      const shown = local < 0 ? 0 : card.speed ? Math.min(local * card.speed, length + TAIL) : length;
      const done = local >= 0 && (!card.speed || shown >= length + TAIL);
      c.dots.hidden = done;
      if (shown !== c.shown) {
        c.shown = shown;
        if (card.speed) {
          const solid = Math.max(0, Math.floor(shown - TAIL));
          const parts = [document.createTextNode(card.text.slice(0, solid))];
          for (let k = solid; k < Math.min(length, Math.ceil(shown)); k++) {
            const span = el('span', '', card.text[k]);
            span.style.opacity = Math.min(1, Math.max(0, (shown - k) / TAIL)).toFixed(2);
            parts.push(span);
          }
          c.text.replaceChildren(...parts);
        } else {
          c.text.textContent = shown > 0 ? card.text : '';
        }
      }
      c.tools.hidden = !done;
      // 正文高度跟着内容走，CSS 过渡让卡片、窗口平滑长高
      const height = local < 0 ? 0 : c.inner.offsetHeight;
      if (c.body.style.height !== `${height}px`) c.body.style.height = `${height}px`;
    }
  }

  renderCapsule(frame) {
    const listening = frame.voice != null;
    this.capsule.classList.toggle('show', listening);
    if (!listening) return;
    this.draftText.textContent = frame.voice;
    this.draft.hidden = !frame.voice;
  }

  renderCaption(frame) {
    if (this.caption.textContent === (frame.caption ?? '')) return;
    this.caption.textContent = frame.caption ?? '';
    this.caption.classList.remove('fade');
    void this.caption.offsetWidth;
    this.caption.classList.add('fade');
  }
}

for (const root of document.querySelectorAll('[data-demo]')) {
  const make = scenes[root.dataset.demo];
  if (make) new Demo(root, make()).start();
}
