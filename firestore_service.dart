import 'dart:math' show asin, cos, sqrt;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;
  String? getUid() => _uid;

  // Attendance: Yes = Pending (driver accepts → Present, refuses → Absent), No = Absent
  Future<void> recordAttendance(bool joining, String? boardTime) async {
    if (_uid == null) return;
    final date = DateTime.now();
    final dateKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    await _firestore.collection('attendance').doc(_uid!).collection('records').doc(dateKey).set({
      'date': Timestamp.fromDate(date),
      'joining': joining,
      'status': joining ? 'Pending' : 'Absent',
      'boardTime': boardTime ?? '---',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Marks whether the student is attending or not attending tomorrow.
  Future<void> setNotAttendingTomorrow(bool notAttending) async {
    if (_uid == null) return;
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    final dateKey = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    await _firestore.collection('users').doc(_uid!).set({
      'notAttendingTomorrow': notAttending,
      'attendTomorrowDateKey': dateKey,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<QuerySnapshot<Map<String, dynamic>>> getAttendanceRecords({int months = 3}) async {
    if (_uid == null) throw StateError('User not signed in');
    return _firestore
        .collection('attendance')
        .doc(_uid!)
        .collection('records')
        .orderBy('date', descending: true)
        .limit(100)
        .get();
  }

  // Pickup points (may have lat, lng for nearest-route-point assignment)
  Future<List<Map<String, dynamic>>> getPickupPoints() async {
    final snap = await _firestore.collection('pickup_points').get();
    final list = snap.docs.map((d) => {'id': d.id, 'name': d.data()['name'] ?? d.id, ...d.data()}).toList();
    list.sort((a, b) => ((a['name'] ?? '') as String).compareTo((b['name'] ?? '') as String));
    return list;
  }

  Future<Map<String, dynamic>?> getPickupPoint(String pointId) async {
    final doc = await _firestore.collection('pickup_points').doc(pointId).get();
    if (!doc.exists) return null;
    return {'id': doc.id, ...doc.data()!};
  }

  Future<void> setUserPickupPoint(String pointId) async {
    if (_uid == null) return;
    await _firestore.collection('users').doc(_uid!).set(
      {'pickupPointId': pointId, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  // Buses and routes (2 buses, 5 points: start + 3 stops + end)
  Future<List<Map<String, dynamic>>> getBuses() async {
    // Ensure both default buses always exist in Firestore
    final defaults = _defaultBuses();
    for (final bus in defaults) {
      final doc = await _firestore.collection('buses').doc(bus['id'] as String).get();
      if (!doc.exists) {
        await _firestore.collection('buses').doc(bus['id'] as String).set({
          'name': bus['name'],
          'order': bus['order'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
    final snap = await _firestore.collection('buses').get();
    final list = snap.docs.map((d) => {'id': d.id, 'name': d.data()['name'] ?? d.id, ...d.data()}).toList();
    list.sort((a, b) => ((a['order'] as num?) ?? 0).compareTo((b['order'] as num?) ?? 0));
    return list;
  }

  List<Map<String, dynamic>> _defaultBuses() {
    return [
      {'id': 'bus_1', 'name': 'Mokattam', 'order': 1},
      {'id': 'bus_2', 'name': 'Nasr City', 'order': 2},
    ];
  }

  // Static route points (hardcoded – no admin config needed)
  static const List<Map<String, dynamic>> _routeA = [
    {'id': 'point_1', 'name': 'Makram Ebeid', 'lat': 30.0578, 'lng': 31.3345, 'order': 1},
    {'id': 'point_2', 'name': 'Abbas El Akkad', 'lat': 30.0615, 'lng': 31.3375, 'order': 2},
    {'id': 'point_3', 'name': 'Youssef Abbas', 'lat': 30.0638, 'lng': 31.3395, 'order': 3},
    {'id': 'point_4', 'name': 'Nady El Seka', 'lat': 30.0662, 'lng': 31.3418, 'order': 4},
    {'id': 'point_5', 'name': 'MTI University', 'lat': 29.9877, 'lng': 31.3653, 'order': 5},
  ];

  // Bus 2: same stops as Route A but reversed
  static const List<Map<String, dynamic>> _routeB = [
    {'id': 'point_1', 'name': 'MTI University', 'lat': 29.9877, 'lng': 31.3653, 'order': 1},
    {'id': 'point_2', 'name': 'Nady El Seka', 'lat': 30.0662, 'lng': 31.3418, 'order': 2},
    {'id': 'point_3', 'name': 'Youssef Abbas', 'lat': 30.0638, 'lng': 31.3395, 'order': 3},
    {'id': 'point_4', 'name': 'Abbas El Akkad', 'lat': 30.0615, 'lng': 31.3375, 'order': 4},
    {'id': 'point_5', 'name': 'Makram Ebeid', 'lat': 30.0578, 'lng': 31.3345, 'order': 5},
  ];

  Future<List<Map<String, dynamic>>> getRoutePoints(String busId) async {
    if (busId == 'bus_1') {
      return _routeA.map((p) => {...p, 'busId': busId}).toList();
    }
    if (busId == 'bus_2') {
      return _routeB.map((p) => {...p, 'busId': busId}).toList();
    }
    return _defaultRoutePoints(busId);
  }

  List<Map<String, dynamic>> _defaultRoutePoints(String busId) {
    const names = ['Start point', 'Stop 1', 'Stop 2', 'Stop 3', 'End point'];
    return List.generate(5, (i) => {
      'id': 'point_${i + 1}',
      'busId': busId,
      'name': names[i],
      'lat': 30.04 + i * 0.002,
      'lng': 31.23 + i * 0.002,
      'order': i + 1,
    });
  }

  // Admin: save routes (buses) and pickup points
  Future<void> saveBus(String busId, String name, int order) async {
    await _firestore.collection('buses').doc(busId).set({
      'name': name,
      'order': order,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// [points] must have 5 items: start, stop1, stop2, stop3, end. Doc ids: point_1..point_5.
  Future<void> saveRoutePoints(String busId, List<Map<String, dynamic>> points) async {
    final batch = _firestore.batch();
    for (var i = 0; i < points.length && i < 5; i++) {
      final p = points[i];
      final id = 'point_${i + 1}';
      final ref = _firestore.collection('buses').doc(busId).collection('route_points').doc(id);
      batch.set(ref, {
        'name': p['name'] as String? ?? _defaultRoutePointName(i),
        'lat': (p['lat'] as num?)?.toDouble() ?? 0.0,
        'lng': (p['lng'] as num?)?.toDouble() ?? 0.0,
        'order': (p['order'] as int?) ?? (i + 1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  static String _defaultRoutePointName(int i) {
    const names = ['Start point', 'Stop 1', 'Stop 2', 'Stop 3', 'End point'];
    return names[i < names.length ? i : 0];
  }

  static double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const p = 0.017453292519943295;
    final a = 0.5 - cos((lat2 - lat1) * p) / 2 + cos(lat1 * p) * cos(lat2 * p) * (1 - cos((lng2 - lng1) * p)) / 2;
    return 12742 * asin(sqrt(a));
  }

  /// Save bus + manually chosen point (when student picks from the 5 stops).
  Future<void> setStudentBusAndPoint(String busId, String pointId, String pointName) async {
    if (_uid == null) return;
    String busName = busId;
    for (final b in await getBuses()) {
      if (b['id'] == busId) {
        busName = b['name'] as String? ?? busId;
        break;
      }
    }
    await _firestore.collection('users').doc(_uid!).set({
      'selectedBusId': busId,
      'selectedBusName': busName,
      'assignedRoutePointId': pointId,
      'assignedRoutePointName': pointName,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setStudentBusAndNearestPoint(String busId, double pickupLat, double pickupLng) async {
    if (_uid == null) return;
    final points = await getRoutePoints(busId);
    if (points.isEmpty) return;
    Map<String, dynamic>? nearest;
    double minDist = double.infinity;
    for (final p in points) {
      final lat = (p['lat'] as num?)?.toDouble();
      final lng = (p['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final d = _distanceKm(pickupLat, pickupLng, lat, lng);
      if (d < minDist) {
        minDist = d;
        nearest = p;
      }
    }
    if (nearest == null) return;
    String busName = busId;
    for (final b in await getBuses()) {
      if (b['id'] == busId) {
        busName = b['name'] as String? ?? busId;
        break;
      }
    }
    await _firestore.collection('users').doc(_uid!).set({
      'selectedBusId': busId,
      'selectedBusName': busName,
      'assignedRoutePointId': nearest['id'],
      'assignedRoutePointName': nearest['name'],
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Lets the student manually change their assigned pickup point on their selected route.
  Future<void> setStudentAssignedPoint(String pointId, String pointName) async {
    if (_uid == null) return;
    await _firestore.collection('users').doc(_uid!).set({
      'assignedRoutePointId': pointId,
      'assignedRoutePointName': pointName,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>?> getUserBusSelection() async {
    if (_uid == null) return null;
    final doc = await _firestore.collection('users').doc(_uid!).get();
    final d = doc.data();
    if (d == null) return null;
    return {
      'selectedBusId': d['selectedBusId'],
      'selectedBusName': d['selectedBusName'],
      'assignedRoutePointId': d['assignedRoutePointId'],
      'assignedRoutePointName': d['assignedRoutePointName'],
    };
  }

  // Driver assignment (admin assigns driver to route)
  static const _busAssignments = 'bus_assignments';

  Future<void> setDriverAssignment(String busId, String driverEmail) async {
    await _firestore.collection(_busAssignments).doc(busId).set({
      'driverEmail': driverEmail.trim().toLowerCase(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<String?> getAssignedDriverEmail(String busId) async {
    final doc = await _firestore.collection(_busAssignments).doc(busId).get();
    return doc.data()?['driverEmail'] as String?;
  }

  /// Returns busId for the driver with this email, or null.
  Future<String?> getAssignedBusForDriver(String driverEmail) async {
    final email = driverEmail.trim().toLowerCase();
    final snap = await _firestore.collection(_busAssignments).get();
    for (final doc in snap.docs) {
      if ((doc.data()['driverEmail'] as String?)?.toLowerCase() == email) {
        return doc.id;
      }
    }
    return null;
  }

  // Admin updating a user's assigned bus
  Future<void> adminUpdateUserBus(String targetUid, String busId, String busName, String userRole, String userEmail) async {
    // 1. Update the user collection
    await _firestore.collection('users').doc(targetUid).set({
      'selectedBusId': busId,
      'selectedBusName': busName,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // 2. If it's a driver, we MUST re-assign them in the _busAssignments collection
    if (userRole == 'driver') {
      // First, remove them from any old bus assignments
      final snap = await _firestore.collection(_busAssignments).get();
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        if ((doc.data()['driverEmail'] as String?)?.toLowerCase() == userEmail.toLowerCase()) {
          batch.delete(doc.reference);
        }
      }
      await batch.commit();

      // Second, assign them to the new bus
      await setDriverAssignment(busId, userEmail);
    }
  }

  // Reports
  Future<void> reportProblem(String message) async {
    if (_uid == null) return;
    
    // Fetch the user's name and role first
    String userName = 'Unknown Student';
    String role = 'student';
    try {
      final userDoc = await _firestore.collection('users').doc(_uid!).get();
      if (userDoc.exists) {
        final d = userDoc.data()!;
        userName = d['name'] as String? ?? d['displayName'] as String? ?? d['email'] as String? ?? 'Unknown Student';
        role = d['role'] as String? ?? 'student';
      }
    } catch (_) {}

    await _firestore.collection('reports').add({
      'userId': _uid,
      'userName': userName,
      'role': role,
      'message': message,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Bus tracking per bus (bus_status/{busId})
  Stream<DocumentSnapshot<Map<String, dynamic>>> getBusStatus(String busId) {
    return _firestore.collection('bus_status').doc(busId).snapshots();
  }

  Future<Map<String, dynamic>?> getBusStatusOnce(String busId) async {
    final doc = await _firestore.collection('bus_status').doc(busId).get();
    if (!doc.exists) return null;
    return doc.data();
  }

  // Driver: trip and live location for a specific bus
  Future<void> updateBusLocation(
    String busId,
    double lat,
    double lng, {
    String? nextStop,
    String? arrivalTime,
    List<String>? pointArrivalTimes,
    List<String>? pointNames,
    List<Map<String, double>>? routePath,
    String? nextStopDistance,
    String? nextStopETA,
    String? endPointDistance,
    String? endPointETA,
    List<Map<String, dynamic>>? routeOptions,
    int? selectedRouteIndex,
  }) async {
    final data = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'updated': FieldValue.serverTimestamp(),
      'tripActive': true,
    };
    if (nextStop != null) data['nextStop'] = nextStop;
    if (arrivalTime != null) data['arrivalTime'] = arrivalTime;
    if (pointArrivalTimes != null) data['pointArrivalTimes'] = pointArrivalTimes;
    if (pointNames != null) data['pointNames'] = pointNames;
    if (routePath != null) data['routePath'] = routePath;
    if (nextStopDistance != null) data['nextStopDistance'] = nextStopDistance;
    if (nextStopETA != null) data['nextStopETA'] = nextStopETA;
    if (endPointDistance != null) data['endPointDistance'] = endPointDistance;
    if (endPointETA != null) data['endPointETA'] = endPointETA;
    if (routeOptions != null) data['routeOptions'] = routeOptions;
    if (selectedRouteIndex != null) data['selectedRouteIndex'] = selectedRouteIndex;
    await _firestore.collection('bus_status').doc(busId).set(data, SetOptions(merge: true));
  }

  static const int defaultMinutesToNextStop = 3;
  static const int estimatedTripDurationMinutes = 15;

  Future<void> startTrip(String busId, {int? minutesToNextStop, int? tripDurationMinutes}) async {
    final now = DateTime.now();
    final toNextStop = minutesToNextStop ?? defaultMinutesToNextStop;
    final duration = tripDurationMinutes ?? estimatedTripDurationMinutes;
    final estimatedArrival = now.add(Duration(minutes: duration));
    await _firestore.collection('bus_status').doc(busId).set({
      'tripActive': true,
      'nextStop': 'Next stop in $toNextStop minutes',
      'arrivalTime': _formatTime(estimatedArrival),
      'estimatedArrivalAt': Timestamp.fromDate(estimatedArrival),
      'startedAt': FieldValue.serverTimestamp(),
      'updated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> endTrip(String busId) async {
    await _firestore.collection('bus_status').doc(busId).set({
      'tripActive': false,
      'updated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ── Attendance flag (written to users/{uid} for fast real-time reads) ──

  static String _todayKey() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Write today's attendance status flag directly onto the user document.
  /// [status] must be one of: 'attending', 'absent', 'present'.
  Future<void> setTodayAttendanceFlag(String status) async {
    if (_uid == null) return;
    await _firestore.collection('users').doc(_uid!).set({
      'todayAttendance': status,
      'todayDateKey': _todayKey(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Returns a real-time stream of the student's own today-attendance status.
  /// Emits one of: 'attending', 'absent', 'present', or null if not set today.
  Stream<String?> getTodayAttendanceStream() {
    if (_uid == null) return const Stream.empty();
    final today = _todayKey();
    return _firestore
        .collection('users')
        .doc(_uid!)
        .snapshots()
        .map((snap) {
      if (!snap.exists) return null;
      final d = snap.data()!;
      if (d['todayDateKey'] != today) return null; // stale flag from yesterday
      return d['todayAttendance'] as String?;
    });
  }

  /// Driver: students who selected this bus — live stream with attendance flags.
  Stream<List<Map<String, dynamic>>> streamRouteStudentsAttendance(String busId) {
    final today = _todayKey();
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final tomorrowKey = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';

    return _firestore
        .collection('users')
        .where('selectedBusId', isEqualTo: busId)
        .snapshots()
        .map((snap) {
      final students = <Map<String, dynamic>>[];
      for (final doc in snap.docs) {
        final d = doc.data();
        final uid = doc.id;
        // Skip drivers
        if ((d['role'] as String?) == 'driver') continue;
        final notAttendingTomorrow =
            d['notAttendingTomorrow'] == true && d['attendTomorrowDateKey'] == tomorrowKey;
        final name = d['name'] as String? ??
            d['displayName'] as String? ??
            d['email'] as String? ??
            'Student';
        // Today's attendance flag
        final String? todayStatus =
            (d['todayDateKey'] == today) ? d['todayAttendance'] as String? : null;
        students.add({
          'id': uid,
          'userId': uid,
          'name': name,
          'notAttendingTomorrow': notAttendingTomorrow,
          'todayAttendance': todayStatus, // 'attending'|'absent'|'present'|null
        });
      }
      students.sort(
          (a, b) => ((a['name'] ?? '') as String).compareTo((b['name'] ?? '') as String));
      return students;
    });
  }

  // Driver: students who selected this bus along with their opt-out status (legacy one-shot)
  Future<List<Map<String, dynamic>>> getRouteStudentsForAttendance(String busId) async {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowKey = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    
    final usersSnap = await _firestore.collection('users').where('selectedBusId', isEqualTo: busId).get();
    final students = <Map<String, dynamic>>[];
    for (final doc in usersSnap.docs) {
      final d = doc.data();
      final uid = doc.id;
      final notAttendingTomorrow = d['notAttendingTomorrow'] == true && d['attendTomorrowDateKey'] == tomorrowKey;
      final name = d['name'] as String? ?? d['displayName'] as String? ?? d['email'] as String? ?? 'Student';
      students.add({
        'id': uid,
        'userId': uid,
        'name': name,
        'notAttendingTomorrow': notAttendingTomorrow,
      });
    }
    students.sort((a, b) => ((a['name'] ?? '') as String).compareTo((b['name'] ?? '') as String));
    return students;
  }

  Future<void> setDriverAttendanceForStudent(String studentId, bool present) async {
    final date = DateTime.now();
    final dateKey = _todayKey();
    final status = present ? 'present' : 'absent';
    // Write to attendance history sub-collection
    await _firestore
        .collection('attendance')
        .doc(studentId)
        .collection('records')
        .doc(dateKey)
        .set({
      'date': Timestamp.fromDate(date),
      'joining': present,
      'status': present ? 'Present' : 'Absent',
      'boardTime': present ? _formatTime(date) : '---',
      'markedByDriver': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // Also update the fast-read flag on the user document
    await _firestore.collection('users').doc(studentId).set({
      'todayAttendance': status,
      'todayDateKey': dateKey,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static String _formatTime(DateTime d) {
    final h = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final am = d.hour < 12;
    return '${h.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${am ? 'AM' : 'PM'}';
  }
}

