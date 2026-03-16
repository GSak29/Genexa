import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  final firestore = FirebaseFirestore.instance;
  final snapshot = await firestore.collection('products').limit(1).get();
  
  if (snapshot.docs.isNotEmpty) {
    print("Found product: ${snapshot.docs.first.id}");
    print("Data: ${snapshot.docs.first.data()}");
  } else {
    print("No products found.");
  }
}
