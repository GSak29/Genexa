import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  final firestore = FirebaseFirestore.instance;
  final snapshot = await firestore.collection('products').limit(3).get();
  
  if (snapshot.docs.isNotEmpty) {
    for (var doc in snapshot.docs) {
      print("Found product ID: ${doc.id}");
      print("Data: ${doc.data()}");
    }
  } else {
    print("No products found.");
  }
}
