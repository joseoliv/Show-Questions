/*
void greet(int age, {required String name, String ? address, String phone = 'N/A'}) {
  print('Hello, $name! You are $age years old.');
}

void m() {
  greet(25, name: 'Alice', );
  greet( name: 'Alice',  address: null, 25, phone: null );
  greet( 25, 'Alice', phone: '0');
  greet( age: 25, name: 'Alice');
  greet( name: 'Alice', age: 25);
  greet(25, name: 'Alice', address: null, phone: null);

}

*/

// statefull widget named MyTest
import 'package:flutter/material.dart';

class MyTest extends StatefulWidget {
  const MyTest({super.key});

  @override
  MyTestState createState() => MyTestState();
}

class MyTestState extends State<MyTest> {
  @override
  Widget build(BuildContext context) {
    return Container(
      
      child: const Text('MyTest'),
    );
  }
}
