// 页面的小功能：
// - 下载按钮（data-download）显示最新版本、直接下载 DMG。取不到（还没发版、断网、GitHub API 限流）就保持原样：
//   「下载 WoType」，点了去 Releases 页
// - 复制按钮（data-copy="元素 id"）复制命令

const REPO = 'HelloMateoToday/WoType';

async function latestRelease() {
  const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { Accept: 'application/vnd.github+json' },
  });
  if (!response.ok) return null;
  const release = await response.json();
  const dmg = release.assets?.find((asset) => asset.name.endsWith('.dmg'));
  return dmg ? { version: release.tag_name, url: dmg.browser_download_url } : null;
}

latestRelease().then((release) => {
  if (!release) return;
  for (const link of document.querySelectorAll('[data-download]')) link.href = release.url;
  for (const label of document.querySelectorAll('[data-download-label]')) label.textContent = `下载 WoType ${release.version}`;
}).catch(() => {});

for (const button of document.querySelectorAll('[data-copy]')) {
  button.addEventListener('click', async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = '已复制';
    } catch {
      button.textContent = '复制失败';
    }
    setTimeout(() => { button.textContent = '复制'; }, 1600);
  });
}
