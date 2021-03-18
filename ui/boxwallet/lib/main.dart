import 'package:boxwallet/NavigationBar/NavigationBar.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(MaterialApp(home: MyApp()));
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Container(
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            child: Stack(
              children: [NavigationBar()],
            ) // Stack
            ) // Container
        ); // Scaffold
  }
}
