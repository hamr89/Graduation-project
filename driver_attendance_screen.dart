import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../app_theme.dart';
import '../../services/firestore_service.dart';

class DriverAttendanceScreen extends StatelessWidget {
  const DriverAttendanceScreen({
    super.key,
    required this.busId,
    required this.currentNavIndex,
    required this.onNavTap,
  });

  final String busId;
  final int currentNavIndex;
  final ValueChanged<int> onNavTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundWhite,
      appBar: AppBar(
        title: const Text('Students on this bus'),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      // ── Live stream replaces FutureBuilder ──
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: context
            .read<FirestoreService>()
            .streamRouteStudentsAttendance(busId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final students = snapshot.data ?? [];
          if (students.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No students assigned to this bus yet. The Admin can add them.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textLight),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: students.length,
            itemBuilder: (context, index) {
              return _StudentAttendanceCard(student: students[index]);
            },
          );
        },
      ),
    );
  }
}

class _StudentAttendanceCard extends StatefulWidget {
  final Map<String, dynamic> student;

  const _StudentAttendanceCard({required this.student});

  @override
  State<_StudentAttendanceCard> createState() => _StudentAttendanceCardState();
}

class _StudentAttendanceCardState extends State<_StudentAttendanceCard> {
  bool _isLoading = false;

  Future<void> _markStudent(bool present) async {
    setState(() => _isLoading = true);
    try {
      final uid = widget.student['id'] as String;
      await context
          .read<FirestoreService>()
          .setDriverAttendanceForStudent(uid, present);
      // No local _markedStatus needed — the stream will update the card automatically
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.student['name']?.toString() ?? 'Student';
    final notAttending = widget.student['notAttendingTomorrow'] == true;

    // todayAttendance flag: 'attending' | 'absent' | 'present' | null
    final String? todayFlag = widget.student['todayAttendance'] as String?;
    final bool alreadyMarked =
        todayFlag == 'present' || todayFlag == 'absent';

    // ── Excused (opted out for tomorrow) ──
    if (notAttending) {
      return _buildCard(
        name: name,
        borderColor: Colors.grey,
        avatarColor: Colors.grey,
        avatarIcon: Icons.person_off,
        badge: _badge('Excused', Colors.grey),
        content: null,
      );
    }

    // ── Already marked by driver (live flag) ──
    if (alreadyMarked) {
      final isPresent = todayFlag == 'present';
      return _buildCard(
        name: name,
        borderColor: isPresent ? AppTheme.successGreen : AppTheme.errorRed,
        avatarColor:
            isPresent ? AppTheme.successGreen : AppTheme.errorRed,
        avatarIcon: isPresent ? Icons.check : Icons.close,
        badge: _badge(
          isPresent ? 'Present' : 'Absent',
          isPresent ? AppTheme.successGreen : AppTheme.errorRed,
        ),
        content: null,
      );
    }

    // ── Attending (set flag but not yet boarded) ──
    if (todayFlag == 'attending') {
      return _buildCard(
        name: name,
        borderColor: AppTheme.primaryBlue,
        avatarColor: AppTheme.primaryBlue,
        avatarIcon: Icons.directions_bus,
        badge: _badge('Attending', AppTheme.primaryBlue),
        content: _markButtons(),
      );
    }

    // ── Default: no flag yet ──
    return _buildCard(
      name: name,
      borderColor: null,
      avatarColor: AppTheme.primaryBlue.withOpacity(0.15),
      avatarIcon: Icons.person,
      badge: null,
      content: _markButtons(),
    );
  }

  Widget _buildCard({
    required String name,
    required Color? borderColor,
    required Color avatarColor,
    required IconData avatarIcon,
    required Widget? badge,
    required Widget? content,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: borderColor != null
          ? RoundedRectangleBorder(
              side: BorderSide(color: borderColor, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: avatarColor.withOpacity(
                      avatarColor.opacity < 0.5 ? 1 : 0.15),
                  child: Icon(avatarIcon,
                      color: avatarColor.opacity < 0.5
                          ? Colors.white
                          : avatarColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                if (badge != null) badge,
              ],
            ),
            if (content != null) ...[
              const SizedBox(height: 12),
              content,
            ],
          ],
        ),
      ),
    );
  }

  Widget _markButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _isLoading ? null : () => _markStudent(false),
            icon: const Icon(Icons.close, color: AppTheme.errorRed, size: 18),
            label: const Text('Absent',
                style: TextStyle(color: AppTheme.errorRed)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppTheme.errorRed),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : () => _markStudent(true),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Present'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.successGreen,
            ),
          ),
        ),
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Chip(
      label: Text(label),
      backgroundColor: color,
      labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
    );
  }
}
