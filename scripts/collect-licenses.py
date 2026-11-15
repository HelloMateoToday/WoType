#!/usr/bin/env python3
"""把要随 App 分发的许可证收进一个目录（scripts/build-rust.sh 调用）。

    collect-licenses.py <engine/Cargo.toml> <输出目录>

输出目录里放：
- WoType 自己的 LICENSE（AGPL-3.0）和 NOTICE；
- 水杉 macOS 版随包的那几份许可证（照它的 platforms/macos/CMakeLists.txt），只取 WoType
  实际带上的部分：粤语、注音、笔画词库、本地翻译、离线语音这些 WoType 不带，不收；
- licenses/librime/ 里的：万象引擎用的 librime 发布包和它静态链进去的库（发布包不带许可证，docs/22）；
- rust-crates.txt：链接进 libwotype_core.a 的每个 Rust crate 的名字、版本、许可和它自带的
  许可证全文（相同的全文只印一次）。水杉 macOS 版的第三方声明没有逐个列这些 crate，
  MIT、Apache-2.0 都要求随副本附上声明，所以这里自己生成。
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys

# 水杉 resources/licenses 里，WoType 带上的部分（和水杉 macOS 版随包的一样，去掉不带的组件）
MSIME_LICENSES = [
    "MPL-2.0.txt",
    "msime-engine-dictionary-NOTICE.md",
    "sentence-model-Apache-2.0.txt",
    "Zinnia-LICENSE.txt",
    "pinyin-data-MIT.txt",
    "ECDICT-MIT.txt",
    "rime_kaomoji_dict-MIT.txt",
    "python-pinyin-MIT.txt",
    "rime-wanxiang-CC-BY-4.0.txt",
    "Administrative-divisions-of-China-WTFPL.txt",
    "libhangul-hanja-BSD-3-Clause.txt",
    "librime-octagram-BSD-3-Clause.txt",
    "libcxx-Apache-2.0-WITH-LLVM-exception.txt",
    "latex-symbols-MIT.txt",
    "kfcd-chaizi-CC-BY-3.0.txt",
    "Unicode-License-V3.txt",
    "OpenCC-Apache-2.0.txt",
    "world-clock-NOTICE.txt",
    "vi-MIT.txt",
    "ewts-MIT.txt",
]

LICENSE_PREFIXES = ("license", "licence", "copying", "notice", "copyright", "unlicense")


def cargo_metadata(manifest):
    out = subprocess.run(
        ["cargo", "metadata", "--manifest-path", manifest, "--format-version", "1",
         "--locked", "--filter-platform", "aarch64-apple-darwin"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def linked_packages(meta):
    """从 wotype-core 出发，只走普通依赖（构建依赖、开发依赖、过程宏不进二进制）。"""
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(p["id"] for p in meta["packages"] if p["name"] == "wotype-core")
    seen, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            if any(kind["kind"] is None for kind in dep["dep_kinds"]):
                stack.append(dep["pkg"])
    result = []
    for pid in seen:
        package = packages[pid]
        if pid == root:
            continue
        if all("proc-macro" in target["kind"] for target in package["targets"]):
            continue
        result.append(package)
    return sorted(result, key=lambda p: (p["name"], p["version"]))


def license_texts(package):
    directory = os.path.dirname(package["manifest_path"])
    names = []
    if package.get("license_file"):
        names.append(package["license_file"])
    for name in sorted(os.listdir(directory)):
        if name.lower().startswith(LICENSE_PREFIXES) and name not in names:
            names.append(name)
    texts = []
    for name in names:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                texts.append((name, f.read().strip() + "\n"))
    return texts


def write_crates(packages, path):
    bodies = {}
    lines = [
        "WoType for macOS — Rust crates linked into the input method",
        "=" * 61,
        "",
        "Each crate below is linked unmodified into libwotype_core.a. Its source is the",
        "matching version on crates.io, or the repository given. License texts follow the",
        "list; identical texts are printed once and name every crate that carries them.",
        "Crates that ship no license file are covered by the standard text of the license",
        "named in their manifest (MIT and Apache-2.0 texts are among those below; the",
        "msime crates are covered by GPL-3.0.txt and MPL-2.0.txt beside this file).",
        "",
    ]
    for package in packages:
        source = package.get("repository") or f"https://crates.io/crates/{package['name']}"
        lines.append(f"* {package['name']} {package['version']} — {package.get('license') or 'see license file'} — {source}")
        for name, text in license_texts(package):
            digest = hashlib.sha256(text.encode()).hexdigest()
            bodies.setdefault(digest, [text, []])[1].append(f"{package['name']} {package['version']} ({name})")
    for text, owners in bodies.values():
        lines += ["", "-" * 80, "Used by: " + ", ".join(owners), "-" * 80, "", text.rstrip()]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return len(packages), len(bodies)


def main():
    manifest, out = sys.argv[1], sys.argv[2]
    repo = os.path.dirname(os.path.dirname(os.path.abspath(manifest)))
    meta = cargo_metadata(manifest)
    host_api = next(p for p in meta["packages"] if p["name"] == "msime-host-api")
    msime = os.path.dirname(os.path.dirname(os.path.dirname(host_api["manifest_path"])))

    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    shutil.copyfile(os.path.join(repo, "LICENSE"), os.path.join(out, "WoType-AGPL-3.0.txt"))
    shutil.copyfile(os.path.join(repo, "NOTICE"), os.path.join(out, "NOTICE.txt"))
    shutil.copyfile(os.path.join(msime, "LICENSE"), os.path.join(out, "GPL-3.0.txt"))
    for name in MSIME_LICENSES:
        shutil.copyfile(os.path.join(msime, "resources", "licenses", name), os.path.join(out, name))
    librime = os.path.join(repo, "licenses", "librime")
    rime_licenses = sorted(os.listdir(librime))
    for name in rime_licenses:
        shutil.copyfile(os.path.join(librime, name), os.path.join(out, name))
    crates, texts = write_crates(linked_packages(meta), os.path.join(out, "rust-crates.txt"))
    count = len(MSIME_LICENSES) + len(rime_licenses) + 3
    print(f"许可证 -> {out}（{count} 份，Rust crate {crates} 个、全文 {texts} 份）")


if __name__ == "__main__":
    main()
