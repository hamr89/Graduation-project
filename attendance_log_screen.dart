import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../app_theme.dart';
import '../../services/firestore_service.dart';

class AttendanceLogScreen extends StatefulWidget {
  const AttendanceLogScreen({super.key});

  @override
  State<AttendanceLogScreen> createState() => _AttendanceLogScreenState();
}

class _AttendanceLogScreenState extends State<AttendanceLogScreen> {
  int _months = 3;
  String _searchDay = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundWhite,
      appBar: AppBar(
        title: const Text('Attendance log'),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.textDark),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 20, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              hintText: 'Find Day',
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onChanged: (v) => setState(() => _searchDay = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<int>(
                  value: _months,
                  items: [1, 2, 3, 6].map((m) => DropdownMenuItem(
                    value: m,
                    child: Text('Last $m months'),
                  )).toList(),
                  onChanged: (v) => setState(() => _months = v ?? 3),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
              future: context.read<FirestoreService>().getAttendanceRecords(months: _months),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        snapshot.error.toString(),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('No attendance records yet'),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _tableHeader(),
                    ...docs.map((doc) {
                      final d = doc.data();
                      final date = (d['date'] as Timestamp?)?.toDate();
                      final status = d['status'] as String? ?? '---';
                      final boardTime = d['boardTime'] as String? ?? '---';
                      if (date == null) return const SizedBox.shrink();
                      final dateStr = DateFormat('MMM d, yyyy').format(date);
                      if (_searchDay.isNotEmpty &&
                          !dateStr.toLowerCase().contains(_searchDay.toLowerCase())) {
                        return const SizedBox.shrink();
                      }
                      return _tableRow(
                        date: dateStr,
                        status: status,
                        boardTime: boardTime,
                      );
                    }),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: const Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              'Date',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Status',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Board time',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textDark,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableRow({
    required String date,
    required String status,
    required String boardTime,
  }) {
    final isPresent = status.toLowerCase() == 'present';
    final isPending = status.toLowerCase() == 'pending';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: Text(
              status,
              style: TextStyle(
                fontSize: 13,
                color: isPresent
                    ? AppTheme.successGreen
                    : isPending
                        ? Colors.amber.shade800
                        : AppTheme.errorRed,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: Text(boardTime, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
