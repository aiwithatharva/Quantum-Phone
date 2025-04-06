// lib/main.dart
import 'package:flutter/material.dart';
import 'dialer_screen.dart'; // We will create this file next

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quantum Dialer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const DialerScreen(), // Set DialerScreen as the home screen
      debugShowCheckedModeBanner: false, // Optional: Removes the debug banner
    );
  }
}