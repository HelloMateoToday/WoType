// 落地页的功能演示分镜。拼音、候选、译文、语音结果都是 2026-11-15 在 WoType 里实测的
// （万象引擎；候选窗不显示拼音；语音用微信体验渠道识别，云端润色和翻译）。
// 和开发仓库 demo/scenes.js（演示视频的分镜）是同一份实测结果：App 的候选变了，两边一起改。
//
// 一帧是演示的一个状态，hold 是停多久（秒）；demo.js 按帧更新界面，过渡动画在那边做。

class Script {
  constructor() {
    this.frames = [];
    this.state = {
      // prefix：分段选时已经选好、但还在输入中的那段（和拼音一起带下划线，实测是这样）
      lines: [], committed: '', prefix: '', pinyin: '', candidates: [], highlight: 0,
      translation: null, key: null, caption: null, toast: null, voice: null, selection: null, tw: null,
    };
  }

  emit(hold) {
    this.frames.push({ ...this.state, lines: [...this.state.lines], candidates: [...this.state.candidates], hold });
  }

  caption(text) { this.state.caption = text; }

  wait(seconds) { this.emit(seconds); }

  newLine() {
    if (this.state.committed) this.state.lines.push(this.state.committed);
    this.state.committed = '';
  }

  /// 逐个字母打拼音（分隔符 ' 跟着后面的字母一起出来，显示成空格），打完这一段才出候选：只实测了打完时的候选
  type(text, candidates) {
    this.state.candidates = [];
    let pending = '';
    for (const character of text) {
      pending += character;
      if (character === "'") continue;
      this.state.pinyin += pending;
      pending = '';
      this.emit(0.11);
    }
    this.state.candidates = candidates;
    this.state.highlight = 0;
    this.emit(0.7);
  }

  typeCommitted(text) {
    for (const character of text) {
      this.state.committed += character;
      this.emit(0.09);
    }
    this.emit(0.6);
  }

  /// 按一个键：键帽按下，然后 change 生效
  press(key, hold = 0.9, change = () => {}) {
    this.state.key = key;
    this.emit(0.45);
    this.state.key = null;
    change(this.state);
    this.emit(hold);
  }

  /// 选第 index 个候选；rest 是还没选的拼音和它的候选（分段选）
  choose(index, { key, rest, hold = 1 } = {}) {
    this.state.highlight = index;
    this.press(key ?? (index === 0 ? '空格' : String(index + 1)), hold, (s) => {
      if (rest) {
        s.prefix += s.candidates[index];
      } else {
        s.committed += s.prefix + s.candidates[index];
        s.prefix = '';
      }
      s.pinyin = rest?.[0] ?? '';
      s.candidates = rest?.[1] ?? [];
      s.highlight = 0;
      s.translation = null;
    });
  }

  /// 按住 key 说话：胶囊里逐字出识别的草稿，松开后 committed 上屏（口语清理、翻译后可以和草稿不同）
  speak(key, draft, committed) {
    this.state.key = key;
    this.state.voice = '';
    this.emit(0.6);
    for (const character of draft) {
      this.state.voice += character;
      this.emit(0.13);
    }
    this.emit(0.6);
    this.state.key = null;
    this.state.voice = null;
    for (const character of committed) {
      this.state.committed += character;
      this.emit(0.04);
    }
    this.emit(1.6);
  }

  select(line) {
    this.state.selection = line;
    this.emit(0.8);
  }
}

// ── 每个功能一段 ─────────────────────────────────────

const parts = {
  sentence(s) {
    s.caption('一口气打完一整句');
    s.type("xiang'qu'zi'jie'shang'ban", ['想去直接上班', '想去', '西昂区', '想娶', '相去', '想取', '乡曲']);
    s.caption('按空格整句上屏');
    s.choose(0);
  },
  initials(s) {
    s.caption('只打声母：bjdx');
    s.type("b'j'd'x", ['北京大学', '比较典型', '比较担心', '编辑短信', '比较对象']);
    s.choose(0, { hold: 1.2 });
  },
  typo(s) {
    s.caption('手快按反了：zhognguo');
    s.type("zhogn'guo", ['中国', '🇨🇳', '种过', '重过', '种果', '中过', '中果', '中古']);
    s.caption('照样认出「中国」');
    s.wait(0.8);
    s.choose(0, { hold: 1.2 });
  },
  english(s) {
    s.caption('不切换，直接打英文');
    s.type('github', ['GitHub', 'GitHub Pages', 'GitHub Actions', 'GitHub Copilot']);
    s.caption('大小写按词表来');
    s.wait(0.6);
    s.choose(0, { hold: 1.2 });
  },
  split(s) {
    s.caption('第一个候选不是想要的');
    s.type("ni'hao'zhong'guo", ['你好中国', '你好重', '你好', '👋', '利好', '你号', '立好']);
    s.caption('先按 3 选「你好」');
    s.choose(2, { rest: ["zhong'guo", ['中国', '🇨🇳', '种过', '重过', '种果', '中过', '中果', '中古']] });
    s.caption('剩下的接着选');
    s.choose(0, { hold: 1.2 });
  },
  emoji(s) {
    s.caption('打「开心」');
    s.type("kai'xin", ['开心', '😄', '开新', '开薪', '开', '凯', '慨', '嘅', '楷']);
    s.caption('候选里接着出 emoji');
    s.wait(0.6);
    s.choose(1, { hold: 1.2 });
  },
  shift(s) {
    s.caption('打到一半想打英文');
    s.type('hello', ['hello', '喝牛奶', '和能力', '喝奶奶', '河流里', '河里捞']);
    s.caption('单按 ⇧，字母原样上屏');
    s.press('⇧', 0.9, (st) => {
      st.committed += st.pinyin;
      st.pinyin = '';
      st.candidates = [];
      st.toast = '英';
    });
    s.caption('接着打英文');
    s.typeCommitted(' world');
    s.caption('再按 ⇧ 切回中文');
    s.press('⇧', 1.4, (st) => { st.toast = '中'; });
    s.state.toast = null;
    s.wait(0.3);
  },
  voice(s) {
    s.caption('按住右 ⌘ 说话，边说边出字');
    s.speak('右 ⌘', '今天天气不错。', '今天天气不错。');
  },
  cleanup(s) {
    s.caption('嗯、呃、那个……自动清掉');
    s.speak('右 ⌘', '呃，那个，我想问一下，评审几点开始？', '我想问一下，评审几点开始？');
  },
  candidateTranslation(s) {
    s.caption('单按 ⌃ 翻译候选');
    s.type("ni'hao'shi'jie", ['你好世界', '你好是', '你好似', '你好时', '你好事', '你好', '👋']);
    s.press('⌃', 1.4, (st) => { st.translation = 'Hello World'; });
    s.caption('按 ⏎ 上屏译文');
    s.press('⏎', 1.2, (st) => {
      st.committed += st.translation ?? '';
      st.pinyin = '';
      st.candidates = [];
      st.translation = null;
    });
  },
  voiceTranslation(s) {
    s.caption('按住右 ⌥ 说中文，松开输入英文');
    s.speak('右 ⌥', '今天天气不错', 'The weather is nice today.');
  },
  selection(s) {
    // 先有一句中文，再选中它翻译
    s.state.lines = ['我想问一下，评审几点开始？'];
    s.caption('选中文字，按 ⌃⌥T 看译文');
    s.wait(0.6);
    s.select(0);
    // 翻译窗口里的译文是 2026-11-17 实测的（DeepSeek、微软翻译两个源；AI 逐字出，机器翻译整段出）
    s.press('⌃⌥T', 1.6, (st) => {
      st.tw = {
        query: '我想问一下，评审几点开始？', language: '简体中文',
        cards: [
          { name: 'DeepSeek', info: true, text: 'I’d like to ask, what time does the review start?', at: 0.9, speed: 26 },
          { name: '微软翻译', text: 'I want to ask, what time does the judging start?', at: 0.45 },
        ],
      };
    });
    s.caption('多个翻译源一起翻，AI 逐字出译文');
    s.wait(2.8);
    s.state.tw = null;
    s.caption('按 ⌃⌥I 直接换成译文');
    s.wait(0.5);
    s.press('⌃⌥I', 2.2, (st) => {
      st.lines[0] = 'I’d like to ask, what time does the review process begin?';
      st.selection = null;
    });
  },
};

/// 几段接在一起，段与段之间另起一行
function build(...names) {
  const s = new Script();
  names.forEach((name, i) => {
    if (i) s.newLine();
    parts[name](s);
  });
  return s.frames;
}

export const scenes = {
  // 首屏：几项主要功能连着放（照 App「功能介绍」的 overview）
  hero: () => build('sentence', 'typo', 'english', 'emoji', 'voice', 'candidateTranslation'),
  sentence: () => build('sentence', 'initials'),
  typo: () => build('typo'),
  english: () => build('english'),
  split: () => build('split'),
  emoji: () => build('emoji'),
  shift: () => build('shift'),
  voice: () => build('voice', 'cleanup'),
  candidateTranslation: () => build('candidateTranslation'),
  voiceTranslation: () => build('voiceTranslation'),
  selection: () => build('selection'),
};
