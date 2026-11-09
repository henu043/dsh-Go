import 'dart:async';

import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/relay/network_route.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingAccount extends remote.RemoteAccount {
  _RecordingAccount() : super(secrets: remote.MemorySecretStore());

  int connects = 0;
  final stopped = StateError('connection boundary reached');

  @override
  Future<List<remote.RemoteHost>> listHosts() async => const [
    remote.RemoteHost(id: 'host', name: 'Host', platform: 'linux', online: true, trust: remote.RemoteHostTrust.pinned),
  ];

  @override
  Future<remote.DshClient> connectHost(
    remote.RemoteHost host, {
    void Function(remote.RemoteConnectionState state)? onState,
    remote.HostTrustPrompt? confirmNewHost,
    remote.MuxOptions muxOptions = const remote.MuxOptions(),
    Duration timeout = const Duration(seconds: 30),
    Duration healthInterval = const Duration(seconds: 25),
    Duration healthTimeout = const Duration(seconds: 10),
    remote.DshTracer? tracer,
  }) async {
    connects++;
    throw stopped;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final stored in <String?>[null, 'unknown']) {
    test('missing or unknown preference $stored defaults to auto', () async {
      SharedPreferences.setMockInitialValues({RemoteTransportPreferenceController.prefsKey: ?stored});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(remoteTransportPreferenceProvider.notifier).ready;
      expect(container.read(remoteTransportPreferenceProvider), RemoteTransportPreference.auto);
    });
  }

  for (final choice in RemoteTransportPreference.values) {
    test('$choice persists across containers', () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      await first.read(remoteTransportPreferenceProvider.notifier).set(choice);
      expect(first.read(remoteTransportPreferenceProvider), choice);
      expect(
        (await SharedPreferences.getInstance()).getString(RemoteTransportPreferenceController.prefsKey),
        choice.name,
      );
      first.dispose();

      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      await restored.read(remoteTransportPreferenceProvider.notifier).ready;
      expect(restored.read(remoteTransportPreferenceProvider), choice);
    });
  }

  test('restore and changes update negotiation without recreating the backend', () async {
    SharedPreferences.setMockInitialValues({RemoteTransportPreferenceController.prefsKey: 'turn'});
    final container = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(MemorySecretStore())]);
    addTearDown(container.dispose);
    final backend = container.read(relayBackendProvider) as DshRemoteRelayBackend;
    final preference = container.read(remoteTransportPreferenceProvider.notifier);
    await preference.ready;
    expect(container.read(relayBackendProvider), same(backend));
    expect(await backend.account.preferredTransports!(), [
      remote.RemoteTransportMode.turn,
      remote.RemoteTransportMode.relay,
    ]);
    await preference.set(RemoteTransportPreference.relay);
    expect(container.read(relayBackendProvider), same(backend));
    expect(await backend.account.preferredTransports!(), [remote.RemoteTransportMode.relay]);
  });

  test('explicit preferences do not wait for a stalled native network query', () async {
    var queries = 0;
    final backend = DshRemoteRelayBackend(
      secrets: MemorySecretStore(),
      resolveNetworkRoute: () {
        queries++;
        return Completer<RemoteNetworkRoute>().future;
      },
    );
    addTearDown(backend.close);
    for (final choice in [RemoteTransportPreference.turn, RemoteTransportPreference.relay]) {
      backend.transportPreference = choice;
      expect(
        await backend.account.preferredTransports!().timeout(const Duration(milliseconds: 100)),
        choice == RemoteTransportPreference.turn
            ? [remote.RemoteTransportMode.turn, remote.RemoteTransportMode.relay]
            : [remote.RemoteTransportMode.relay],
      );
    }
    expect(queries, 0);
  });

  test('cold-start connection waits for saved preference before entering the account', () async {
    final account = _RecordingAccount();
    final saved = Completer<RemoteTransportPreference>();
    final loading = Completer<void>();
    final backend = DshRemoteRelayBackend(
      secrets: MemorySecretStore(),
      account: account,
      loadTransportPreference: () {
        loading.complete();
        return saved.future;
      },
    );
    addTearDown(backend.close);
    final host = (await backend.listHosts()).single;
    final opening = expectLater(backend.connectHost(host), throwsA(same(account.stopped)));
    await loading.future;
    expect(account.connects, 0);
    saved.complete(RemoteTransportPreference.turn);
    await opening;
    expect(account.connects, 1);
  });

  test('returning to auto consults the current network again', () async {
    var route = RemoteNetworkRoute.local;
    final backend = DshRemoteRelayBackend(secrets: MemorySecretStore(), resolveNetworkRoute: () async => route);
    addTearDown(backend.close);
    expect(await backend.account.preferredTransports!(), remote.RemoteTransportMode.values);
    backend.transportPreference = RemoteTransportPreference.turn;
    expect(await backend.account.preferredTransports!(), [
      remote.RemoteTransportMode.turn,
      remote.RemoteTransportMode.relay,
    ]);
    route = RemoteNetworkRoute.remote;
    backend.transportPreference = RemoteTransportPreference.auto;
    expect(await backend.account.preferredTransports!(), [
      remote.RemoteTransportMode.p2p,
      remote.RemoteTransportMode.turn,
      remote.RemoteTransportMode.relay,
    ]);
  });
}
