#!/bin/bash
# tests/cases/guides.sh — the task pages and the queue they come out of. A
# guide carries a publish date and the builder renders it only once that date
# has arrived, so the queue can be written in one sitting and released one a day
# by a timer. Both halves of that are checked here: the data is complete and in
# three languages, and the gate really hides what is not due yet.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

if ! command -v python3 >/dev/null 2>&1 || [ ! -d "$REPO/site" ]; then
	skip "the guides build" "no python3 or no site/ in this tree"
	t_end
fi

out=$(cd "$REPO" && python3 -c "
import datetime, re, sys
sys.path.insert(0, 'site')
import guides
bad = []
today = datetime.date.today().isoformat()
seen = set()
for g in guides.GUIDES:
    s = g['slug']
    if not re.match(r'^[a-z0-9]+(-[a-z0-9]+)*\$', s): bad.append('%s: not a url slug' % s)
    if s in seen: bad.append('%s: twice' % s)
    seen.add(s)
    try:
        datetime.date.fromisoformat(g['publish'])
    except Exception:
        bad.append('%s: publish is not a date (%s)' % (s, g['publish']))
    for l in ('en', 'uk', 'ru'):
        if l not in g: bad.append('%s: no %s' % (s, l)); continue
        p = g[l]
        for k in ('title', 'description', 'h1', 'lead', 'body'):
            if not p.get(k, '').strip(): bad.append('%s/%s: %s is empty' % (s, l, k))
        if not 20 <= len(p['title']) <= 75: bad.append('%s/%s: title is %d characters' % (s, l, len(p['title'])))
        if not 110 <= len(p['description']) <= 165: bad.append('%s/%s: description is %d characters' % (s, l, len(p['description'])))
        words = len(re.sub(r'<[^>]+>', ' ', p['body']).split())
        if words < 300: bad.append('%s/%s: only %d words, too thin to publish' % (s, l, words))
        for tag in re.findall(r'<(/?)(h1|h2|p|ul|li|pre|code|table)\b', p['body']):
            pass
    for l in ('en', 'uk', 'ru'):
        if guides.PAGE[l].keys() != guides.PAGE['en'].keys(): bad.append('PAGE[%s] has other keys' % l)
print('; '.join(bad))")
assert_eq "every guide is complete and in three languages" "" "$out"

# the gate: a guide dated tomorrow is nowhere, with RELOCA_PREVIEW_ALL it is everywhere
OUT=$(mktemp -d /var/tmp/xslive-reloca-guides.XXXXXX) || exit 1
trap 'rm -rf "$OUT"' EXIT
today=$(cd "$REPO" && python3 -c "
import datetime, sys; sys.path.insert(0, 'site'); import guides
t = datetime.date.today().isoformat()
print(sum(1 for g in guides.GUIDES if g['publish'] <= t), len(guides.GUIDES))")
live=${today% *}; total=${today#* }
out=$(cd "$REPO" && python3 site/build.py "$OUT/now" 2>&1)
assert_has "the build says how many guides are live" "($live of $total guides live" "$out"
pub=$(cd "$REPO" && python3 -c "
import datetime, sys; sys.path.insert(0, 'site'); import guides
t = datetime.date.today().isoformat()
print('\n'.join(g['slug'] for g in guides.GUIDES if g['publish'] <= t))")
fut=$(cd "$REPO" && python3 -c "
import datetime, sys; sys.path.insert(0, 'site'); import guides
t = datetime.date.today().isoformat()
print('\n'.join(g['slug'] for g in guides.GUIDES if g['publish'] > t))")
for s in $pub; do
	for l in "" uk/ ru/; do
		if [ -s "$OUT/now/${l}guides/$s/index.html" ]; then _pass "published: ${l}guides/$s"; else _fail "published: ${l}guides/$s" "missing"; fi
	done
	if grep -q "guides/$s/" "$OUT/now/sitemap.xml"; then _pass "in the sitemap: $s"; else _fail "in the sitemap: $s" "absent"; fi
	if grep -q "guides/$s/" "$OUT/now/ru/guides/index.html"; then _pass "listed on the index: $s"; else _fail "listed on the index: $s" "absent"; fi
done
for s in $fut; do
	if [ -e "$OUT/now/guides/$s" ]; then _fail "not due yet: $s" "it was rendered"; else _pass "not due yet: $s"; fi
	if grep -q "guides/$s/" "$OUT/now/sitemap.xml"; then _fail "not in the sitemap yet: $s" "it is there"; else _pass "not in the sitemap yet: $s"; fi
	if grep -q "guides/$s/" "$OUT/now/ru/guides/index.html"; then _fail "not on the index yet: $s" "it is there"; else _pass "not on the index yet: $s"; fi
done
out=$(cd "$REPO" && RELOCA_PREVIEW_ALL=1 python3 site/build.py "$OUT/all" 2>&1)
assert_has "preview renders the whole queue" "($total of $total guides live, preview" "$out"
for s in $fut; do
	if [ -s "$OUT/all/guides/$s/index.html" ]; then _pass "preview shows: $s"; else _fail "preview shows: $s" "missing"; fi
done

# a guide page must carry what a search engine and a reader need
for s in $pub; do
	html=$(cat "$OUT/now/ru/guides/$s/index.html")
	assert_has "$s: canonical"      '<link rel="canonical" href="https://reloca.to/ru/guides/' "$html"
	assert_has "$s: hreflang"       'hreflang="x-default"' "$html"
	assert_has "$s: breadcrumbs"    '"@type":"BreadcrumbList"' "$html"
	assert_has "$s: the prose body" '<div class="prose">' "$html"
	assert_has "$s: the way on"     'curl -fsSL reloca.to | bash' "$html"
	break
done

t_end
