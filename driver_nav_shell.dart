import 'package:flutter/material.dart';
import 'driver_home_screen.dart';
import 'driver_profile_screen.dart';

class DriverNavShell extends StatefulWidget {
  const DriverNavShell({super.key});

  @override
  State<DriverNavShell> createState() => _DriverNavShellState();
}

class _DriverNavShellState extends State<DriverNavShell> {
  int _currentIndex = 0;

  void _onNavTap(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: _currentIndex,
      children: [
        DriverHomeScreen(currentNavIndex: _currentIndex, onNavTap: _onNavTap),
        DriverProfileScreen(currentNavIndex: _currentIndex, onNavTap: _onNavTap),
      ],
    );
  }
}
