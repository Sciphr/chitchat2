# ChitChat

Desktop-first Flutter chat scaffold for Windows, macOS, and Linux using:

- Supabase Auth and Postgres for server, channel, and chat persistence
- Supabase Realtime Broadcast and Presence for WebRTC signaling
- `flutter_webrtc` for peer-to-peer media transport
- Native desktop source enumeration with `desktopCapturer.getSources`

## What is implemented

- Email/password sign-in and account creation
- Discord-style server create/join flows backed by `servers` and `server_members`
- Text channels backed by `channels` and `channel_messages`
- Voice channels that use private Realtime Broadcast plus Presence for signaling
- STUN-only WebRTC setup using `stun:stun.l.google.com:19302`
- Voice, camera, and desktop screen sharing in voice channels
- Custom screen/window picker built from `DesktopCapturerSource` thumbnails in a Flutter `GridView`
- SQL migrations with RLS for servers, members, roles, channels, channel messages, and Realtime authorization
- macOS entitlements and Android permissions for camera/microphone access

## Run locally

Apply the Supabase migrations first:

```text
supabase/migrations/20260310_001_initial_schema.sql
supabase/migrations/20260310_002_servers_channels.sql
supabase/migrations/20260310_003_server_creation_policy_fix.sql
supabase/migrations/20260310_004_user_profiles_and_permission_enforcement.sql
supabase/migrations/20260310_005_channel_overrides_and_voice_topics.sql
```

If you are using the Supabase CLI, `supabase db push` will apply both in order.

Store local Supabase settings in a file such as `config/dart_defines.local.json`
using `config/dart_defines.example.json` as the template. Keep the local file
out of version control.

Then launch the app with your Supabase project values:

```bash
flutter run -d windows --dart-define-from-file=config/dart_defines.local.json
```

## Notes

- Windows desktop plugin builds require Developer Mode because Flutter uses symlinks for plugin registration.
- Realtime signaling for voice uses private Broadcast channels named `voice:<channel-id>`.
- Chat persistence uses Postgres-backed tables; only signaling is kept off Postgres Changes.
- The app includes a server settings dialog for creating roles, editing role permissions, and assigning roles to members.
- The app includes channel-specific allow/deny overrides for view, send, join voice, camera, and screen-share permissions.
- Voice signaling now uses split Realtime topics for presence, base signaling, camera signaling, and screen signaling so media-specific permissions can be enforced by topic.
- Server-level permissions are enforced for channel management, invites, role management, text sending, voice-channel joins, and channel visibility.
- On macOS, screen recording permission is handled by the OS TCC prompt when capture starts. Camera and microphone entitlements are included in the project files.
- The app now uses a local desktop capture bridge in [desktop_capture_bridge.dart](d:/chitchat2/lib/src/desktop_capture_bridge.dart) so app code does not call `navigator.mediaDevices.getDisplayMedia` directly.
