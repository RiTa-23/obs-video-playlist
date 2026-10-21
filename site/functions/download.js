// /download … 最新版の配布用 zip へ転送する（クリックでそのままダウンロードが始まる）
import { latestRelease, RELEASES_URL } from '../lib/latest-release.js';

export async function onRequestGet({ env }) {
  const rel = await latestRelease(env);
  return new Response(null, {
    status: 302,
    headers: {
      Location: rel ? rel.url : RELEASES_URL,
      'Cache-Control': 'no-store',
    },
  });
}
