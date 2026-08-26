import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'db/app_database.dart';
import 'pages/home_page.dart';
import 'services/font_service.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.open();
  await AppState.loadPrefs();
  await ReaderSettings.load();
  await FontService.init();
  await SystemChrome.setPreferredOrientations(
    [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
  );
  runApp(const HeiYuApp());
}

class HeiYuApp extends StatelessWidget {
  const HeiYuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        AppState.appThemeMode,
        AppState.accentKey,
      ]),
      builder: (context, _) {
        final mode = switch (AppState.appThemeMode.value) {
          AppThemeMode.system => ThemeMode.system,
          AppThemeMode.dark => ThemeMode.dark,
          AppThemeMode.light => ThemeMode.light,
        };
        return MaterialApp(
          title: '黑羽阅读',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildAppTheme(),
          themeMode: mode,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          home: const HomePage(),
        );
      },
    );
  }
}
