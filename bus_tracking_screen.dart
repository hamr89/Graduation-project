import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../app_theme.dart';
import '../../services/firestore_service.dart';
import '../../services/location_service.dart';
import '../../services/routing_service.dart';
import '../../widgets/uni_bus_header.dart';
import '../../widgets/bottom_nav_bar.dart';
import 'select_bus_screen.dart';

const LatLng _kMapCenterWhenNoBus = LatLng(30.0444, 31.2357);

class BusTrackingScreen extends StatelessWidget {
  const BusTrackingScreen({
    super.key,
    required this.currentNavIndex,
    required this.onNavTap,
  });

  final int currentNavIndex;
  final ValueChanged<int> onNavTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundWhite,
      body: SafeArea(
        child: FutureBuilder<Map<String, dynamic>?>(
          future: context.read<FirestoreService>().getUserBusSelection(),
          builder: (context, selectionSnapshot) {
            final selection = selectionSnapshot.data;
            final busId = selection?['selectedBusId'] as String?;
            final assignedStop = selection?['assignedRoutePointName'] as String?;
            if (busId == null || busId.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const UniBusHeader(),
                  const SizedBox(height: 24),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Select your bus to see its location and your assigned stop.',
                      style: TextStyle(color: AppTheme.textLight, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ElevatedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SelectBusScreen()),
                      ).then((_) {}),
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: const Text('Select your bus'),
                    ),
                  ),
                  const Spacer(),
                  UniBusBottomNav(currentIndex: currentNavIndex, onTap: onNavTap),
                ],
              );
            }
            return _BusMapContent(
              busId: busId,
              assignedStopName: assignedStop,
              currentNavIndex: currentNavIndex,
              onNavTap: onNavTap,
            );
          },
        ),
      ),
    );
  }
}

class _BusMapContent extends StatefulWidget {
  const _BusMapContent({
    required this.busId,
    required this.assignedStopName,
    required this.currentNavIndex,
    required this.onNavTap,
  });

  final String busId;
  final String? assignedStopName;
  final int currentNavIndex;
  final ValueChanged<int> onNavTap;

  @override
  State<_BusMapContent> createState() => _BusMapContentState();
}

class _BusMapContentState extends State<_BusMapContent> {
  Position? _userPosition;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _busSub;

  List<Map<String, dynamic>> _routePoints = [];
  List<LatLng> _liveRoutePath = [];
  List<LatLng> _staticRoutePath = [];
  int _selectedRouteIndex = 0;
  List<({List<LatLng> path, double durationSeconds, double distanceMeters})> _alternativeRoutes = [];
  
  bool _tripActive = false;
  double? _busLat;
  double? _busLng;
  String? _nextStop;
  
  double _lastCalculatedBusLat = 0;
  double _lastCalculatedBusLng = 0;
  
  String? _etaToStudent;
  String? _distToStudent;
  
  String? _etaToNextStop;
  String? _distToNextStop;
  
  String? _etaToEndPoint;
  String? _distToEndPoint;

  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    _fetchRoutePoints();
    _listenToBus();
  }

  void _listenToBus() {
    final firestore = context.read<FirestoreService>();
    _busSub = firestore.getBusStatus(widget.busId).listen((snapshot) {
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
        _tripActive = active;
        _busLat = lat;
        _busLng = lng;
        _nextStop = nStop;
        _selectedRouteIndex = selectedRouteIdx;
        _alternativeRoutes = parsedOptions;
        
        if (firebaseRoutePath.isNotEmpty) {
          _liveRoutePath = firebaseRoutePath;
        } else if (parsedOptions.isNotEmpty && selectedRouteIdx < parsedOptions.length) {
          _liveRoutePath = parsedOptions[selectedRouteIdx].path;
        }
        
        if (nextStopDist != null) _distToNextStop = nextStopDist;
        if (nextStopEta != null) _etaToNextStop = nextStopEta;
        if (endPointDist != null) _distToEndPoint = endPointDist;
        if (endPointEta != null) _etaToEndPoint = endPointEta;
      });
      
      if (active && lat != null && lng != null) {
        _updateStudentETA(lat, lng);
        
        // Fallback to client-side routing calculations ONLY if Firestore doesn't provide routePath/routeOptions
        if (firebaseRoutePath.isEmpty && parsedOptions.isEmpty) {
          _updateLiveETAAndRoute(lat, lng, nStop);
        }
      }
    });
  }

  Future<void> _updateStudentETA(double busLat, double busLng) async {
    if (_userPosition == null) return;
    
    // Only recalculate if the bus has moved significantly to avoid rate limits/spamming OSRM
    final distMove = Geolocator.distanceBetween(busLat, busLng, _lastCalculatedBusLat, _lastCalculatedBusLng);
    if (distMove < 100 && _etaToStudent != null) return;
    
    _lastCalculatedBusLat = busLat;
    _lastCalculatedBusLng = busLng;

    final routing = context.read<RoutingService>();
    final routeRes = await routing.getRoute(busLat, busLng, _userPosition!.latitude, _userPosition!.longitude);
    if (mounted && routeRes.durationSeconds > 0) {
      final mins = (routeRes.durationSeconds / 60).ceil();
      final distToMe = routeRes.distanceMeters;
      setState(() {
        _etaToStudent = mins > 60 ? "${(mins / 60).toStringAsFixed(1)} hrs" : "$mins mins";
        _distToStudent = distToMe > 1000 ? "${(distToMe / 1000).toStringAsFixed(1)} km" : "${distToMe.toStringAsFixed(0)} m";
      });
    }
  }

  Future<void> _fetchRoutePoints() async {
    final firestore = context.read<FirestoreService>();
    final routing = context.read<RoutingService>();
    final points = await firestore.getRoutePoints(widget.busId);
    if (!mounted) return;
    setState(() => _routePoints = points);

    if (points.isNotEmpty) {
      final routingPoints = points.map((p) => {
        'lat': (p['lat'] as num).toDouble(),
        'lng': (p['lng'] as num).toDouble(),
      }).toList();
      try {
        final res = await routing.getFullRouteWithSnapped(routingPoints);
        if (mounted && res.path.isNotEmpty) {
          setState(() {
            _staticRoutePath = res.path.map((rp) => LatLng(rp.lat, rp.lng)).toList();
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _startLocationUpdates() async {
    final loc = context.read<LocationService>();
    final ok = await loc.requestPermission();
    if (!ok) return;
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((p) {
      if (mounted) setState(() => _userPosition = p);
    });
    final pos = await loc.getCurrentPosition();
    if (mounted) setState(() => _userPosition = pos);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _busSub?.cancel();
    super.dispose();
  }

  String _distanceText(double busLat, double busLng) {
    if (_userPosition == null) return "Waiting for your location...";
    final d = Geolocator.distanceBetween(busLat, busLng, _userPosition!.latitude, _userPosition!.longitude);
    if (d > 1000) {
      return "${(d/1000).toStringAsFixed(1)} km away from you";
    }
    return "${d.toStringAsFixed(0)} meters away from you";
  }

  Future<void> _updateLiveETAAndRoute(double busLat, double busLng, String? nextStopName) async {
    // Only recalculate ETA if the bus has moved significantly (e.g., > 100 meters) to save API calls
    final distMove = Geolocator.distanceBetween(busLat, busLng, _lastCalculatedBusLat, _lastCalculatedBusLng);
    if (distMove < 100 && (_etaToStudent != null || _userPosition == null)) return;
    
    _lastCalculatedBusLat = busLat;
    _lastCalculatedBusLng = busLng;

    final routing = context.read<RoutingService>();
    
    // 1. Calculate Route from bus to student
    if (_userPosition != null) {
      final routeRes = await routing.getRoute(busLat, busLng, _userPosition!.latitude, _userPosition!.longitude);
      if (mounted && routeRes.durationSeconds > 0) {
        final mins = (routeRes.durationSeconds / 60).ceil();
        final distToMe = routeRes.distanceMeters;
        setState(() {
          _etaToStudent = mins > 60 ? "${(mins/60).toStringAsFixed(1)} hrs" : "$mins mins";
          _distToStudent = distToMe > 1000 ? "${(distToMe/1000).toStringAsFixed(1)} km" : "${distToMe.toStringAsFixed(0)} m";
        });
      }
    }
    
    // 2. Calculate dynamic live route from bus to destination
    if (_routePoints.isEmpty) return;
    
    int nextIndex = _routePoints.indexWhere((p) => p['name'] == nextStopName);
    if (nextStopName == 'End') {
      nextIndex = _routePoints.length;
    } else if (nextIndex == -1) {
      nextIndex = 0; // fallback
    }

    final routingPoints = <Map<String, dynamic>>[
      {'lat': busLat, 'lng': busLng},
    ];
    for (var i = nextIndex; i < _routePoints.length; i++) {
        routingPoints.add({
            'lat': (_routePoints[i]['lat'] as num).toDouble(),
            'lng': (_routePoints[i]['lng'] as num).toDouble(),
        });
    }
    
    if (routingPoints.length > 1) {
      // Find distance to next point specifically (which is routingPoints[1])
      final nextStopMapPointLat = routingPoints[1]['lat'] as double;
      final nextStopMapPointLng = routingPoints[1]['lng'] as double;
      final nextStopRes = await routing.getRoute(busLat, busLng, nextStopMapPointLat, nextStopMapPointLng);
      
      try {
        final destRes = await routing.getFullRouteWithSnapped(routingPoints);
        if (mounted && destRes.path.isNotEmpty) {
          setState(() {
            _liveRoutePath = destRes.path.map((p) => LatLng(p.lat, p.lng)).toList();
            
            // End point info
            final minsEnd = (destRes.durationSeconds / 60).ceil();
            final distEnd = destRes.distanceMeters;
            _etaToEndPoint = minsEnd > 60 ? "${(minsEnd/60).toStringAsFixed(1)} hrs" : "$minsEnd mins";
            _distToEndPoint = distEnd > 1000 ? "${(distEnd/1000).toStringAsFixed(1)} km" : "${distEnd.toStringAsFixed(0)} m";
            
            // Next stop info
            if (nextStopRes.durationSeconds > 0) {
              final minsNext = (nextStopRes.durationSeconds / 60).ceil();
              final distNext = nextStopRes.distanceMeters;
              _etaToNextStop = minsNext > 60 ? "${(minsNext/60).toStringAsFixed(1)} hrs" : "$minsNext mins";
              _distToNextStop = distNext > 1000 ? "${(distNext/1000).toStringAsFixed(1)} km" : "${distNext.toStringAsFixed(0)} m";
            }
          });
        }
      } catch (_) {}
    } else {
      // Bus is at the end or has no waypoints left
      setState(() {
        _etaToNextStop = null;
        _distToNextStop = "Arrived";
        _etaToEndPoint = null;
        _distToEndPoint = "Arrived";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const UniBusHeader(),
        if (widget.assignedStopName != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text(
              'Your stop: ${widget.assignedStopName}',
              style: const TextStyle(fontSize: 13, color: AppTheme.textDark, fontWeight: FontWeight.bold),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: Builder(
            builder: (context) {
              final hasBusLocation = _busLat != null && _busLng != null;
              final busPosition = hasBusLocation ? LatLng(_busLat!, _busLng!) : null;
              
              LatLng cameraTarget = _kMapCenterWhenNoBus;
              if (busPosition != null) {
                cameraTarget = busPosition;
              } else if (_routePoints.isNotEmpty) {
                cameraTarget = LatLng((_routePoints.first['lat'] as num).toDouble(), (_routePoints.first['lng'] as num).toDouble());
              }

              final routeMarkers = <Marker>[];
              
              // 1. Draw All Stops
              for (var i = 0; i < _routePoints.length; i++) {
                final pt = _routePoints[i];
                final pLat = (pt['lat'] as num).toDouble();
                final pLng = (pt['lng'] as num).toDouble();
                final isAssigned = pt['name'] == widget.assignedStopName;
                
                // If the bus is active, maybe gray out stops that have been passed?
                // We compare against `_nextStop`.
                int nextIndex = _routePoints.indexWhere((p) => p['name'] == _nextStop);
                if (nextIndex == -1) nextIndex = 0;
                
                final isPassed = _tripActive && hasBusLocation && i < nextIndex;
                
                routeMarkers.add(
                  Marker(
                    point: LatLng(pLat, pLng),
                    width: isAssigned ? 36 : 24,
                    height: isAssigned ? 36 : 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isPassed 
                            ? Colors.grey 
                            : (isAssigned ? AppTheme.errorRed : AppTheme.primaryBlue.withOpacity(0.8)),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(color: Colors.white, fontSize: isAssigned ? 14 : 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                );
              }

              // 2. Draw Bus
              if (busPosition != null) {
                routeMarkers.add(
                  Marker(
                    point: busPosition,
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.directions_bus, color: AppTheme.accentOrange, size: 50),
                  ),
                );
              }
              if (_userPosition != null) {
                routeMarkers.add(
                  Marker(
                    point: LatLng(_userPosition!.latitude, _userPosition!.longitude),
                    width: 24,
                    height: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                      ),
                      width: 24,
                      height: 24,
                    ),
                  ),
                );
              }

              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: double.infinity,
                      height: double.infinity,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: cameraTarget,
                          initialZoom: 14,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.untitled',
                          ),
                          if (_staticRoutePath.isNotEmpty && !_tripActive)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _staticRoutePath,
                                  color: Colors.black87, // 'black route' as requested
                                  strokeWidth: 5,
                                ),
                              ],
                            ),
                          if (_tripActive && _alternativeRoutes.isNotEmpty)
                            PolylineLayer(
                              polylines: [
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
                              ],
                            )
                          else if (_tripActive && _liveRoutePath.isNotEmpty)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _liveRoutePath,
                                  color: AppTheme.primaryBlue,
                                  strokeWidth: 6,
                                ),
                              ],
                            ),
                          MarkerLayer(markers: routeMarkers),
                        ],
                      ),
                    ),
                  ),
                  if (!_tripActive || !hasBusLocation)
                    Positioned(
                      left: 20,
                      right: 20,
                      top: 20,
                      child: Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 2,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Text(
                            _tripActive
                                ? 'Waiting for driver GPS location…'
                                : 'No active trip. Showing scheduled route.',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textDark,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 16,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, -2)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Bus Progress',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textDark),
                          ),
                          const SizedBox(height: 12),
                          if (_nextStop != null && _nextStop != 'End') ...[
                            _buildInfoRow('Next Stop:', _nextStop, _distToNextStop, _etaToNextStop),
                            const Divider(height: 16),
                          ],
                          if (widget.assignedStopName != null) ...[
                            _buildInfoRow('Your Stop:', widget.assignedStopName, _distToStudent, _etaToStudent),
                            const Divider(height: 16),
                          ],
                          if (_routePoints.isNotEmpty)
                            _buildInfoRow('End Point:', _routePoints.last['name'], _distToEndPoint, _etaToEndPoint),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        UniBusBottomNav(currentIndex: widget.currentNavIndex, onTap: widget.onNavTap),
      ],
    );
  }

  Widget _buildInfoRow(String label, String? name, String? distance, String? eta) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 75, child: Text(label, style: const TextStyle(fontSize: 13, color: AppTheme.textLight))),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name ?? '—', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.primaryBlue)),
              if (distance != null || eta != null)
                Text(
                  [if (distance != null) distance, if (eta != null) eta].join(' — '),
                  style: const TextStyle(fontSize: 13, color: AppTheme.accentOrange, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
