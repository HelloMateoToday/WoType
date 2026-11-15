// 功能演示动画：按 scenes.js 的分镜一帧帧更新界面（编辑器窗口、候选窗、键帽、语音胶囊、中英提示、翻译气泡）。
// 尺寸、配色照 App 的真实界面（WoType/WoType/UI/CandidatePanel.swift、Theme.swift 的默认皮肤，
// UI/Voice/CapsuleView.swift、ModeToast.swift、TranslationPanel.swift），和实测截图核对过。
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
    this.bubble = el('div', 'demo-bubble');
    this.capsule = el('div', 'demo-capsule');
    const mark = el('div', 'demo-mark');
    mark.append(el('span', 'live'));
    for (let i = 0; i < 5; i++) mark.append(el('span', `bar b${i}`));
    this.draft = el('div', 'demo-draft');
    this.draftText = el('span');
    this.draft.append(this.draftText);
    this.capsule.append(mark, this.draft);

    this.stage.append(win, this.panel, this.toast, this.bubble, this.key, this.capsule);
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

  /// 减少动态效果时显示的那一帧：气泡、译文、候选、语音草稿里最靠后、内容最全的
  representative() {
    const score = (f) => (f.key ? -1 : 0) + (f.bubble ? 4 : 0) + (f.translation ? 3 : 0)
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
    this.renderBubble(frame);
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

  renderBubble(frame) {
    this.bubble.classList.toggle('show', !!frame.bubble);
    if (!frame.bubble) return;
    this.bubble.textContent = frame.bubble;
    this.bubble.style.left = `${TEXT.left}px`;
    this.bubble.style.top = `${TEXT.top + (frame.selection - this.scroll + 1) * TEXT.line + 4}px`;
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
