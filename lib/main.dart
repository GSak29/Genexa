// File: lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'screens/dashboard_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/wishlist_screen.dart';
import 'services/notification_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print("🔔 Background Notification: ${message.notification?.title}");
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  
  await NotificationService().init();
  runApp(const GenexApp());
}

class GenexApp extends StatefulWidget {
  const GenexApp({super.key});

  @override
  State<GenexApp> createState() => _GenexAppState();
}

class _GenexAppState extends State<GenexApp> {
  @override
  void initState() {
    super.initState();
    _setupFCM();
    _listenForAlerts();
  }

  void _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    // Request permissions
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      print('User granted permission');
      
      // Get token
      String? token = await messaging.getToken();
      print("📱 Device Token: $token");
      
      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print("🔔 Foreground Notification: ${message.notification?.title}");
        if (message.notification != null) {
          NotificationService().showNotification(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            title: message.notification!.title ?? 'Notification',
            body: message.notification!.body ?? '',
          );
        }
      });
    } else {
      print('User declined or has not accepted permission');
    }
  }

  void _listenForAlerts() {
    // Listen for new notifications
    final startupTime = DateTime.now();
    FirebaseFirestore.instance.collection('notifications').snapshots().listen((snapshot) {
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data() as Map<String, dynamic>;
          final isRead = data['read'] ?? false;
          
          if (!isRead) {
            // Check if this is truly a newly created notification (after app startup)
            // or if it's just the initial load of existing unread notifications
            bool isTrulyNew = false;
            if (data['timestamp'] != null) {
              final timestamp = (data['timestamp'] as Timestamp).toDate();
              // If it was created recently (e.g., after the app started listening)
              if (timestamp.isAfter(startupTime.subtract(const Duration(seconds: 5)))) {
                isTrulyNew = true;
              }
            } else {
               // Fallback if no timestamp is found
               isTrulyNew = true; 
            }

            if (isTrulyNew) {
              final title = data['title'] ?? 'New Alert';
              final message = data['message'] ?? '';
              NotificationService().showNotification(
                id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                title: title,
                body: message,
              );
            }
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Genex',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  
  static const List<Widget> _widgetOptions = <Widget>[
    DashboardScreen(),
    NotificationsScreen(),
    WishlistScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _widgetOptions.elementAt(_selectedIndex),
      bottomNavigationBar: BottomNavigationBar(
        items: <BottomNavigationBarItem>[
          const BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('notifications')
                  .where('read', isEqualTo: false)
                  .snapshots(),
              builder: (context, snapshot) {
                int unreadCount = 0;
                if (snapshot.hasData) {
                  unreadCount = snapshot.data!.docs.length;
                }
                return Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text(unreadCount.toString()),
                  child: const Icon(Icons.notifications),
                );
              },
            ),
            label: 'Alerts',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long),
            label: 'Wishlists',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.blue,
        onTap: _onItemTapped,
      ),
    );
  }
}
