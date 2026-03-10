import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Build-time version string (from `--dart-define`).
///
/// CI passes it like:
/// `--dart-define=APP_VERSION=1.2.3`
///
/// If not provided, shows `dev`.
const String kBuildVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// ---------------------------
/// Settings (theme/accent)
/// ---------------------------

enum AppThemeMode { system, light, dark }

class AppSettings {
  AppSettings({
    required this.themeMode,
    required this.accentColor,
  });

  final AppThemeMode themeMode;
  final Color accentColor;

  AppSettings copyWith({AppThemeMode? themeMode, Color? accentColor}) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
    );
  }
}

class SettingsStore {
  static final SettingsStore instance = SettingsStore._();
  SettingsStore._();

  // По умолчанию: системная тема + стандартный акцент.
  final ValueNotifier<AppSettings> settings = ValueNotifier<AppSettings>(
    AppSettings(
      themeMode: AppThemeMode.system,
      accentColor: Colors.blue,
    ),
  );
}

ThemeMode _toFlutterThemeMode(AppThemeMode mode) {
  switch (mode) {
    case AppThemeMode.system:
      return ThemeMode.system;
    case AppThemeMode.light:
      return ThemeMode.light;
    case AppThemeMode.dark:
      return ThemeMode.dark;
  }
}

/// Windows-only Flutter app:
/// - Bottom navigation: Главная / Фиксы игр
/// - Главная: toggle testsigning (bcdedit) + reboot (shutdown)
/// - Фиксы игр: list of games with + add dialog and per-game toggle that runs
///   a 3-command sequence (placeholders; you will fill them later)
///
/// Notes:
/// - Admin elevation on startup is implemented in Windows runner
///   (windows/runner/main.cpp) via UAC "runas".
/// - Persistence is currently done via a local `games.json` file (in working dir).
///   You can later migrate it to `shared_preferences` or a DB without changing UI much.
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // if (!Platform.isWindows) {
  //   // Hard fail: app is designed for Windows only.
  //   runApp(const _WindowsOnlyApp());
  //   return;
  // }

  runApp(const HypervisorFixApp());
}

// class _WindowsOnlyApp extends StatelessWidget {
//   const _WindowsOnlyApp();

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(
//       debugShowCheckedModeBanner: false,
//       home: Scaffold(
//         body: Center(
//           child: Text(
//             'Это приложение работает только на Windows.',
//             textAlign: TextAlign.center,
//           ),
//         ),
//       ),
//     );
//   }
// }

class HypervisorFixApp extends StatelessWidget {
  const HypervisorFixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: SettingsStore.instance.settings,
      builder: (context, s, _) {
        final seed = s.accentColor;

        return MaterialApp(
          title: 'HypervisorFix',
          debugShowCheckedModeBanner: false,
          themeMode: _toFlutterThemeMode(s.themeMode),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: seed),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const _RootShell(),
        );
      },
    );
  }
}

class _RootShell extends StatefulWidget {
  const _RootShell();

  @override
  State<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<_RootShell> {
  int _index = 0;

  final _pages = const <Widget>[
    HomeScreen(),
    GameFixesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.videogame_asset_outlined),
            activeIcon: Icon(Icons.videogame_asset),
            label: 'Фиксы игр',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }
}

/// ---------------------------
/// Command execution utilities
/// ---------------------------

class CommandResult {
  CommandResult({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  });

  final int exitCode;
  final String stdoutText;
  final String stderrText;

  bool get ok => exitCode == 0;

  @override
  String toString() =>
      'exitCode=$exitCode\nstdout:\n$stdoutText\nstderr:\n$stderrText';
}

class Cmd {
  /// Runs an executable with arguments and captures output.
  static Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    bool runInShell = true,
  }) async {
    final res = await Process.run(
      executable,
      arguments,
      runInShell: runInShell,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );

    return CommandResult(
      exitCode: res.exitCode,
      stdoutText: (res.stdout ?? '').toString(),
      stderrText: (res.stderr ?? '').toString(),
    );
  }

  /// Runs a single command line via `cmd.exe /c ...`.
  static Future<CommandResult> runCmdLine(String cmdLine) {
    return run('cmd.exe', ['/c', cmdLine]);
  }

  /// Runs N cmd lines sequentially.
  ///
  /// By default, stops on first failure.
  /// If [ignoreFailureAtIndices] contains an index (0-based), a non-zero exitCode
  /// for that command will be ignored and execution continues.
  static Future<CommandResult> runSequence(
    List<String> cmdLines, {
    Set<int> ignoreFailureAtIndices = const {},
  }) async {
    CommandResult? last;
    CommandResult? firstNonIgnoredFailure;

    for (var i = 0; i < cmdLines.length; i++) {
      final line = cmdLines[i];
      last = await runCmdLine(line);

      if (last.ok) continue;

      if (ignoreFailureAtIndices.contains(i)) {
        // Intentionally ignore failures for selected command steps
        // (e.g. stopping/deleting a service that may not exist).
        continue;
      }

      firstNonIgnoredFailure = last;
      break;
    }

    if (firstNonIgnoredFailure != null) return firstNonIgnoredFailure;

    return last ??
        CommandResult(exitCode: 0, stdoutText: '', stderrText: '');
  }
}

/// ---------------------------
/// testsigning utilities
/// ---------------------------

enum TestSigningState { on, off, unknown }

class BcdEdit {
  static Future<TestSigningState> getTestSigningState() async {
    final res = await Cmd.run('bcdedit', const []);
    if (!res.ok) return TestSigningState.unknown;

    // Robust parsing: look specifically at the "testsigning" line/value.
    // Typical bcdedit output includes a line like:
    //   testsigning              Yes
    // or:
    //   testsigning              No
    final lines = res.stdoutText.split(RegExp(r'\r?\n'));
    for (final raw in lines) {
      final line = raw.trim().toLowerCase();
      if (!line.startsWith('testsigning')) continue;

      // Collapse whitespace and split tokens.
      final tokens = line.split(RegExp(r'\s+'));
      // Expect: ["testsigning", "yes"] or ["testsigning", "no"]
      if (tokens.length >= 2) {
        final v = tokens[1];
        if (v == 'yes' || v == 'on' || v == 'true') return TestSigningState.on;
        if (v == 'no' || v == 'off' || v == 'false') return TestSigningState.off;
      }
    }

    return TestSigningState.unknown;
  }

  static Future<CommandResult> setTestSigning(bool enabled) async {
    return Cmd.run('bcdedit', ['/set', 'testsigning', enabled ? 'on' : 'off']);
  }

  static Future<CommandResult> rebootNow() async {
    return Cmd.run('shutdown', const ['-r', '-t', '0']);
  }
}

/// ---------------------------
/// Data model + storage (simple)
/// ---------------------------
/// For now this uses a very simple JSON file in the current directory.
/// Later you can replace with Hive/Isar/SharedPreferences.
///
/// File: `games.json` next to the exe/working dir.
/// On Windows release builds, the working dir is commonly the exe folder,
/// but not guaranteed. This is a minimal placeholder storage.

class GameEntry {
  GameEntry({
    required this.id,
    required this.name,
    required this.gameExePath,
    required this.fixExePath,
    required this.enabled,
    required this.fixApplied,
  });

  final String id;
  final String name;

  /// Path to the game's .exe (what you "play"/launch).
  final String gameExePath;

  /// Path to the fix/driver/etc .exe (used in your command templates).
  final String fixExePath;

  /// User toggle (desire to enable fix).
  final bool enabled;

  /// True only after the enable-command sequence finished successfully.
  /// Used to gate the "Играть" button.
  final bool fixApplied;

  GameEntry copyWith({
    String? name,
    String? gameExePath,
    String? fixExePath,
    bool? enabled,
    bool? fixApplied,
  }) {
    return GameEntry(
      id: id,
      name: name ?? this.name,
      gameExePath: gameExePath ?? this.gameExePath,
      fixExePath: fixExePath ?? this.fixExePath,
      enabled: enabled ?? this.enabled,
      fixApplied: fixApplied ?? this.fixApplied,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'gameExePath': gameExePath,
        'fixExePath': fixExePath,
        'enabled': enabled,
        'fixApplied': fixApplied,
      };

  static GameEntry fromJson(Map<String, dynamic> json) {
    return GameEntry(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      gameExePath: (json['gameExePath'] as String?) ?? '',
      fixExePath: (json['fixExePath'] as String?) ?? '',
      enabled: (json['enabled'] as bool?) ?? false,
      fixApplied: (json['fixApplied'] as bool?) ?? false,
    );
  }
}

class GameStore {
  static final GameStore instance = GameStore._();
  GameStore._();

  final ValueNotifier<List<GameEntry>> games = ValueNotifier<List<GameEntry>>([]);

  /// Minimal persistence: simple JSON next to the working directory.
  /// This keeps the code self-contained (no extra service file needed).
  ///
  /// If you later want `shared_preferences`, you can swap `_file` based storage
  /// with a preferences-backed string, keeping the public API the same.
  File get _file => File('games.json');

  Future<void> load() async {
    try {
      if (!await _file.exists()) {
        games.value = [];
        return;
      }

      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        games.value = [];
        return;
      }

      games.value = decoded
          .whereType<Map>()
          .map((m) => GameEntry.fromJson(Map<String, dynamic>.from(m)))
          .where((g) => g.id.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // Keep UI functional even if the file is corrupted.
      games.value = [];
    }
  }

  Future<void> save() async {
    final list = games.value.map((g) => g.toJson()).toList();
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
  }

  Future<void> add(GameEntry entry) async {
    games.value = [...games.value, entry];
    await save();
  }

  Future<void> update(GameEntry entry) async {
    games.value = [
      for (final g in games.value) if (g.id == entry.id) entry else g,
    ];
    await save();
  }

  Future<void> remove(String id) async {
    games.value = games.value.where((g) => g.id != id).toList(growable: false);
    await save();
  }
}

/// ---------------------------
/// UI: Home
/// ---------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  TestSigningState _state = TestSigningState.unknown;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final state = await BcdEdit.getTestSigningState();
    if (!mounted) return;
    setState(() {
      _state = state;
      _busy = false;
    });
  }

  Future<void> _setSwitch(bool enable) async {
    if (_busy) return;

    // Optimistically update UI so the switch reflects user's intent while command runs.
    final prev = _state;
    setState(() {
      _busy = true;
      _state = enable ? TestSigningState.on : TestSigningState.off;
    });

    final res = await BcdEdit.setTestSigning(enable);
    if (!mounted) return;

    if (!res.ok) {
      // Revert UI on failure.
      setState(() {
        _busy = false;
        _state = prev;
      });

      await _showError(
        title: 'Ошибка',
        message:
            'Не удалось выполнить bcdedit.\n\n${res.toString()}\n\n'
            'Проверь, что приложение запущено от администратора.',
      );
      return;
    }

    setState(() => _busy = false);

    await _showInfo(
      title: 'Готово',
      message:
          'Фикс ${enable ? 'включен' : 'выключен'}.\n'
          'Чтобы изменения вступили в силу, нужно перезагрузить ПК.',
    );

    await _refresh();
  }

  Future<void> _reboot() async {
    final res = await BcdEdit.rebootNow();
    if (!res.ok) {
      await _showError(
        title: 'Ошибка перезагрузки',
        message: res.toString(),
      );
    }
  }

  Future<void> _showInfo({required String title, required String message}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
        ],
      ),
    );
  }

  Future<void> _showError({required String title, required String message}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOn = _state == TestSigningState.on;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Главная'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Test Signing: '
                  '${_state == TestSigningState.on ? 'ON' : _state == TestSigningState.off ? 'OFF' : 'UNKNOWN'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Включить фикс',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (_busy) ...[
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Switch(
                          value: isOn,
                          onChanged: _busy ? null : _setSwitch,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _reboot,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Перезагрузить ПК'),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Важно: Создатель данной программы не ручается за ваше устройство\n'
                  'Используйте на свой страх и риск. Рекомендуется создать точку восстановления Windows перед использованием.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ---------------------------
/// UI: Game Fixes
/// ---------------------------

class GameFixesScreen extends StatefulWidget {
  const GameFixesScreen({super.key});

  @override
  State<GameFixesScreen> createState() => _GameFixesScreenState();
}

class _GameFixesScreenState extends State<GameFixesScreen> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await GameStore.instance.load();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _addGame() async {
    final created = await showDialog<GameEntry>(
      context: context,
      builder: (_) => const _AddGameDialog(),
    );
    if (created == null) return;
    await GameStore.instance.add(created);
  }

  /// Placeholder 3-command sequence.
  /// Replace these strings with your real commands later.
  List<String> _buildCommandsForGame(GameEntry game) {
    // Заглушки под твой формат:
    // 1) <комманда 1>
    // 2) <комманда 2> - тут с переменной (подставляется путь к файлу фикса)
    // 3) <комманда 3>
    //
    // Когда будешь готов — просто замени строки ниже на реальные команды.
    const cmd1 = 'sc stop denuvo';
    const cmd2 = 'sc delete denuvo';
    const cmd3 = 'sc create denuvo type=kernel start=demand binPath={path}';
    const cmd4 = 'sc start denuvo';

    return [
      cmd1,
      cmd2,
      cmd3.replaceAll('{path}', game.fixExePath),
      cmd4,
    ];
  }


  Future<void> _setEnabled(GameEntry game, bool enabled) async {
    // We only enable "Играть" after commands succeed (fixApplied=true).
    // If commands fail, revert toggle and keep fixApplied=false.
    final previousEnabled = game.enabled;

    // Any toggle change resets applied-state until we (re)apply successfully.
    await GameStore.instance.update(
      game.copyWith(enabled: enabled, fixApplied: false),
    );

    if (enabled) {
      final seq = _buildCommandsForGame(game);

      // Твоя логика: если 1-я или 2-я команда падают — продолжаем.
      // (например: stop/delete сервиса, которого может не быть)
      final res = await Cmd.runSequence(
        seq,
        ignoreFailureAtIndices: const {0, 1},
      );

      if (!res.ok) {
        await GameStore.instance.update(
          game.copyWith(enabled: previousEnabled, fixApplied: false),
        );
        if (!mounted) return;
        await _showError(
          title: 'Ошибка выполнения команд',
          message:
              'Команда упала, последовательность остановлена.\n\n${res.toString()}',
        );
        return;
      }

      await GameStore.instance.update(
        game.copyWith(enabled: true, fixApplied: true),
      );
    } else {
      // If you later need "disable" commands, implement here.
      // For now, mark as not applied (and keep play disabled).
      await GameStore.instance.update(
        game.copyWith(enabled: false, fixApplied: false),
      );
    }
  }

  Future<void> _deleteGame(GameEntry game) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить игру?'),
        content: Text('Удалить "${game.name}" из списка?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    await GameStore.instance.remove(game.id);
  }

  Future<void> _showError({required String title, required String message}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Фиксы игр'),
        actions: [
          IconButton(
            tooltip: 'Добавить',
            onPressed: _loaded ? _addGame : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<GameEntry>>(
              valueListenable: GameStore.instance.games,
              builder: (context, games, _) {
                if (games.isEmpty) {
                  return const Center(
                    child: Text('Пока нет игр. Нажми + чтобы добавить.'),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: games.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final g = games[i];
                    return Card(
                      child: ListTile(
                        title: Text(g.name),
                        subtitle: Text(g.gameExePath),
                        leading: const Icon(Icons.sports_esports),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FilledButton(
                              onPressed: g.fixApplied
                                  ? () async {
                                      try {
                                        final exe = g.gameExePath.trim();
                                        if (exe.isEmpty) return;

                                        final workingDir = File(exe).parent.path;

                                        await Process.start(
                                          exe,
                                          const [],
                                          workingDirectory: workingDir,
                                          runInShell: false,
                                        );
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        await showDialog<void>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Не удалось запустить игру'),
                                            content: SelectableText(
                                              'Путь:\n${g.gameExePath}\n\nОшибка:\n$e',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(ctx),
                                                child: const Text('OK'),
                                              ),
                                            ],
                                          ),
                                        );
                                      }
                                    }
                                  : null,
                              child: const Text('Играть'),
                            ),
                            const SizedBox(width: 12),
                            Switch(
                              value: g.enabled,
                              onChanged: (v) => _setEnabled(g, v),
                            ),
                            IconButton(
                              tooltip: 'Удалить',
                              onPressed: () => _deleteGame(g),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
      floatingActionButton: !_loaded
          ? null
          : FloatingActionButton(
              onPressed: _addGame,
              child: const Icon(Icons.add),
            ),
    );
  }
}

/// ---------------------------
/// UI: Settings
/// ---------------------------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _accentOptions = <Color>[
    Colors.blue,
    Colors.green,
    Colors.purple,
    Colors.orange,
    Colors.red,
    Colors.teal,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ValueListenableBuilder<AppSettings>(
              valueListenable: SettingsStore.instance.settings,
              builder: (context, s, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Тема',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<AppThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: AppThemeMode.system,
                          label: Text('Системная'),
                          icon: Icon(Icons.computer),
                        ),
                        ButtonSegment(
                          value: AppThemeMode.light,
                          label: Text('Светлая'),
                          icon: Icon(Icons.light_mode_outlined),
                        ),
                        ButtonSegment(
                          value: AppThemeMode.dark,
                          label: Text('Тёмная'),
                          icon: Icon(Icons.dark_mode_outlined),
                        ),
                      ],
                      selected: <AppThemeMode>{s.themeMode},
                      onSelectionChanged: (newSelection) {
                        final mode = newSelection.first;
                        SettingsStore.instance.settings.value =
                            s.copyWith(themeMode: mode);
                      },
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Акцентный цвет',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final c in _accentOptions)
                          _AccentSwatch(
                            color: c,
                            selected:
                                s.accentColor.toARGB32() == c.toARGB32(),
                            onTap: () {
                              SettingsStore.instance.settings.value =
                                  s.copyWith(accentColor: c);
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'По умолчанию используется системная тема.\n'
                      'Цвет и тема применяются сразу.',
                      textAlign: TextAlign.left,
                    ),
                    const Spacer(),
                    Text(
                      'Версия: $kBuildVersion',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
      ),
    );
  }
}

class _AddGameDialog extends StatefulWidget {
  const _AddGameDialog();

  @override
  State<_AddGameDialog> createState() => _AddGameDialogState();
}

class _AddGameDialogState extends State<_AddGameDialog> {
  final _nameCtrl = TextEditingController();
  final _gameExeCtrl = TextEditingController();
  final _fixExeCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _gameExeCtrl.dispose();
    _fixExeCtrl.dispose();
    super.dispose();
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _pickExeInto(TextEditingController ctrl) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['exe'],
      withData: false,
      dialogTitle: 'Выбери файл',
    );

    final path = res?.files.single.path;
    if (path == null || path.trim().isEmpty) return;

    ctrl.text = path;
    if (mounted) setState(() {});
  }

  Future<void> _pickFixFileInto(TextEditingController ctrl) async {
    // Для фикса разрешаем любые типы файлов (.sys, .exe, .dll, и т.д.)
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      dialogTitle: 'Выбери файл фикса',
    );

    final path = res?.files.single.path;
    if (path == null || path.trim().isEmpty) return;

    ctrl.text = path;
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final gameExe = _gameExeCtrl.text.trim();
    final fixExe = _fixExeCtrl.text.trim();

    if (name.isEmpty || gameExe.isEmpty || fixExe.isEmpty) return;

    setState(() => _submitting = true);

    // Basic validation: files exist.
    final gameExists = await File(gameExe).exists();
    final fixExists = await File(fixExe).exists();

    if (!gameExists || !fixExists) {
      setState(() => _submitting = false);
      if (!mounted) return;

      final missing = [
        if (!gameExists) 'Игра: $gameExe',
        if (!fixExists) 'Фикс: $fixExe',
      ].join('\n');

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Файл не найден'),
          content: SelectableText('Не найдены файлы:\n\n$missing'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            )
          ],
        ),
      );
      return;
    }

    final entry = GameEntry(
      id: _newId(),
      name: name,
      gameExePath: gameExe,
      fixExePath: fixExe,
      enabled: false,
      fixApplied: false,
    );

    if (!mounted) return;
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _nameCtrl.text.trim().isNotEmpty &&
        _gameExeCtrl.text.trim().isNotEmpty &&
        _fixExeCtrl.text.trim().isNotEmpty;

    Widget exePickerRow({
      required TextEditingController controller,
      required String label,
      required String hint,
    }) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _submitting ? null : () => _pickExeInto(controller),
            child: const Text('Выбрать .exe'),
          ),
        ],
      );
    }

    Widget fixFilePickerRow({
      required TextEditingController controller,
      required String label,
      required String hint,
    }) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _submitting ? null : () => _pickFixFileInto(controller),
            child: const Text('Выбрать файл'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Добавить игру'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Название',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            exePickerRow(
              controller: _gameExeCtrl,
              label: 'Файл игры (.exe)',
              hint: r'C:\Games\MyGame\game.exe',
            ),
            const SizedBox(height: 12),
            fixFilePickerRow(
              controller: _fixExeCtrl,
              label: 'Файл фикса (любой)',
              hint: r'C:\Path\To\Fix\fix.sys',
            ),
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Кнопка "Играть" станет доступна только после успешного выполнения команд (тумблер включен и команды прошли).',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: (!canSubmit || _submitting) ? null : _submit,
          child: Text(_submitting ? 'Добавляю...' : 'Добавить'),
        ),
      ],
    );
  }
}
