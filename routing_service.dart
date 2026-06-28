import 'dart:convert';

import 'package:http/http.dart' as http;

/// Fetches road-based driving routes from OSRM. Snaps points to roads.
class RoutingService {
  static const _baseUrl = 'https://router.project-osrm.org';
  static const _routePath = '/route/v1/driving';
  static const _nearestPath = '/nearest/v1/driving';

  /// Snaps a point to the nearest location on the road network.
  /// Returns original coords if OSRM fails.
  Future<({double lat, double lng})> snapToRoad(double lat, double lng) async {
    try {
      final coords = '$lng,$lat';
      final uri = Uri.parse('$_baseUrl$_nearestPath/$coords');
      final r = await http.get(uri, headers: {'User-Agent': 'UniBus/1.0'});
      if (r.statusCode != 200) return (lat: lat, lng: lng);
      final data = jsonDecode(r.body) as Map<String, dynamic>?;
      if (data == null) return (lat: lat, lng: lng);
      final waypoints = data['waypoints'] as List<dynamic>?;
      if (waypoints == null || waypoints.isEmpty) return (lat: lat, lng: lng);
      final loc = waypoints[0]['location'] as List<dynamic>?;
      if (loc == null || loc.length < 2) return (lat: lat, lng: lng);
      return (lat: (loc[1] as num).toDouble(), lng: (loc[0] as num).toDouble());
    } catch (_) {
      return (lat: lat, lng: lng);
    }
  }

  /// Returns road path between two points as list of [lat, lng], plus the estimated duration in seconds and distance in meters. Uses snapped coords.
  /// Returns empty list and 0 duration/distance on failure.
  Future<({List<({double lat, double lng})> path, double durationSeconds, double distanceMeters})> getRoute(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) async {
    try {
      final coords = '$lng1,$lat1;$lng2,$lat2';
      final uri = Uri.parse('$_baseUrl$_routePath/$coords').replace(
        queryParameters: {'overview': 'full', 'geometries': 'geojson'},
      );
      final emptyResult = (path: <({double lat, double lng})>[], durationSeconds: 0.0, distanceMeters: 0.0);
      final r = await http.get(uri, headers: {'User-Agent': 'UniBus/1.0'});
      if (r.statusCode != 200) return emptyResult;
      final data = jsonDecode(r.body) as Map<String, dynamic>?;
      if (data == null) return emptyResult;
      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return emptyResult;
      final route = routes[0] as Map<String, dynamic>?;
      if (route == null) return emptyResult;
      final geometry = route['geometry'] as Map<String, dynamic>?;
      if (geometry == null) return emptyResult;
      final coordsList = geometry['coordinates'] as List<dynamic>?;
      if (coordsList == null || coordsList.isEmpty) return emptyResult;
      
      final duration = (route['duration'] as num?)?.toDouble() ?? 0.0;
      final distance = (route['distance'] as num?)?.toDouble() ?? 0.0;
      final path = coordsList.map((c) {
        final arr = c as List<dynamic>;
        final lng = (arr[0] as num).toDouble();
        final lat = (arr[1] as num).toDouble();
        return (lat: lat, lng: lng);
      }).toList();
      return (path: path, durationSeconds: duration, distanceMeters: distance);
    } catch (_) {
      return (path: <({double lat, double lng})>[], durationSeconds: 0.0, distanceMeters: 0.0);
    }
  }

  /// Returns up to 3 alternative paths between two points. Uses snapped coords.
  /// If OSRM fails or there are no alternatives, returns a list containing the primary route if available.
  Future<List<({List<({double lat, double lng})> path, double durationSeconds, double distanceMeters})>> getRouteAlternatives(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) async {
    try {
      final coords = '$lng1,$lat1;$lng2,$lat2';
      final uri = Uri.parse('$_baseUrl$_routePath/$coords').replace(
        queryParameters: {
          'overview': 'full',
          'geometries': 'geojson',
          'alternatives': 'true',
        },
      );
      final r = await http.get(uri, headers: {'User-Agent': 'UniBus/1.0'});
      if (r.statusCode != 200) return [];
      final data = jsonDecode(r.body) as Map<String, dynamic>?;
      if (data == null) return [];
      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return [];

      final result = <({List<({double lat, double lng})> path, double durationSeconds, double distanceMeters})>[];
      for (final rObj in routes) {
        final route = rObj as Map<String, dynamic>?;
        if (route == null) continue;
        final geometry = route['geometry'] as Map<String, dynamic>?;
        if (geometry == null) continue;
        final coordsList = geometry['coordinates'] as List<dynamic>?;
        if (coordsList == null || coordsList.isEmpty) continue;

        final duration = (route['duration'] as num?)?.toDouble() ?? 0.0;
        final distance = (route['distance'] as num?)?.toDouble() ?? 0.0;
        final path = coordsList.map((c) {
          final arr = c as List<dynamic>;
          final lng = (arr[0] as num).toDouble();
          final lat = (arr[1] as num).toDouble();
          return (lat: lat, lng: lng);
        }).toList();
        result.add((path: path, durationSeconds: duration, distanceMeters: distance));
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// Snaps all points to roads. Returns list of (lat, lng).
  Future<List<({double lat, double lng})>> snapPointsToRoads(
    List<Map<String, dynamic>> points,
  ) async {
    final result = <({double lat, double lng})>[];
    for (final p in points) {
      final lat = (p['lat'] as num?)?.toDouble();
      final lng = (p['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      result.add(await snapToRoad(lat, lng));
    }
    return result;
  }

  /// Returns full road path, snapped stop points, total duration, and total distance in a single API call.
  Future<({List<({double lat, double lng})> path, List<({double lat, double lng})> snappedPoints, double durationSeconds, double distanceMeters})> getFullRouteWithSnapped(
    List<Map<String, dynamic>> points,
  ) async {
    if (points.length < 2) return (path: <({double lat, double lng})>[], snappedPoints: <({double lat, double lng})>[], durationSeconds: 0.0, distanceMeters: 0.0);
    
    try {
      final coordsString = points.map((p) => '${p['lng']},${p['lat']}').join(';');
      final uri = Uri.parse('$_baseUrl$_routePath/$coordsString').replace(
        queryParameters: {'overview': 'full', 'geometries': 'geojson'},
      );
      
      final r = await http.get(uri, headers: {'User-Agent': 'UniBus/1.0'});
      if (r.statusCode != 200) throw Exception('OSRM API failed');
      
      final data = jsonDecode(r.body) as Map<String, dynamic>?;
      if (data == null) throw Exception();
      
      final routes = data['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) throw Exception();
      
      final route = routes[0] as Map<String, dynamic>?;
      if (route == null) throw Exception();
      
      final geometry = route['geometry'] as Map<String, dynamic>?;
      if (geometry == null) throw Exception();
      
      final coordsList = geometry['coordinates'] as List<dynamic>?;
      if (coordsList == null || coordsList.isEmpty) throw Exception();
      
      final duration = (route['duration'] as num?)?.toDouble() ?? 0.0;
      final distance = (route['distance'] as num?)?.toDouble() ?? 0.0;
      final path = <({double lat, double lng})>[];
      for (final c in coordsList) {
        final arr = c as List<dynamic>;
        path.add((lat: (arr[1] as num).toDouble(), lng: (arr[0] as num).toDouble()));
      }
      
      final waypoints = data['waypoints'] as List<dynamic>?;
      final snappedPoints = <({double lat, double lng})>[];
      if (waypoints != null) {
        for (final wp in waypoints) {
          final loc = wp['location'] as List<dynamic>?;
          if (loc != null && loc.length >= 2) {
             snappedPoints.add((lat: (loc[1] as num).toDouble(), lng: (loc[0] as num).toDouble()));
          }
        }
      }
      
      if (snappedPoints.isEmpty) {
        final fallback = points.map((p) => (lat: (p['lat'] as num).toDouble(), lng: (p['lng'] as num).toDouble())).toList();
        snappedPoints.addAll(fallback);
      }
      
      return (path: path, snappedPoints: snappedPoints, durationSeconds: duration, distanceMeters: distance);
    } catch (_) {
      // Return empty path on failure so callers maintain their existing route instead of jumping to straight lines
      return (path: <({double lat, double lng})>[], snappedPoints: <({double lat, double lng})>[], durationSeconds: 0.0, distanceMeters: 0.0);
    }
  }

  /// Returns full road path (for backwards compatibility).
  Future<List<({double lat, double lng})>> getFullRoute(
    List<Map<String, dynamic>> points,
  ) async {
    final r = await getFullRouteWithSnapped(points);
    return r.path;
  }
}
