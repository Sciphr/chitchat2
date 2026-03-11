import { AccessToken } from 'npm:livekit-server-sdk';
import { createClient } from 'npm:@supabase/supabase-js@2';

type ChannelRow = {
  id: string;
  server_id: string;
  kind: string;
};

type ServerRow = {
  id: string;
  owner_id: string;
};

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const liveKitApiKey = Deno.env.get('LIVEKIT_API_KEY') ?? '';
const liveKitApiSecret = Deno.env.get('LIVEKIT_API_SECRET') ?? '';

function jsonResponse(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}

function roomNameForChannel(channelId: string) {
  return `voice:${channelId}`;
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (request.method != 'POST') {
    return jsonResponse(405, { error: 'Method not allowed.' });
  }

  if (
    supabaseUrl.length === 0 ||
    supabaseAnonKey.length === 0 ||
    liveKitApiKey.length === 0 ||
    liveKitApiSecret.length === 0
  ) {
    return jsonResponse(500, {
      error:
        'Missing function secrets. Configure SUPABASE_URL, SUPABASE_ANON_KEY, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET.',
    });
  }

  const authorization = request.headers.get('Authorization');
  if (authorization == null || authorization.trim().length === 0) {
    return jsonResponse(401, { error: 'Missing Authorization header.' });
  }
  const bearerToken = authorization.replace(/^Bearer\s+/i, '').trim();
  if (bearerToken.length === 0) {
    return jsonResponse(401, { error: 'Missing bearer token.' });
  }

  let payload: { channelId?: string };
  try {
    payload = await request.json();
  } catch (_) {
    return jsonResponse(400, { error: 'Invalid JSON body.' });
  }

  const channelId = payload.channelId?.trim();
  if (channelId == null || channelId.isEmpty) {
    return jsonResponse(400, { error: 'channelId is required.' });
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
  });

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser(bearerToken);
  if (userError != null || user == null) {
    return jsonResponse(401, { error: 'Invalid session.' });
  }

  const { data: channel, error: channelError } = await supabase
    .from('channels')
    .select('id, server_id, kind')
    .eq('id', channelId)
    .maybeSingle<ChannelRow>();
  if (channelError != null) {
    return jsonResponse(500, { error: channelError.message });
  }
  if (channel == null || channel.kind != 'voice') {
    return jsonResponse(404, { error: 'Voice channel not found.' });
  }

  const [{ data: membership, error: membershipError }, { data: server, error: serverError }] =
    await Promise.all([
      supabase
        .from('server_members')
        .select('user_id')
        .eq('server_id', channel.server_id)
        .eq('user_id', user.id)
        .maybeSingle(),
      supabase
        .from('servers')
        .select('id, owner_id')
        .eq('id', channel.server_id)
        .maybeSingle<ServerRow>(),
    ]);

  if (membershipError != null) {
    return jsonResponse(500, { error: membershipError.message });
  }
  if (serverError != null) {
    return jsonResponse(500, { error: serverError.message });
  }

  const isMember = membership != null;
  const isOwner = server?.owner_id == user.id;
  if (!isMember && !isOwner) {
    return jsonResponse(403, {
      error: 'You do not have access to this voice channel.',
    });
  }

  const token = new AccessToken(liveKitApiKey, liveKitApiSecret, {
    identity: user.id,
    name:
      (user.user_metadata?.display_name as string | undefined) ??
      user.email ??
      'Anonymous',
    metadata: JSON.stringify({
      user_id: user.id,
      display_name:
        (user.user_metadata?.display_name as string | undefined) ??
        user.email ??
        'Anonymous',
      channel_id: channelId,
    }),
  });

  token.addGrant({
    roomJoin: true,
    room: roomNameForChannel(channelId),
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
  });

  return jsonResponse(200, {
    token: await token.toJwt(),
    roomName: roomNameForChannel(channelId),
    identity: user.id,
  });
});
