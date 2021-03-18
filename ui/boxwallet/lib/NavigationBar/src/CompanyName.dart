import 'package:flutter/material.dart';

class CompanyName extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
        height: 70.0,
        child: Center(
            child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'B',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontSize: 16.0,
              ),
            ),
            Text(
              'oxWallet',
              style: TextStyle(
                fontWeight: FontWeight.w300,
                color: Colors.white,
                fontSize: 16.0,
              ),
            ),
          ],
        ) // Row
            ) // Centre
        ); // Container
  }
}
