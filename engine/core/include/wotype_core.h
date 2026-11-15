/*
 * WoType Rust 核心的 C ABI：万象拼音引擎（wotype_engine_* / wotype_session_*）、按键码、语音润色规则。
 * 水杉的宿主层链在同一个静态库里，接口见 msime_client.h（docs/12）。两个拼音引擎可以切换（docs/15）。
 *
 * 生命周期：
 * - wotype_engine_new 成功返回句柄，必须用 wotype_engine_free 释放；
 * - wotype_engine_input 返回的候选句柄必须用 wotype_candidates_free 释放；
 * - 返回的字符串指针在对应句柄释放前有效（错误串在下一次 API 调用前有效）。
 */
#ifndef WOTYPE_CORE_H
#define WOTYPE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WotypeEngineHandle WotypeEngineHandle;
typedef struct WotypeCandidates WotypeCandidates;

/* 创建引擎；bigram_tsv_path 可为 NULL 或空串。失败返回 NULL。 */
WotypeEngineHandle *wotype_engine_new(const char *lexicon_tsv_path,
                                        const char *bigram_tsv_path);

/* 释放引擎。 */
void wotype_engine_free(WotypeEngineHandle *engine);

/* 设置 beam size；成功返回 0，失败返回 -1。 */
int wotype_engine_set_beam_size(WotypeEngineHandle *engine, unsigned int beam_size);

/* 每次输入最多返回多少个整句候选（句首词候选另算）。返回 0 成功。 */
int wotype_engine_set_max_candidates(WotypeEngineHandle *engine, unsigned int max_candidates);

/* 开关按错键纠错（相邻键、两键按反、多按/漏按），默认开。返回 0 成功。 */
int wotype_engine_set_typo_correction(WotypeEngineHandle *engine, int on);

/* 载入英文词表（每行一个词，或 rime 的 en.dict.yaml）。
 * 载入后输入已知英文词（hello、github）时英文排在前面。返回累计词条数，失败返回 -1。 */
int wotype_engine_load_english(WotypeEngineHandle *engine, const char *path);

/* 设置「这个字画不画得出来」的回调（参数是码位）：画不出来的字（系统字体里没有，显示成 ?）不出候选。
 * 只会拿 U+20000 以后的字来问，每个字问一次；回调要能在任意线程调用。传 NULL 取消。 */
void wotype_engine_set_glyph_check(WotypeEngineHandle *engine, bool (*check)(uint32_t codepoint));

/* 载入混合编码词表（万象的 dicts/mixed.dict.yaml）：编码里有字母的词，Azuo -> A座、OKla -> OK啦。
 * 整份替换，返回词条数，失败返回 -1。 */
int wotype_engine_load_mixed(WotypeEngineHandle *engine, const char *path);

/* 换一份快捷短语（quick-phrases.tsv 的内容：编码<TAB>短语，短语里的换行、制表符写成 \n \t）。
 * 整串输入正好是编码时短语进候选（第一页的最后）。整份替换，NULL 或空串清空；返回条数，失败返回 -1。 */
int wotype_engine_set_quick_phrases(WotypeEngineHandle *engine, const char *tsv);

/* 载入微信输入法的字级神经语言模型（nlrgpt2_nnlm.bin，不随 WoType 分发），
 * 用来给整句候选重排。返回字表大小，失败返回 -1。 */
int wotype_engine_load_nnlm(WotypeEngineHandle *engine, const char *path);

/* 开关模糊音（z/zh、c/ch、s/sh、an/ang、en/eng、in/ing）。返回 0 成功。 */
int wotype_engine_set_fuzzy(WotypeEngineHandle *engine, int on);

/* 开关双拼（自然码方案）。返回 0 成功。 */
int wotype_engine_set_shuangpin(WotypeEngineHandle *engine, int on);

/* 开关繁体输出。返回 0 成功。 */
int wotype_engine_set_traditional(WotypeEngineHandle *engine, int on);

/* 载入简繁映射表（简体<TAB>繁体）。返回条目数，失败返回 -1。 */
int wotype_engine_load_conversion(WotypeEngineHandle *engine, const char *path);

/* ASCII 标点转中文标点；未收录返回 NULL。指针在下一次调用前有效。 */
const char *wotype_fullwidth_punct(int ascii_codepoint);

/* 符号检索（拼音/中文名前缀），结果用 wotype_candidates_* 读取并释放。 */
WotypeCandidates *wotype_symbol_search(const char *query, size_t limit);

/* 打字时的 emoji 推荐。text 是首选候选的文字；结果的 text 是显示文字，
 * 上屏用 wotype_candidates_commit（整个词对上时只有 emoji，句尾对上时是整句 + emoji）。 */
WotypeCandidates *wotype_emoji_recommend(const char *text, size_t limit);

/* 表情面板搜索。query 为空给全部 emoji；否则按拼音（经引擎转成中文词）、英文、
 * 符号名一起找。engine 可为 NULL。 */
WotypeCandidates *wotype_engine_emoji_search(const WotypeEngineHandle *engine,
                                               const char *query, size_t limit);

/* 记录一次选词，参与历史排序特征。返回 0 成功，-1 失败。 */
int wotype_engine_record_selection(WotypeEngineHandle *engine, const char *word);

/* 记录选词并带上拼音：选够次数后自动加入用户词库。pinyin 可为 NULL。 */
int wotype_engine_record_selection_ex(WotypeEngineHandle *engine,
                                       const char *word, const char *pinyin);

/* 设置光标前文本，参与上下文 bigram 特征。返回 0 成功，-1 失败。 */
int wotype_engine_set_context(WotypeEngineHandle *engine, const char *text);

/* 用户词库 */
int wotype_engine_add_user_word(WotypeEngineHandle *engine, const char *pinyin,
                                 const char *word);
int wotype_engine_remove_user_word(WotypeEngineHandle *engine, const char *word);
int wotype_engine_save_user_dict(WotypeEngineHandle *engine, const char *path);
int wotype_engine_load_user_dict(WotypeEngineHandle *engine, const char *path);
/* 自定义词（设置里添加的，custom.tsv：拼音<TAB>词[<TAB>频次]）：整体替换上一次读到的，
 * 文件不存在就清空；不写回用户词库。返回收下的条数，-1 表示出错。 */
int wotype_engine_load_custom_words(WotypeEngineHandle *engine, const char *path);

/* 用户输入习惯：选过的词的热度（30 天半衰期）和词搭配（上一个词 -> 这个词），
 * 参与排序，存成 TSV。save 返回 0 成功；load 返回条数，-1 表示出错。 */
int wotype_engine_save_history(WotypeEngineHandle *engine, const char *path);
int wotype_engine_load_history(WotypeEngineHandle *engine, const char *path);

/* 输入拼音串；失败返回 NULL。 */
WotypeCandidates *wotype_engine_input(WotypeEngineHandle *engine, const char *input);

/**
 * 基于上一词的预测（预测词库）。
 * 成功返回候选集合（text 为预测词，score 为对数概率），必须 wotype_candidates_free；
 * 失败返回 NULL，用 wotype_last_error 取原因。
 */
WotypeCandidates *wotype_engine_predict_next(const WotypeEngineHandle *engine,
                                               const char *prev_word,
                                               size_t limit);

/* 候选数量。 */
size_t wotype_candidates_len(const WotypeCandidates *candidates);

/* 候选文本（UTF-8，NUL 结尾）；索引越界返回 NULL。 */
const char *wotype_candidates_text(const WotypeCandidates *candidates, size_t index);

/* 候选分数；索引越界返回 0。 */
double wotype_candidates_score(const WotypeCandidates *candidates, size_t index);

/* 候选拼音（空格分隔音节，纠错后的写法），可传给 record_selection_ex；
 * 预测/符号结果为空串，越界返回 NULL。 */
const char *wotype_candidates_pinyin(const WotypeCandidates *candidates, size_t index);

/* 候选用掉了输入的多少字节。等于输入长度是整句候选；小于时是句首词候选，
 * 上屏后应把 input + consumed 之后的部分留在编辑区继续输入。越界返回 0。 */
size_t wotype_candidates_consumed(const WotypeCandidates *candidates, size_t index);

/* 选中后上屏的文字（emoji 推荐可能和显示的不同），其他候选等于 text。越界返回 NULL。 */
const char *wotype_candidates_commit(const WotypeCandidates *candidates, size_t index);

/* 释放候选集合。 */
void wotype_candidates_free(WotypeCandidates *candidates);

/* 编辑区显示用：按候选拼音（空格分隔，wotype_candidates_pinyin）给输入分词，
 * hengxiang + "heng xiang" -> heng'xiang。保留用户打的字母（大小写、按错的键）。
 * 切不了（英文、双拼、差得太多）返回 NULL；返回的串在同一线程下一次调用前有效。 */
const char *wotype_segment_input(const char *input, const char *pinyin);

/* 最近一次错误信息，可能为空串。 */
const char *wotype_last_error(void);

/* 模糊音规则：逗号分隔的规则 id，NULL 或空串表示一条都不开。所有引擎共用，返回认出来的条数。
 * 可选：声母 z=zh c=ch s=sh g=k h=f n=l r=l；韵母 an=ang en=eng in=ing an=ai eng=ong ian=iang
 * uan=uang un=ong un=iong；整音节 hui=fei huang=wang。
 * 规则只决定「哪些音节算一样」；模糊音生不生效还要 wotype_engine_set_fuzzy 打开。 */
int wotype_set_fuzzy_rules(const char *rules);

/* 指定词库快照（*.wcache）目录，要在 wotype_engine_new 之前调用；NULL 或空串恢复默认。
 * 设了以后快照只写这里，不再写到词库旁边（macOS 上词库在 App 包里，写进去会破坏签名）。 */
void wotype_set_cache_dir(const char *dir);

/* 词库有没有能直接映射的快照：1 有，0 没有。
 *
 * 有快照时 wotype_engine_new 直接映射它，词库不占进程内存。没有时要解析 TSV，用掉一百多 MB，
 * 而且释放后 macOS 的分配器不还给系统，进程的内存占用会一直停在高位。所以常驻的进程应当：
 * 没有快照时先起一个子进程调 wotype_lexicon_build_cache（它退出内存就全还了），再 wotype_engine_new。
 * 两个函数都要先 wotype_set_cache_dir。 */
int wotype_lexicon_cache_ready(const char *lexicon_path);
/* 给词库建快照（已经有就什么都不做）：1 建好了，0 没建成。 */
int wotype_lexicon_build_cache(const char *lexicon_path);
/* 删掉这个词库的快照（词库本身不要了的时候调，免得几十 MB 的快照留在缓存目录里）。 */
void wotype_lexicon_remove_cache(const char *lexicon_path);

/* 在线更新词库：把万象的词表目录（rime-wanxiang-data 的 dicts）转成 WoType 的词库，
 * 写 out_dir/lexicon.tsv 和 out_dir/english.txt。hotwords（WoType 的热词表）可以是 NULL；
 * source 写进词库开头的注释（版本等），可以是 NULL。
 * 词条少于 min_entries、或者少了常用词（词表格式变了）算失败，不留下文件。
 * 返回词条数；失败返回 -1，原因见 wotype_last_error。
 * 解析一百多万行要一百多 MB 内存：在子进程里调。快照等载入时再建（wotype_lexicon_build_cache）。 */
long long wotype_wanxiang_convert(const char *dicts_dir, const char *hotwords, const char *out_dir,
                                   size_t min_entries, const char *source);

/* 版本号，例如 0.1.0。 */
const char *wotype_version(void);

/*
 * 输入会话：一个输入框里的交互状态机（编辑区、已选的句首词、翻页、展开网格、表情面板），
 * 前端只把按键交进来，再按快照画编辑区和候选、把要上屏的文字交给应用。
 *
 * 每个输入框一个会话。引擎句柄每次调用都传进来，还在后台载入时传 NULL（字母照常进编辑区）。
 * 所有会话都只能在同一个线程里用。
 */
typedef struct WotypeSession WotypeSession;

/* 按键码：可打印字符直接用 Unicode 码点（空格是 0x20）；功能键用下面的值。 */
enum {
    WOTYPE_KEY_BACKSPACE = 0x1000,
    WOTYPE_KEY_RETURN = 0x1001,
    WOTYPE_KEY_ESCAPE = 0x1002,
    WOTYPE_KEY_TAB = 0x1003,
    WOTYPE_KEY_DELETE = 0x1004,
    WOTYPE_KEY_LEFT = 0x1005,
    WOTYPE_KEY_RIGHT = 0x1006,
    WOTYPE_KEY_UP = 0x1007,
    WOTYPE_KEY_DOWN = 0x1008,
    WOTYPE_KEY_PAGE_UP = 0x1009,
    WOTYPE_KEY_PAGE_DOWN = 0x100A,
    WOTYPE_KEY_HOME = 0x100B,
    WOTYPE_KEY_END = 0x100C,
};

/* 修饰键位。带 CONTROL / OPTION / COMMAND 的按键一律交还给应用。 */
enum {
    WOTYPE_MOD_SHIFT = 1,
    WOTYPE_MOD_CONTROL = 2,
    WOTYPE_MOD_OPTION = 4,
    WOTYPE_MOD_COMMAND = 8,
    WOTYPE_MOD_CAPSLOCK = 16,
};

WotypeSession *wotype_session_new(void);
void wotype_session_free(WotypeSession *session);

/* 处理一个按键（只给按下，不给松开）。返回 1 表示吃掉了，0 表示交还给应用。 */
int wotype_session_key(WotypeSession *session, const WotypeEngineHandle *engine,
                        unsigned int key, unsigned int modifiers);
/* 鼠标点了当前显示的第 index 个候选（快照 candidates 里的下标）。返回 1 表示选上了。 */
int wotype_session_select(WotypeSession *session, const WotypeEngineHandle *engine,
                           size_t index);
/* 翻页：delta < 0 上一页，> 0 下一页（网格里一次一屏）。返回 1 表示翻了。 */
int wotype_session_page(WotypeSession *session, int delta);
/* 展开或收起网格（候选窗右边的 ∨ / ∧，横排竖排都能用）。返回 1 表示变了。 */
int wotype_session_toggle_grid(WotypeSession *session);
/* 光标前的文字（应用里真实的上下文），参与排序；NULL 表示清空。
 * 也用来判断下一个键前面是不是数字（光标前是数字，或者上一个键是数字，任一成立就算）：
 * 只对紧接着的那一次 wotype_session_key 有效。 */
void wotype_session_set_context(WotypeSession *session, const char *text);
/* 失去焦点或切走。commit_pending 非 0（切英文、切输入法）时把已选的词和原始字母
 * 放进下一次快照的 commit；为 0（失去焦点）时直接清空，不往别的窗口上屏。 */
void wotype_session_reset(WotypeSession *session, const WotypeEngineHandle *engine,
                           int commit_pending);
/* 打开或关闭表情面板；打了一半的拼音拿来当搜索词。 */
void wotype_session_toggle_emoji(WotypeSession *session, const WotypeEngineHandle *engine);
/*
 * 当前状态的 JSON 快照，顺带取走要上屏的文字和学习次数（只给一次）。handled 原样写进去。
 * 返回的串在下一次调用这个会话的任何函数前有效。字段：
 *   handled    bool    这次按键是否被吃掉
 *   commit     string  要上屏的文字（可能为空）
 *   learned    int     上次快照以来学了几次选词（前端据此决定何时保存用户词库）
 *   mode       string  idle（收起）/ list（候选列表）/ grid（下键展开的网格）/ emoji（表情面板）
 *   selected   string  编辑区里已选好的词
 *   remaining  string  编辑区里还没选的拼音（分好音节）；表情面板时是搜索词
 *   caret      int     ← → 移到拼音中间时光标在 remaining 里的位置（UTF-16），候选只是光标前那段的；在末尾时没有这个字段
 *   horizontal bool    这一屏横排还是竖排（日期、时间格式展开时竖排，别的都是横排）
 *   columns    int     网格每行几个（list 时为 0）
 *   first      int     candidates[0] 在全部候选里的下标
 *   cursor     int     光标在 candidates 里的下标
 *   total      int     全部候选个数
 *   has_prev / has_next  bool  还有上一页 / 下一页
 *   candidates [{text, emoji, whole, icon?}]  当前显示的候选：列表是当前页，网格是光标所在的一屏；
 *              icon 是候选前要画的图标（SF Symbols 名，日期、时间候选是 calendar）
 *   raw          原样输入（打拼音途中按了 . 或 @）：候选是原样文字，不显示编号，空格、回车上屏
 *   caret_back   上屏后光标要往左退几个字（自动补全的右括号），0 表示不动
 */
const char *wotype_session_snapshot(WotypeSession *session, int handled);

/* wotype_session_configure 的 options（按位或）。 */
enum {
    WOTYPE_OPT_URL_PUNCT = 1,        /* 打字途中按 . @ 进原样输入（women.、g@qq.com），照微信输入法 */
    WOTYPE_OPT_SLASH_DUNHAO = 2,     /* / 键输入顿号「、」 */
    WOTYPE_OPT_AUTO_PAIR = 4,        /* （【《“‘ 补上右半边；快照的 caret_back 是光标要往左退几个字 */
    WOTYPE_OPT_SPACE_CJK_LATIN = 8,  /* 中文与英文字母之间自动加空格 */
    WOTYPE_OPT_SPACE_CJK_DIGIT = 16, /* 中文与数字之间自动加空格 */
    WOTYPE_OPT_V_NUMBER = 32,        /* v 加数字转中文数字（v234 → 二百三十四），默认关 */
};

/* 所有会话共用的设置：每页个数（3–9）、是否推荐 emoji、紧跟在数字后面的 . 和 :
 * 是否原样输出（3.14、12:30），其余开关见 WOTYPE_OPT_*。立即生效。 */
void wotype_session_configure(unsigned int page_size, int emoji_suggest, int ascii_punct_after_digit,
                              unsigned int options);
/* 一行能放多宽（单位：候选字号的 1/100）：按宽度分页，能放几个放几个，最多 9 个。
 * 0 表示按 wotype_session_configure 的每页个数。立即生效。 */
void wotype_session_set_row_width(unsigned int width);
/* 展开时一个候选占几列（1～6）：前端按候选窗里真实的字宽量。展开后一行 6 列，放不下就换行，
 * 快照里多 rows（这一屏每行几个）、spans（每个候选占几列）。NULL 取消，改按估的字宽算。
 * 回调在调会话函数的那个线程里调用。 */
void wotype_session_set_grid_span(unsigned int (*span)(const char *text));
/* 日期、时间候选（照微信输入法：整串拼音是 riqi / rq、shijian / sj 时出一个带日历图标的候选，
 * 选它竖排展开各种格式）。前端按本地时区、农历排好：kind 0 日期、1 时间，每行一种写进 buf
 * （UTF-8，最多 len 字节，不用结尾的 0），返回写了多少字节。NULL 取消，不再出这个候选。 */
void wotype_session_set_date_formats(size_t (*formats)(unsigned int kind, char *buf, size_t len));
/* 记住的邮箱后缀存在哪个文件：上屏过的、不在内置表里的后缀（公司邮箱等），下次打 @ 时排在内置的前面，
 * 最多 5 个、最近用的在前。只存 @ 后面的部分，不存用户名。NULL 表示不记。 */
void wotype_session_set_mail_domains_path(const char *path);
/* 最近用过的 emoji 存在哪个文件（一行一个）；NULL 表示不存。 */
void wotype_session_set_recent_emoji_path(const char *path);

/* ---- 语音输入的润色规则（照 Arion 移植，src/polish）----
 * 返回文字的函数写进 out（容量 capacity 字节，含结尾的 0），返回需要的字节数（不含 0）；
 * 返回值 >= capacity 时没写全，加大缓冲区再调。 */

/* 清理口语：删语气词、口吃式的重复和明确的改口（「三点，不对，四点」留「四点」）。 */
size_t wotype_polish_clean(const char *source, char *out, size_t capacity);
/* 场景：0 日常输入、1 邮件、2 工作消息、3 编程指令、4 搜索。app 是 bundle ID，site 是网页域名（可以是空）。 */
int wotype_polish_scene(const char *app, const char *site, int search_field);
/* 场景里机械的部分：搜索并成一行、去掉句末标点；别的场景原样。 */
size_t wotype_polish_finish(int scene, const char *source, char *out, size_t capacity);
/* 模型的结果能不能上屏：1 能；0 不能（被截断、空的、带提示词的标记）。 */
int wotype_polish_deliverable(const char *candidate, int truncated);
/* 提示词用哪种语言：0 中文（只有汉字）、1 英文（只有拉丁字母）、2 混合。 */
int wotype_polish_route(const char *source);

/* 选同音词（src/polish/spelling.rs）。读音表只载一次：pypinyin 的字音 JSON 和 cmudict.dict 的路径；成功 1。 */
int wotype_polish_spelling_load(const char *readings_path, const char *dictionary_path);
/* 列候选：写出 {"text":"<给模型的用户消息>","hypotheses":[{"id":"e0","status":"unique"},…]}；读音表没载入时写空串。
 * 上下文各项可以是空串。compounds 为 1：英文按字母拼起来也算候选（润色用）；0：Arion 例子用的 Prepare。 */
size_t wotype_polish_spelling_prepare(const char *source, const char *scene, int compounds, const char *screen,
                                       const char *before, const char *after, const char *history, const char *terms,
                                       char *out, size_t capacity);
/* 按模型的选择替换：参数同上，choices 一行一个「id<TAB>keep|replace」；选择不合规矩时返回 SIZE_MAX。 */
size_t wotype_polish_spelling_apply(const char *source, const char *scene, int compounds, const char *screen,
                                     const char *before, const char *after, const char *history, const char *terms,
                                     const char *choices, char *out, size_t capacity);

/* 改错学习（src/polish/learning.rs）。分词回调：把 text 的词范围（按 Unicode 字符的开始、结束，一对一对）
 * 写进 spans（最多 capacity 个数），返回写了几个词；分不了返回 -1。 */
typedef intptr_t (*WotypeSegmenter)(const char *text, uint32_t *spans, size_t capacity);
/* 用户改了插入的文字后，找出改了哪些词：第一行是结论（learned、unchanged、outside……），
 * 后面一行一对「错误写法<TAB>正确写法」。 */
size_t wotype_polish_learn(const char *inserted, const char *baseline, const char *settled, WotypeSegmenter segmenter,
                            char *out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* WOTYPE_CORE_H */
