// Zoomies "push" Edge Function: sends one Web Push notification to every phone of one person.
// Called only by the database (private.push in features.sql), which sends the shared HOOK_SECRET header.
// Secrets (Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, HOOK_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
// Deploy with "Verify JWT" OFF (the secret header is the check).
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) ?? '';
webpush.setVapidDetails(env('VAPID_SUBJECT') || 'mailto:admin@example.com', env('VAPID_PUBLIC_KEY'), env('VAPID_PRIVATE_KEY'));
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method', { status: 405 });
  if (!env('HOOK_SECRET') || req.headers.get('x-zoomies-hook') !== env('HOOK_SECRET')) return new Response('forbidden', { status: 403 });
  let msg: { user_id?: string; title?: string; body?: string; url?: string; tag?: string | null };
  try { msg = await req.json(); } catch { return new Response('bad json', { status: 400 }); }
  if (!msg.user_id || !msg.title) return new Response('missing', { status: 400 });

  const { data: subs, error } = await sb.from('push_subscriptions').select('endpoint, p256dh, auth').eq('user_id', msg.user_id);
  if (error) return new Response(error.message, { status: 500 });

  const payload = JSON.stringify({ title: String(msg.title).slice(0, 120), body: String(msg.body ?? '').slice(0, 300), url: msg.url || './', tag: msg.tag || undefined });
  let sent = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint); // phone unsubscribed
    }
  }));
  return new Response(JSON.stringify({ sent }), { headers: { 'Content-Type': 'application/json' } });
});
