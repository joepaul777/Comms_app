import 'package:firebase_core/firebase_core.dart';

/// The Firebase settings for Comms in a browser. (The Android app reads its own from
/// google-services.json.) These identify the project; they are not secrets, and the
/// database rules decide what anyone can do.
const webFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyB31RAJ_Gp-RWnBGXHwPbfAJFmNl1WRjuA',
  appId: '1:1063518731720:web:03b21e9ebc533b1a4894fd',
  messagingSenderId: '1063518731720',
  projectId: 'jp-comms',
  authDomain: 'jp-comms.firebaseapp.com',
  storageBucket: 'jp-comms.firebasestorage.app',
);
