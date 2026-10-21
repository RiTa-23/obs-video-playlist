// 最新 Release の配布用 zip を調べる（/download と /api/latest で共用）
//
// 配布用 zip の名前は release.yml で obs-video-playlist-<タグ>.zip と決まっているので、
// 最新版のタグさえ分かれば直リンクを組み立てられる。
// タグは GitHub API で調べ、使えないとき（API の回数制限など）は
// github.com/.../releases/latest のリダイレクト先から読み取る。

export const REPO = 'RiTa-23/obs-video-playlist';
export const RELEASES_URL = `https://github.com/${REPO}/releases/latest`;
const ASSET = /^obs-video-playlist-v[\d.]+\.zip$/;
const CACHE_TTL = 300; // 秒

function apiHeaders(env) {
  const h = { 'User-Agent': 'obs-video-playlist-site', Accept: 'application/vnd.github+json' };
  // 任意：Cloudflare の環境変数に GITHUB_TOKEN を入れると API の回数制限が緩くなる
  if (env && env.GITHUB_TOKEN) h.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  return h;
}

async function fromApi(env) {
  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: apiHeaders(env),
    cf: { cacheTtl: CACHE_TTL, cacheEverything: true },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const rel = await res.json();
  const asset = (rel.assets || []).find((a) => ASSET.test(a.name));
  if (!asset) throw new Error('配布用 zip がまだ添付されていません');
  return {
    tag: rel.tag_name,
    publishedAt: rel.published_at,
    name: asset.name,
    size: asset.size,
    url: asset.browser_download_url,
  };
}

async function fromRedirect() {
  const res = await fetch(RELEASES_URL, {
    method: 'HEAD',
    redirect: 'manual',
    headers: { 'User-Agent': 'obs-video-playlist-site' },
    cf: { cacheTtl: CACHE_TTL, cacheEverything: true },
  });
  const loc = res.headers.get('Location') || '';
  const m = loc.match(/\/releases\/tag\/([^/?#]+)$/);
  if (!m) throw new Error('最新版のタグを読み取れません');
  const tag = decodeURIComponent(m[1]);
  const name = `obs-video-playlist-${tag}.zip`;
  const url = `https://github.com/${REPO}/releases/download/${encodeURIComponent(tag)}/${name}`;
  // Release を公開した直後は zip の添付が終わっていないことがあるので、存在を確かめる
  const head = await fetch(url, { method: 'HEAD', redirect: 'manual', headers: { 'User-Agent': 'obs-video-playlist-site' } });
  if (head.status !== 302 && head.status !== 200) throw new Error('配布用 zip がまだ添付されていません');
  return { tag, publishedAt: null, name, size: null, url };
}

// 見つからなければ null（呼び出し側で Release ページに案内する）
export async function latestRelease(env) {
  try {
    return await fromApi(env);
  } catch (e) {
    try {
      return await fromRedirect();
    } catch (e2) {
      return null;
    }
  }
}
