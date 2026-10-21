// /api/latest … ページに表示する最新版の情報（版名・公開日・サイズ）
import { latestRelease } from '../../lib/latest-release.js';

export async function onRequestGet({ env }) {
  const rel = await latestRelease(env);
  return new Response(JSON.stringify(rel), {
    status: rel ? 200 : 503,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    },
  });
}
