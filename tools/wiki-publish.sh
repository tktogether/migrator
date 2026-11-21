#!/bin/bash
# tools/wiki-publish.sh — render docs/wiki into the GitHub wiki repository.
#
# GitHub wikis have two constraints the source tree does not: every page is a
# flat file at the repository root (subdirectories are not served as pages), and
# the page title is the file name with dashes turned into spaces. This script
# therefore renames pages to their Chinese titles, rewrites every relative link
# to an absolute wiki path, and adds the sidebar and footer. Nothing is edited by
# hand in the wiki repository; re-run the script after changing docs/wiki.
#
# Usage: tools/wiki-publish.sh [--no-push]
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
REMOTE=${WIKI_REMOTE:-https://github.com/tktogether/migrator.wiki.git}
PUSH=yes
[ "${1:-}" = "--no-push" ] && PUSH=no

command -v git >/dev/null 2>&1 || { echo "git not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! git clone --quiet "$REMOTE" "$work/wiki" 2>/dev/null; then
	echo "cannot clone $REMOTE" >&2
	exit 1
fi

python3 - "$REPO" "$work/wiki" <<'PY' || exit 1
import posixpath, re, shutil, sys, pathlib

repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = repo / "docs" / "wiki"
base = "/tktogether/migrator/wiki"
version = (repo / "VERSION").read_text(encoding="utf-8").strip()

# source page, wiki page, sidebar label
PAGES = [
    ("README.md", "Home.md", None),
    ("01-overview.md", "01-产品概览.md", "产品概览"),
    ("02-install.md", "02-安装与构建.md", "安装与构建"),
    ("03-quickstart.md", "03-快速开始.md", "快速开始"),
    ("04-modes.md", "04-迁移模式.md", "迁移模式"),
    ("05-stages.md", "05-阶段与执行流程.md", "阶段与执行流程"),
    ("06-options.md", "06-选项参考.md", "选项参考"),
    ("07-plan-file.md", "07-计划文件.md", "计划文件"),
    ("08-network-and-firmware.md", "08-网络与固件.md", "网络与固件"),
    ("09-transfer-and-consistency.md", "09-传输与一致性.md", "传输与一致性"),
    ("10-verify-and-acceptance.md", "10-验证与验收.md", "验证与验收"),
    ("11-troubleshooting.md", "11-故障排查.md", "故障排查"),
    ("12-faq.md", "12-常见问题.md", "常见问题"),
    ("13-security.md", "13-安全与信任边界.md", "安全与信任边界"),
    ("14-license.md", "14-许可与再分发政策.md", "许可与再分发政策"),
    ("maintainers/README.md", "维护者-索引.md", "维护者索引"),
    ("maintainers/architecture.md", "维护者-代码结构.md", "代码结构与数据流"),
    ("maintainers/inventory-format.md", "维护者-清单格式.md", "清单记录格式"),
    ("maintainers/rig.md", "维护者-实验台.md", "QEMU 实验台"),
    ("maintainers/live-build.md", "维护者-Live-构建.md", "迁移 Live 构建"),
    ("maintainers/testing.md", "维护者-测试体系.md", "测试体系"),
    ("maintainers/release.md", "维护者-发布与安装布局.md", "发布与安装布局"),
]
TARGET = {s: d for s, d, _ in PAGES}
LINK = re.compile(r'(?<!\\)(!?)\[([^\]]*)\]\(([^)\s]+)\)')


def url(dst):
    slug = dst[:-3]
    return base if slug == "Home" else base + "/" + slug


def retarget(filedir, target):
    if target.startswith(("http://", "https://", "#", "mailto:")):
        return None
    path = posixpath.normpath(posixpath.join(filedir, target))
    if target.endswith(".md"):
        if path not in TARGET:
            raise SystemExit("unmapped link %s in %s" % (target, filedir or "docs/wiki"))
        return url(TARGET[path])
    return base + "/" + path


def convert(filedir, text):
    lines, fenced = [], False
    for line in text.splitlines(True):
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            lines.append(line)
            continue
        if fenced:
            lines.append(line)
            continue

        def sub(m):
            new = retarget(filedir, m.group(3))
            if new is None:
                return m.group(0)
            return "%s[%s](%s)" % (m.group(1), m.group(2), new)

        lines.append(LINK.sub(sub, line))
    return "".join(lines)


for entry in out.iterdir():
    if entry.name == ".git":
        continue
    shutil.rmtree(entry) if entry.is_dir() else entry.unlink()

for page, dst, _ in PAGES:
    body = (src / page).read_text(encoding="utf-8")
    (out / dst).write_text(convert(posixpath.dirname(page), body), encoding="utf-8")

(out / "assets").mkdir()
for f in sorted((src / "assets").iterdir()):
    shutil.copy2(f, out / "assets" / f.name)

user = [(d, t) for s, d, t in PAGES if t and not d.startswith("维护者-")]
maint = [(d, t) for s, d, t in PAGES if d.startswith("维护者-")]
bar = ["## 用户文档", ""]
bar += ["- [%s](%s)" % (t, url(d)) for d, t in user]
bar += ["", "## 维护者文档", ""]
bar += ["- [%s](%s)" % (t, url(d)) for d, t in maint]
bar += ["", "---", "", "[文档首页](%s)" % url("Home.md")]
(out / "_Sidebar.md").write_text("\n".join(bar) + "\n", encoding="utf-8")
(out / "_Footer.md").write_text(
    "migrator %s · 文档源：`tktogether/migrator` 仓库 `docs/wiki/`，与代码同版本发布。\n" % version,
    encoding="utf-8")
PY

cd "$work/wiki" || exit 1
git add -A
if git diff --cached --quiet; then
	echo "wiki is already up to date"
	exit 0
fi
git commit --quiet -m "docs: sync from docs/wiki"
if [ "$PUSH" = yes ]; then
	git push --quiet origin HEAD || { echo "push failed" >&2; exit 1; }
	echo "wiki updated: $(git log --oneline -1)"
else
	echo "staged but not pushed (--no-push)"
fi
