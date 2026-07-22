# my_first_flutter_app

A new Flutter project.

## Safe Android device run

Do not use raw `flutter run` on a phone that contains important app data.
Flutter may automatically uninstall the existing app when an APK replacement
is rejected, which also deletes private app data.

Use the repository wrapper instead:

```powershell
.\safe_flutter_run.bat -FlutterVerbose
```

The wrapper builds first, performs a data-preserving APK replacement, and
stops without uninstalling if installation is rejected. After a successful
install it attaches Flutter, so `r`, `R`, and `q` remain available.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
