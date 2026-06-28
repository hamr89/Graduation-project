import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../app_theme.dart';
import '../services/firestore_service.dart';
import '../services/routing_service.dart';

class ManagerBusTrackingScreen extends StatefulWidget {
  const ManagerBusTrackingScreen({super.key});

  @override
  State<ManagerBusTrackingScreen> createState() =>
      _ManagerBusTrackingScreenState();
}

class _ManagerBusTrackingScreenState extends State<ManagerBusTrackingScreen> {
  String? _selectedBusId;
  List<Map<String, dynamic>> _buses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBuses();
  }

  Future<void> _loadBuses() async {
    final buses = await context.read<FirestoreService>().getBuses();
    if (mounted) {
      setState(() {
        _buses = buses;
        if (buses.isNotEmpty) _selectedBusId = buses.first['id'] as String;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: AppTheme.backgroundWhite,
      appBar: AppBar(
        title: const Text('Live Bus Tracking',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: DropdownButtonFormField<String>(
              value: _selectedBusId,
              decoration: InputDecoration(
                labelText: 'Select Bus to Track',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.directions_bus,
                    color: AppTheme.primaryBlue),
              ),
              items: _buses
                  .map((b) => DropdownMenuItem(
                        value: b['id'] as String,
                        child: Text(b['name'] as String? ?? b['id'] as String),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedBusId = v),
            ),
          ),
          Expanded(
            child: _selectedBusId == null
                ? const Center(child: Text('Please select a bus'))
                : _ManagerBusMapContent(
                    key: ValueKey(_selectedBusId!), busId: _selectedBusId!),
          ),
        ],
      ),
    );
  }
}

class _ManagerBusMapContent extends StatefulWidget {
  const _ManagerBusMapContent({super.key, required this.busId});

  final String busId;

  @override
  State<_ManagerBusMapContent> createState() => _ManagerBusMapContentState();
}

class _ManagerBusMapContentState extends State<_ManagerBusMapContent> {
  final MapController _mapController = MapController();
  List<LatLng> _routePoints = [];
  List<LatLng> _liveRoutePoints = [];
  List<Map<String, dynamic>> _stopPoints = [];
  Map<String, dynamic>? _busStatus;

  String? _etaToNextStop;
  String? _distToNextStop;

  String? _etaToEndPoint;
  String? _distToEndPoint;

  String? _nextStopName;
  LatLng? _lastBusPos;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _busSub;
  int _selectedRouteIndex = 0;
  List<({List<LatLng> path, double durationSeconds, double distanceMeters})> _alternativeRoutes = [];
  bool _tripActive = false;
  double? _busLat;
  double? _busLng;

  @override
  void initState() {
    super.initState();
    _fetchRoutePoints();
    _listenToBus();
  }

  @override
  void didUpdateWidget(_ManagerBusMapContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busId != widget.busId) {
      _lastBusPos = null;
      _busStatus = null;
      _etaToNextStop = null;
      _distToNextStop = null;
      _etaToEndPoint = null;
      _distToEndPoint = null;
      _nextStopName = null;
      _fetchRoutePoints();
      _listenToBus();
    }
  }

  @override
  void dispose() {
    _busSub?.cancel();
    super.dispose();
  }

  void _listenToBus() {
    _busSub?.cancel();
    _busSub = context
        .read<FirestoreService>()
        .getBusStatus(widget.busId)
        .listen((snapshot) {
      if (!mounted) return;
      if (!snapshot.exists) return;

      final d = snapshot.data();
      if (d == null) return;

      final active = d['tripActive'] == true;
      final lat = (d['lat'] as num?)?.toDouble();
      final lng = (d['lng'] as num?)?.toDouble();
      final nStop = d['nextStop'] as String?;

      final nextStopDist = d['nextStopDistance'] as String?;
      final nextStopEta = d['nextStopETA'] as String?;
      final endPointDist = d['endPointDistance'] as String?;
      final endPointEta = d['endPointETA'] as String?;

      final routePathData = d['routePath'] as List<dynamic>?;
      List<LatLng> firebaseRoutePath = [];
      if (routePathData != null) {
        firebaseRoutePath = routePathData.map((pt) {
          final map = pt as Map<dynamic, dynamic>;
          return LatLng((map['lat'] as num).toDouble(), (map['lng'] as num).toDouble());
        }).toList();
      }

      // Parse alternative route options
      final routeOptionsData = d['routeOptions'] as List<dynamic>?;
      final selectedRouteIdx = d['selectedRouteIndex'] as int? ?? 0;

      final parsedOptions = <({List<LatLng> path, double durationSeconds, double distanceMeters})>[];
      if (routeOptionsData != null) {
        for (final opt in routeOptionsData) {
          final mapOpt = opt as Map<dynamic, dynamic>;
          final optPathList = mapOpt['path'] as List<dynamic>?;
          final optPath = <LatLng>[];
          if (optPathList != null) {
            for (final pt in optPathList) {
              final mapPt = pt as Map<dynamic, dynamic>;
              optPath.add(LatLng((mapPt['lat'] as num).toDouble(), (mapPt['lng'] as num).toDouble()));
            }
          }
          final durationSec = (mapOpt['durationSeconds'] as num?)?.toDouble() ?? 0.0;
          final distanceM = (mapOpt['distanceMeters'] as num?)?.toDouble() ?? 0.0;
          parsedOptions.add((path: optPath, durationSeconds: durationSec, distanceMeters: distanceM));
        }
      }

      setState(() {
        _busStatus = d;
        _tripActive = active;
        _nextStopName = nStop;
        _selectedRouteIndex = selectedRouteIdx;
        _alternativeRoutes = parsedOptions;
        _busLat = lat;
        _busLng = lng;

        if (firebaseRoutePath.isNotEmpty) {
          _liveRoutePoints = firebaseRoutePath;
        } else if (parsedOptions.isNotEmpty && selectedRouteIdx < parsedOptions.length) {
          _liveRoutePoints = parsedOptions[selectedRouteIdx].path;
        }

        if (nextStopDist != null) _distToNextStop = nextStopDist;
        if (nextStopEta != null) _etaToNextStop = nextStopEta;
        if (endPointDist != null) _distToEndPoint = endPointDist;
        if (endPointEta != null) _etaToEndPoint = endPointEta;
      });

      if (active && lat != null && lng != null) {
        final busPos = LatLng(lat, lng);
        // Fallback to client-side routing calculations ONLY if Firestore doesn't provide routePath/routeOptions
        if (firebaseRoutePath.isEmpty && parsedOptions.isEmpty) {
          if (_lastBusPos == null ||
              Geolocator.distanceBetween(_lastBusPos!.latitude,
                      _lastBusPos!.longitude, lat, lng) >
                  10) {
            _lastBusPos = busPos;
            _updateLiveRoute(busPos);
          }
        } else {
          _lastBusPos = busPos;
        }
      } else {
        _lastBusPos = null;
        if (mounted) {
          setState(() {
            _liveRoutePoints = [];
            _etaToNextStop = null;
            _distToNextStop = null;
            _etaToEndPoint = null;
            _distToEndPoint = null;
          });
        }
      }
    });
  }

  Future<void> _fetchRoutePoints() async {
    final points =
        await context.read<FirestoreService>().getRoutePoints(widget.busId);
    final coords = points.map((p) => LatLng(p['lat'], p['lng'])).toList();

    final fullRoute =
        await context.read<RoutingService>().getRoutePolyline(coords);

    if (mounted) {
      setState(() {
        _stopPoints = points;
        _routePoints = fullRoute;
        _liveRoutePoints = [];
      });
      if (fullRoute.isNotEmpty) {
        _mapController.move(fullRoute.first, 13.0);
      }
    }
  }

  void _updateLiveRoute(LatLng busPos) async {
    final points =
        await context.read<FirestoreService>().getRoutePoints(widget.busId);
    List<LatLng> remainingStops = [];

    for (var p in points) {
      final stopPos = LatLng(p['lat'], p['lng']);
      final dist = Geolocator.distanceBetween(busPos.latitude, busPos.longitude,
          stopPos.latitude, stopPos.longitude);
      if (dist > 50) {
        remainingStops.add(stopPos);
      }
    }

    if (remainingStops.isNotEmpty) {
      final routingPoints = <Map<String, dynamic>>[
        {'lat': busPos.latitude, 'lng': busPos.longitude},
      ];
      for (final stp in remainingStops) {
        routingPoints.add({'lat': stp.latitude, 'lng': stp.longitude});
      }

      final routing = context.read<RoutingService>();

      // Distance to exact next remaining point
      final nextStopRes = await routing.getRoute(
          busPos.latitude,
          busPos.longitude,
          remainingStops.first.latitude,
          remainingStops.first.longitude);

      try {
        final destRes = await routing.getFullRouteWithSnapped(routingPoints);
        if (mounted && destRes.path.isNotEmpty) {
          setState(() {
            _liveRoutePoints =
                destRes.path.map((p) => LatLng(p.lat, p.lng)).toList();

            // End point info
            final minsEnd = (destRes.durationSeconds / 60).ceil();
            final distEnd = destRes.distanceMeters;
            _etaToEndPoint = minsEnd > 60
                ? "${(minsEnd / 60).toStringAsFixed(1)} hrs"
                : "$minsEnd mins";
            _distToEndPoint = distEnd > 1000
                ? "${(distEnd / 1000).toStringAsFixed(1)} km"
                : "${distEnd.toStringAsFixed(0)} m";

            // Next stop info
            if (nextStopRes.durationSeconds > 0) {
              final minsNext = (nextStopRes.durationSeconds / 60).ceil();
              final distNext = nextStopRes.distanceMeters;
              _etaToNextStop = minsNext > 60
                  ? "${(minsNext / 60).toStringAsFixed(1)} hrs"
                  : "$minsNext mins";
              _distToNextStop = distNext > 1000
                  ? "${(distNext / 1000).toStringAsFixed(1)} km"
                  : "${distNext.toStringAsFixed(0)} m";
            }
          });
        }
      } catch (_) {}
    } else {
      // Arrived
      if (mounted) {
        setState(() {
          _liveRoutePoints = [];

          _etaToNextStop = null;
          _distToNextStop = "Arrived";
          _etaToEndPoint = null;
          _distToEndPoint = "Arrived";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: const LatLng(30.0444, 31.2357),
            initialZoom: 13.0,
            onMapReady: () {
              if (_routePoints.isNotEmpty) {
                _mapController.move(_routePoints.first, 13.0);
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.manager',
            ),
            PolylineLayer(
              polylines: [
                if (_routePoints.isNotEmpty && !_tripActive)
                  Polyline(
                    points: List<LatLng>.from(_routePoints),
                    color: Colors.black87,
                    strokeWidth: 5,
                  )
                else if (_routePoints.isNotEmpty)
                  Polyline(
                    points: List<LatLng>.from(_routePoints),
                    color: Colors.grey.withOpacity(0.3),
                    strokeWidth: 4,
                  ),
                if (_tripActive && _alternativeRoutes.isNotEmpty) ...[
                  // Draw alternative routes first (in gray)
                  for (int i = 0; i < _alternativeRoutes.length; i++)
                    if (i != _selectedRouteIndex)
                      Polyline(
                        points: _alternativeRoutes[i].path,
                        color: Colors.grey.withOpacity(0.6),
                        strokeWidth: 5,
                      ),
                  // Draw selected route last (in blue) on top
                  if (_selectedRouteIndex < _alternativeRoutes.length)
                    Polyline(
                      points: _alternativeRoutes[_selectedRouteIndex].path,
                      color: AppTheme.primaryBlue,
                      strokeWidth: 7,
                    ),
                ] else if (_tripActive && _liveRoutePoints.isNotEmpty)
                  Polyline(
                    points: List<LatLng>.from(_liveRoutePoints),
                    color: AppTheme.primaryBlue,
                    strokeWidth: 6,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                // Draw route stops
                for (var i = 0; i < _stopPoints.length; i++)
                  Marker(
                    point: LatLng(
                      (_stopPoints[i]['lat'] as num).toDouble(),
                      (_stopPoints[i]['lng'] as num).toDouble(),
                    ),
                    width: 28,
                    height: 28,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue.withOpacity(0.8),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4)
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),

                // Draw bus
                if (_tripActive &&
                    _busLat != null &&
                    _busLng != null)
                  Marker(
                    point: LatLng(_busLat!, _busLng!),
                    width: 60,
                    height: 60,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 8)
                        ],
                      ),
                      child: const Icon(Icons.directions_bus,
                          color: AppTheme.accentOrange, size: 30),
                    ),
                  ),
              ],
            ),
          ],
        ),
        if (!_tripActive)
          Positioned(
            left: 20,
            right: 20,
            top: 20,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 2,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  'Trip is not currently active.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textDark),
                ),
              ),
            ),
          ),
        if (_tripActive && _nextStopName != null)
          Positioned(
            bottom: 20,
            left: 16,
            right: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, 2))
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Bus Progress',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: AppTheme.textDark),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                            color: AppTheme.successGreen,
                            borderRadius: BorderRadius.circular(12)),
                        child: const Text('LIVE',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_nextStopName != null && _nextStopName != 'End') ...[
                    _buildInfoRow('Next Stop:', _nextStopName,
                        _distToNextStop, _etaToNextStop),
                    const Divider(height: 16),
                  ],
                  if (_stopPoints.isNotEmpty)
                    _buildInfoRow('End Point:', _stopPoints.last['name'],
                        _distToEndPoint, _etaToEndPoint),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoRow(
      String label, String? name, String? distance, String? eta) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 75,
            child: Text(label,
                style:
                    const TextStyle(fontSize: 13, color: AppTheme.textLight))),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name ?? '—',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue)),
              if (distance != null || eta != null)
                Text(
                  [if (distance != null) distance, if (eta != null) eta]
                      .join(' — '),
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.accentOrange,
                      fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
