import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;

enum RemoteNetworkRoute { local, remote, unknown }

enum RemoteTransportPreference { auto, turn, relay }

RemoteNetworkRoute remoteNetworkRoute(List<ConnectivityResult> interfaces) {
  if (interfaces.contains(ConnectivityResult.wifi) || interfaces.contains(ConnectivityResult.ethernet)) {
    return RemoteNetworkRoute.local;
  }
  if (interfaces.contains(ConnectivityResult.mobile)) {
    return RemoteNetworkRoute.remote;
  }
  return RemoteNetworkRoute.unknown;
}

bool shouldRenegotiateRemoteRoute(RemoteNetworkRoute previous, RemoteNetworkRoute next) =>
    previous != RemoteNetworkRoute.unknown && next != RemoteNetworkRoute.unknown && previous != next;

List<remote.RemoteTransportMode> transportsForRemoteRoute(
  RemoteNetworkRoute route, {
  RemoteTransportPreference preference = RemoteTransportPreference.auto,
}) => switch (preference) {
  RemoteTransportPreference.auto =>
    route == RemoteNetworkRoute.remote
        ? const [remote.RemoteTransportMode.p2p, remote.RemoteTransportMode.turn, remote.RemoteTransportMode.relay]
        : remote.RemoteTransportMode.values,
  RemoteTransportPreference.turn => const [remote.RemoteTransportMode.turn, remote.RemoteTransportMode.relay],
  RemoteTransportPreference.relay => const [remote.RemoteTransportMode.relay],
};

/// Interface hints only; ICE validates actual reachability and the selected path.
List<remote.RemoteTransportMode> automaticRemoteTransports(List<ConnectivityResult> interfaces) =>
    transportsForRemoteRoute(remoteNetworkRoute(interfaces));

Future<RemoteNetworkRoute> resolveRemoteNetworkRoute() async {
  try {
    return remoteNetworkRoute(await Connectivity().checkConnectivity().timeout(const Duration(seconds: 2)));
  } catch (_) {
    return RemoteNetworkRoute.unknown;
  }
}
