//! 场景：在哪个 App 里说的话，决定润色怎么排版（只改排版，不改意思）。
//! 照 Arion packages/core/domain/scene.go@d2108fe（AGPL-3.0-only）：DecideScene 的规则、
//! hostScenes / tenantScenes / appScenes 几张表、FinishScene。用户给 App 指定场景（SceneOverrides）以后做。

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scene {
    /// 日常输入、个人消息：一段话
    Chat,
    /// 邮件：称呼、正文、落款
    Email,
    /// 工作消息：自然的职场口吻，明确列举时才分条
    Work,
    /// 给编程助手、AI 助手的指令
    Prompt,
    /// 搜索：一行，句末不加标点
    Search,
}

impl Scene {
    pub fn name(self) -> &'static str {
        match self {
            Scene::Chat => "chat",
            Scene::Email => "email",
            Scene::Work => "work",
            Scene::Prompt => "prompt",
            Scene::Search => "search",
        }
    }

    pub fn from_name(name: &str) -> Option<Scene> {
        [Scene::Chat, Scene::Email, Scene::Work, Scene::Prompt, Scene::Search].into_iter().find(|s| s.name() == name)
    }
}

/// 选场景：搜索框最优先，再看网页的域名（精确的域名，再看企业的工作区域名），再看 App；都认不出是日常输入。
/// app 是 macOS 的 bundle ID，site 是网页的域名（小写，没有就是空）。
pub fn decide_scene(app: &str, site: &str, search_field: bool) -> Scene {
    if search_field {
        return Scene::Search;
    }
    let site = site.trim_end_matches('.').to_lowercase();
    if !site.is_empty() {
        let host = site.strip_prefix("www.").unwrap_or(&site);
        if let Some(&(_, scene)) = HOST_SCENES.iter().find(|(h, _)| *h == host) {
            return scene;
        }
        let mut tenant = Some(host);
        while let Some(t) = tenant {
            if let Some(&(_, scene)) = TENANT_SCENES.iter().find(|(h, _)| *h == t) {
                return scene;
            }
            tenant = parent_domain(t);
        }
    }
    if let Some(&(_, scene)) = APP_SCENES.iter().find(|(a, _)| *a == app) {
        return scene;
    }
    if app.starts_with("com.jetbrains.") {
        return Scene::Prompt;
    }
    Scene::Chat
}

/// mail.google.com → google.com；只剩一段时没有上一级。
fn parent_domain(host: &str) -> Option<&str> {
    let (_, parent) = host.split_once('.')?;
    parent.contains('.').then_some(parent)
}

const SENTENCE_ENDS: &str = "。．.！!？?";

/// 场景里机械的那部分：搜索是一行、句末不加标点；别的场景原样。
pub fn finish_scene(scene: Scene, text: &str) -> String {
    if scene != Scene::Search {
        return text.to_string();
    }
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ");
    joined.trim_end_matches(|c| SENTENCE_ENDS.contains(c)).to_string()
}

use Scene::*;

/// 精确的域名（不算开头的 www.）；别的子域名是别的产品：docs.google.com 不是搜索页。
const HOST_SCENES: &[(&str, Scene)] = &[
    // 网页邮箱
    ("mail.google.com", Email), ("outlook.live.com", Email), ("outlook.office.com", Email),
    ("outlook.office365.com", Email), ("mail.yahoo.com", Email), ("mail.proton.me", Email),
    ("app.fastmail.com", Email), ("mail.zoho.com", Email), ("mail.qq.com", Email),
    ("exmail.qq.com", Email), ("mail.163.com", Email), ("mail.126.com", Email),
    ("mail.aliyun.com", Email), ("qiye.aliyun.com", Email),
    // 工作消息和任务
    ("app.slack.com", Work), ("teams.microsoft.com", Work), ("teams.live.com", Work),
    ("work.weixin.qq.com", Work), ("linear.app", Work),
    // 编程助手、AI 助手、代码托管
    ("chatgpt.com", Prompt), ("chat.openai.com", Prompt), ("claude.ai", Prompt),
    ("gemini.google.com", Prompt), ("aistudio.google.com", Prompt), ("chat.deepseek.com", Prompt),
    ("kimi.com", Prompt), ("kimi.moonshot.cn", Prompt), ("doubao.com", Prompt),
    ("yuanbao.tencent.com", Prompt), ("tongyi.com", Prompt), ("perplexity.ai", Prompt),
    ("poe.com", Prompt), ("grok.com", Prompt), ("copilot.microsoft.com", Prompt),
    ("chat.mistral.ai", Prompt), ("v0.dev", Prompt), ("v0.app", Prompt), ("bolt.new", Prompt),
    ("lovable.dev", Prompt), ("replit.com", Prompt), ("github.com", Prompt), ("gitlab.com", Prompt),
    // 网页搜索
    ("google.com", Search), ("google.com.hk", Search), ("google.com.tw", Search), ("google.co.jp", Search),
    ("google.co.uk", Search), ("bing.com", Search), ("cn.bing.com", Search), ("baidu.com", Search),
    ("duckduckgo.com", Search), ("search.brave.com", Search), ("sogou.com", Search), ("kagi.com", Search),
    ("so.com", Search),
];

/// 域名和它所有的子域名：企业的工作区在各自的域名上（acme.feishu.cn）。
const TENANT_SCENES: &[(&str, Scene)] =
    &[("feishu.cn", Work), ("larksuite.com", Work), ("dingtalk.com", Work), ("atlassian.net", Work)];

/// macOS 的 bundle ID。聊天软件也明确写成日常输入，表示认出来了。
const APP_SCENES: &[(&str, Scene)] = &[
    // 邮件
    ("com.apple.mail", Email), ("com.microsoft.Outlook", Email), ("com.readdle.SparkDesktop", Email),
    ("com.readdle.smartemail-Mac", Email), ("com.mimestream.Mimestream", Email),
    ("org.mozilla.thunderbird", Email), ("com.tencent.Foxmail", Email), ("it.bloop.airmail2", Email),
    // 工作消息
    ("com.tinyspeck.slackmacgap", Work), ("com.microsoft.teams2", Work), ("com.microsoft.teams", Work),
    ("com.electron.lark", Work), ("com.alibaba.DingTalkMac", Work), ("com.tencent.WeWorkMac", Work),
    ("us.zoom.xos", Work),
    // 个人消息
    ("com.tencent.xinWeChat", Chat), ("com.tencent.qq", Chat), ("com.tdesktop.Telegram", Chat),
    ("ru.keepcoder.Telegram", Chat), ("net.whatsapp.WhatsApp", Chat), ("com.hnc.Discord", Chat),
    ("com.apple.MobileSMS", Chat), ("org.whispersystems.signal-desktop", Chat), ("jp.naver.line.mac", Chat),
    // 编辑器、终端、AI 助手
    ("com.microsoft.VSCode", Prompt), ("com.microsoft.VSCodeInsiders", Prompt),
    ("com.todesktop.230313mzl4w4u92", Prompt), ("com.exafunction.windsurf", Prompt), ("dev.zed.Zed", Prompt),
    ("com.apple.dt.Xcode", Prompt), ("com.google.android.studio", Prompt), ("com.sublimetext.4", Prompt),
    ("com.google.antigravity", Prompt), ("com.apple.Terminal", Prompt),
    ("com.googlecode.iterm2", Prompt), ("dev.warp.Warp-Stable", Prompt), ("com.mitchellh.ghostty", Prompt),
    ("com.termius.mac", Prompt), ("com.anthropic.claudefordesktop", Prompt), ("com.openai.chat", Prompt),
    ("com.openai.codex", Prompt), ("ai.opencode.desktop", Prompt), ("app.chatwise", Prompt),
    ("tech.baye.OpenCat", Prompt), ("ai.elementlabs.lmstudio", Prompt),
];

#[cfg(test)]
mod tests {
    use super::*;

    // scene_test.go 里不涉及用户指定场景的几条
    #[test]
    fn decide() {
        assert_eq!(decide_scene("com.apple.mail", "", false), Email);
        assert_eq!(decide_scene("com.apple.mail", "", true), Search);
        assert_eq!(decide_scene("com.google.Chrome", "www.google.com", false), Search);
        assert_eq!(decide_scene("com.google.Chrome", "docs.google.com", false), Chat);
        assert_eq!(decide_scene("com.google.Chrome", "acme.feishu.cn", false), Work);
        assert_eq!(decide_scene("com.google.Chrome", "mail.google.com.", false), Email);
        assert_eq!(decide_scene("com.jetbrains.goland", "", false), Prompt);
        assert_eq!(decide_scene("com.tencent.xinWeChat", "", false), Chat);
        assert_eq!(decide_scene("unknown.app", "", false), Chat);
        assert_eq!(parent_domain("feishu.cn"), None);
    }

    #[test]
    fn finish() {
        assert_eq!(finish_scene(Search, " 北京 天气\n明天。 "), "北京 天气 明天");
        assert_eq!(finish_scene(Search, "what is rust?"), "what is rust");
        assert_eq!(finish_scene(Chat, "好的。"), "好的。");
    }
}
