import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ProcessTerminatorApp());
}

class ProcessTerminatorApp extends StatelessWidget {
  const ProcessTerminatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '到点关',
      debugShowCheckedModeBanner: false,
      // 全部本地化为中文
      locale: const Locale('zh'),
      supportedLocales: const [
        Locale('zh'),
        Locale('en'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F6EF7),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'PingFang SC',
      ),
      home: const HomePage(),
    );
  }
}

/// 获取运行中应用列表
typedef ListAppsFn = Future<List<Map<String, dynamic>>> Function();

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<_TimerItem> _timers = [];
  Map<int, Map<String, dynamic>> _appsById = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshApps();
    _loadCountdownPrefs();
  }

  /// 启动时读取上次使用的倒计时设置(持久化,重启应用仍生效)
  Future<void> _loadCountdownPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _lastCountdown =
            sp.getInt('countdown_value') ?? _lastCountdown;
        final unitIdx = sp.getInt('countdown_unit');
        if (unitIdx != null &&
            unitIdx >= 0 &&
            unitIdx < _CountdownUnit.values.length) {
          _lastCountdownUnit = _CountdownUnit.values[unitIdx];
        }
      });
    } catch (e) {
      debugPrint('【到点关】读取倒计时设置失败: $e');
    }
  }

  /// 保存倒计时设置,下次打开弹框默认使用
  Future<void> _saveCountdownPrefs(int value, _CountdownUnit unit) async {
    _lastCountdown = value;
    _lastCountdownUnit = unit;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('countdown_value', value);
      await sp.setInt('countdown_unit', unit.index);
    } catch (e) {
      debugPrint('【到点关】保存倒计时设置失败: $e');
    }
  }

  Future<void> _refreshApps() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final apps = await MacChannel.listRunningApps();
      setState(() {
        _appsById = {for (final a in apps) (a['pid'] as int): a};
        _loading = false;
      });
    } catch (e) {
      // 输出到 IDE / flutter run 控制台
      debugPrint('【到点关】加载应用列表失败: $e');
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openPicker() async {
    // 打开弹窗时取当前窗口宽度,弹窗固定为窗口的 95%
    final sheetWidth = MediaQuery.of(context).size.width * 0.95;
    final apps = _appsById.values.toList()
      ..sort((a, b) {
        final ah = a['isHidden'] == true ? 1 : 0;
        final bh = b['isHidden'] == true ? 1 : 0;
        if (ah != bh) return ah - bh;
        return (a['localizedName'] ?? '')
            .toString()
            .compareTo((b['localizedName'] ?? '').toString());
      });

    final result = await showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            width: sheetWidth,
            child: _AppPickerSheet(apps: apps),
          ),
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    final mode = await _pickScheduleMode();
    if (mode == null) return;

    Duration? delay;
    DateTime? at;
    if (mode == _ScheduleMode.countdown) {
      delay = await _pickCountdown();
      if (delay == null) return;
    } else {
      at = await _pickTimeOfDay();
      if (at == null) return;
    }

    final forceStr = await _pickTerminateMode();
    if (forceStr == null) return;

    final now = DateTime.now();
    for (final app in result) {
      final pid = app['pid'] as int;
      // 同一 PID 只保留最新的定时,避免重复任务
      _timers.removeWhere((t) => t.pid == pid);
      _timers.add(_TimerItem(
        pid: pid,
        name: (app['localizedName'] ?? 'PID $pid') as String,
        terminateAt:
            mode == _ScheduleMode.countdown ? now.add(delay!) : at!,
        force: forceStr == 'force',
        icon: app['icon'] as Uint8List?,
        path: (app['path'] ?? '') as String,
      ));
    }
    _scheduleNextTick();
    if (mounted) setState(() {});
  }

  /// 添加定时关机/重启系统任务
  Future<void> _addSystemTask(_TaskKind kind) async {
    final label = kind == _TaskKind.shutdown ? '定时关机' : '定时重启';
    final mode = await _pickScheduleMode();
    if (mode == null) return;

    Duration? delay;
    DateTime? at;
    if (mode == _ScheduleMode.countdown) {
      delay = await _pickCountdown();
      if (delay == null) return;
    } else {
      at = await _pickTimeOfDay();
      if (at == null) return;
    }

    // 执行前最后确认
    final now = DateTime.now();
    final terminateAt =
        mode == _ScheduleMode.countdown ? now.add(delay!) : at!;
    final fmt =
        '${terminateAt.month}月${terminateAt.day}日 '
        '${terminateAt.hour}:${terminateAt.minute.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          kind == _TaskKind.shutdown
              ? Icons.power_settings_new
              : Icons.restart_alt,
          size: 32,
          color: Colors.orange.shade700,
        ),
        title: Text(label),
        content: Text(
          '将于 $fmt 系统自动${kind == _TaskKind.shutdown ? "关机" : "重启"},'
          '确认设置吗?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 同类型系统任务只保留最新的一个
    _timers.removeWhere((t) => t.kind == kind);
    _timers.add(_TimerItem(
      pid: 0,
      name: label,
      terminateAt: terminateAt,
      force: true,
      kind: kind,
    ));
    _scheduleNextTick();
    if (mounted) setState(() {});
  }

  Future<_ScheduleMode?> _pickScheduleMode() async {
    return showDialog<_ScheduleMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择定时方式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _ScheduleMode.countdown),
            child: const ListTile(
              leading: Icon(Icons.timer_outlined),
              title: Text('倒计时'),
              subtitle: Text('例如 30 分钟后关闭'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _ScheduleMode.absolute),
            child: const ListTile(
              leading: Icon(Icons.schedule_outlined),
              title: Text('指定时间'),
              subtitle: Text('例如今天 23:30 关闭'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  /// 上次使用的倒计时设置(持久化记忆,默认 10 秒)
  static int _lastCountdown = 10;
  static _CountdownUnit _lastCountdownUnit = _CountdownUnit.seconds;

  Future<Duration?> _pickCountdown() async {
    final ctrl = TextEditingController(text: '$_lastCountdown');
    final unit = ValueNotifier<_CountdownUnit>(_lastCountdownUnit);
    return showDialog<Duration>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('倒计时'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '时长',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            ValueListenableBuilder<_CountdownUnit>(
              valueListenable: unit,
              builder: (ctx, v, _) => DropdownButton<_CountdownUnit>(
                value: v,
                items: const [
                  DropdownMenuItem(
                    value: _CountdownUnit.minutes,
                    child: Text('分钟'),
                  ),
                  DropdownMenuItem(value: _CountdownUnit.hours, child: Text('小时')),
                  DropdownMenuItem(
                    value: _CountdownUnit.seconds,
                    child: Text('秒'),
                  ),
                ],
                onChanged: (nv) => unit.value = nv!,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n == null || n <= 0) return;
              // 记住本次选择,下次打开弹框默认使用(含重启应用后)
              _saveCountdownPrefs(n, unit.value);
              Navigator.pop(
                ctx,
                switch (unit.value) {
                  _CountdownUnit.seconds => Duration(seconds: n),
                  _CountdownUnit.minutes => Duration(minutes: n),
                  _CountdownUnit.hours => Duration(hours: n),
                },
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickTimeOfDay() async {
    final now = DateTime.now();
    // +1分1秒:秒位默认为0,多加1秒保证默认时间一定晚于当前时间(不触发无效校验)
    final initial = now.add(const Duration(minutes: 1, seconds: 1));
    int year = initial.year;
    int month = initial.month;
    int day = initial.day;
    int hour = initial.hour;
    int minute = initial.minute;
    int second = 0;

    // 当月天数(切换年月时用于收敛日期)
    int daysInMonth() => DateTime(year, month + 1, 0).day;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 年月变化后,日期超出当月天数时收敛
          if (day > daysInMonth()) day = daysInMonth();
          final dt = DateTime(year, month, day, hour, minute, second);
          final invalid = !dt.isAfter(now);

          // 通用的数字下拉框构造
          DropdownButtonFormField<int> dd(
            String label,
            int value,
            int min,
            int max,
            String suffix,
            void Function(int v) on,
          ) =>
              DropdownButtonFormField<int>(
                value: value,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: label,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (var i = min; i <= max; i++)
                    DropdownMenuItem(value: i, child: Text('$i$suffix')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => on(v));
                },
              );

          return AlertDialog(
            title: const Text('指定关闭时间'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: dd('年', year, now.year, now.year + 5, '年',
                          (v) => year = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: dd('月', month, 1, 12, '月', (v) => month = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: dd('日', day, 1, daysInMonth(), '日', (v) => day = v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: dd('时', hour, 0, 23, '时', (v) => hour = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: dd('分', minute, 0, 59, '分', (v) => minute = v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: dd('秒', second, 0, 59, '秒', (v) => second = v),
                    ),
                  ],
                ),
                if (invalid)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '所选时间早于当前时间,请重新选择',
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                // 时间无效时禁止确认
                onPressed: invalid ? null : () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );

    if (ok != true) return null;
    return DateTime(year, month, day, hour, minute, second);
  }

  Future<String?> _pickTerminateMode() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭方式'),
        content: const Text(
          '优雅退出会发送正常的退出请求(相当于 Cmd+Q),应用可能弹出保存确认;'
          '强制结束会立即杀掉进程,未保存内容会丢失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'graceful'),
            child: const Text('优雅退出'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'force'),
            child: const Text('强制结束'),
          ),
        ],
      ),
    );
  }

  void _scheduleNextTick() {
    Future.delayed(const Duration(seconds: 1), _tick);
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final now = DateTime.now();
    final due = _timers.where((t) => !t.terminateAt.isAfter(now)).toList();
    for (final t in due) {
      _timers.remove(t);
      try {
        if (t.kind == _TaskKind.shutdown) {
          await MacChannel.systemShutdown();
        } else if (t.kind == _TaskKind.restart) {
          await MacChannel.systemRestart();
        } else if (t.force) {
          await MacChannel.forceQuit(t.pid);
        } else {
          await MacChannel.terminateGracefully(t.pid);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t.kind == _TaskKind.shutdown
                    ? '已执行系统关机'
                    : t.kind == _TaskKind.restart
                        ? '已执行系统重启'
                        : '已${t.force ? "强制结束" : "发送退出请求"}:${t.name}(PID ${t.pid})'),
            ),
          );
        }
      } catch (e) {
        await _showError(
          t.kind == _TaskKind.app ? '关闭 ${t.name}(PID ${t.pid})' : t.name,
          e,
          item: t.kind == _TaskKind.app ? t : null,
        );
      }
    }
    if (mounted) setState(() {});
    // 没有待处理的定时任务时停止轮询,避免空转
    if (_timers.isNotEmpty) _scheduleNextTick();
  }

  /// 出错时弹提示框,并把错误内容同时打印到控制台
  /// 若是优雅退出超时(item 非空),提供"立即强制结束"一键升级按钮
  Future<void> _showError(String action, Object error, {_TimerItem? item}) async {
    // 输出到 IDE / flutter run 控制台
    debugPrint('【到点关】$action 失败: $error');
    if (!mounted) return;
    final theme = Theme.of(context);
    final canForce =
        item != null &&
        error is PlatformException &&
        (error.code == 'TERMINATE_TIMEOUT' ||
         error.code == 'TERMINATE_FAILED');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.error_outline, color: theme.colorScheme.error, size: 32),
        title: Text('$action 失败'),
        content: Text(
          error.toString(),
          style: TextStyle(color: theme.colorScheme.error),
        ),
        actions: [
          if (canForce)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _forceQuitNow(item);
              },
              child: const Text('立即强制结束'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _forceQuitNow(_TimerItem t) async {
    try {
      await MacChannel.forceQuit(t.pid);
      debugPrint('【到点关】已升级为强制结束:${t.name}(PID ${t.pid})');
      if (mounted) {
        setState(() => _timers.removeWhere((x) => x.pid == t.pid));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已强制结束:${t.name}(PID ${t.pid})')),
        );
      }
    } catch (e) {
      await _showError('强制结束 ${t.name}(PID ${t.pid})', e);
    }
  }

  /// 取消定时前弹窗确认,防止误点
  Future<void> _confirmRemove(_TimerItem t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消定时'),
        content: Text(
          t.kind == _TaskKind.app
              ? '确定要取消「${t.name}」(PID ${t.pid})的定时关闭吗?'
              : '确定要取消「${t.name}」的定时任务吗?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _timers.remove(t));
    }
  }

  /// 辅助功能权限指引是否已提示过(每次应用运行只提示一次)
  bool _axGuideShown = false;

  /// 激活前检测辅助功能权限,未授权时弹出操作指引
  /// (系统不会自动弹这个授权框,需要引导用户手动开启)
  Future<void> _ensureAxGuide() async {
    if (_axGuideShown) return;
    _axGuideShown = true;
    bool trusted;
    try {
      trusted = await MacChannel.axTrusted();
    } catch (_) {
      return; // 检测失败就不打扰用户
    }
    if (trusted || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.accessibility_new, size: 32),
        title: const Text('建议开启辅助功能权限'),
        content: const Text(
          '恢复最小化的窗口需要「辅助功能」权限,开启方法:\n\n'
          '1. 点击下方按钮打开 系统设置 → 隐私与安全性 → 辅助功能\n'
          '2. 在列表中找到「到点关」并打开开关\n'
          '   (列表中没有时,点「+」选择应用手动添加)\n\n'
          '未授权时激活功能仍可使用,只是无法恢复最小化的窗口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不开启'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              MacChannel.openAxSettings();
            },
            child: const Text('打开系统设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _activateApp(_TimerItem t) async {
    // 未授权辅助功能时先弹一次指引
    await _ensureAxGuide();
    try {
      await MacChannel.activateApp(t.pid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已激活:${t.name}(PID ${t.pid})')),
        );
      }
    } catch (e) {
      await _showError('激活 ${t.name}(PID ${t.pid})', e);
    }
  }

  /// 最小化所有应用的窗口
  Future<void> _minimizeAllApps() async {
    // 最小化窗口依赖辅助功能权限,未授权时先弹一次指引
    await _ensureAxGuide();
    try {
      final n = await MacChannel.minimizeAllApps();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              n > 0
                  ? '已最小化 $n 个窗口'
                  : '没有最小化任何窗口,请确认已在系统设置中开启辅助功能权限',
            ),
          ),
        );
      }
    } catch (e) {
      await _showError('最小化所有应用', e);
    }
  }

  /// 恢复所有应用:取消隐藏并恢复最小化的窗口
  Future<void> _restoreAllApps() async {
    await _ensureAxGuide();
    try {
      final n = await MacChannel.restoreAllApps();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              n > 0
                  ? '已恢复 $n 个应用/窗口'
                  : '没有恢复任何内容(可能无需恢复,或未开启辅助功能权限)',
            ),
          ),
        );
      }
    } catch (e) {
      await _showError('恢复所有应用', e);
    }
  }

  String _fmtRemaining(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h小时$m分$s秒';
    if (m > 0) return '$m分$s秒';
    return '$s秒';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('到点关 · 进程定时关闭'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '刷新应用列表',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshApps,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('选择应用并设置定时关闭'),
                onPressed: _appsById.isEmpty ? null : _openPicker,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.power_settings_new, size: 20),
                    label: const Text('定时关机'),
                    onPressed: () => _addSystemTask(_TaskKind.shutdown),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.restart_alt, size: 20),
                    label: const Text('定时重启'),
                    onPressed: () => _addSystemTask(_TaskKind.restart),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.minimize, size: 20),
                    label: const Text('所有程序最小化'),
                    onPressed: _minimizeAllApps,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.restore, size: 20),
                    label: const Text('所有程序恢复'),
                    onPressed: _restoreAllApps,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '加载失败:$_error\n\n请确认以 macOS 桌面应用方式运行,\n且已在 entitlements 中关闭沙盒(见 README)。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      )
                    : _timers.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.alarm_add_outlined,
                                    size: 56,
                                    color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无定时任务',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '点击上方按钮,选择正在运行的应用并设置关闭时间',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            itemCount: _timers.length,
                            itemBuilder: (ctx, i) {
                              final t = _timers[i];
                              final remain = t.terminateAt.difference(DateTime.now());
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: Colors.grey.shade200),
                                ),
                                child: ListTile(
                                  leading: t.kind == _TaskKind.app
                                      ? _buildAppIcon(context, t.icon, t.name)
                                      : CircleAvatar(
                                          backgroundColor:
                                              Colors.orange.shade100,
                                          child: Icon(
                                            t.kind == _TaskKind.shutdown
                                                ? Icons.power_settings_new
                                                : Icons.restart_alt,
                                            color: Colors.orange.shade800,
                                          ),
                                        ),
                                  title: Text(t.name),
                                  subtitle: Text(
                                    t.kind == _TaskKind.app
                                        ? 'PID ${t.pid} · 目标时间 '
                                            '${t.terminateAt.toIso8601String().substring(0, 10)} '
                                            '${t.terminateAt.toIso8601String().substring(11, 19)}'
                                            ' · ${t.force ? "强制结束" : "优雅退出"}'
                                        : '目标时间 '
                                            '${t.terminateAt.toIso8601String().substring(0, 10)} '
                                            '${t.terminateAt.toIso8601String().substring(11, 19)}'
                                            ' · 系统自动${t.kind == _TaskKind.shutdown ? "关机" : "重启"}',
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _fmtRemaining(remain),
                                        style: TextStyle(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      // 系统级任务没有"激活窗口"一说,不显示该按钮
                                      if (t.kind == _TaskKind.app)
                                        IconButton(
                                          tooltip: '激活该应用窗口',
                                          icon: const Icon(Icons.open_in_new),
                                          onPressed: () => _activateApp(t),
                                        ),
                                      IconButton(
                                        tooltip: '取消定时',
                                        icon: const Icon(Icons.close),
                                        onPressed: () => _confirmRemove(t),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

/// macOS 平台通道封装
class MacChannel {
  static const _ch = MethodChannel('com.macappds.process_terminator');

  /// 列出正在运行的常规应用(排除自身与系统后台进程)
  static Future<List<Map<String, dynamic>>> listRunningApps() async {
    final raw = await _ch.invokeListMethod('listRunningApps');
    return (raw ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// 优雅退出(相当于 Cmd+Q / NSApplicationDelegate 应用正常退出流程)
  static Future<void> terminateGracefully(int pid) =>
      _ch.invokeMethod('terminateGracefully', {'pid': pid});

  /// 强制结束(SIGKILL)
  static Future<void> forceQuit(int pid) =>
      _ch.invokeMethod('forceQuit', {'pid': pid});

  /// 激活应用,把它的窗口调到前台
  static Future<void> activateApp(int pid) =>
      _ch.invokeMethod('activateApp', {'pid': pid});

  /// 系统关机
  static Future<void> systemShutdown() =>
      _ch.invokeMethod('systemShutdown');

  /// 系统重启
  static Future<void> systemRestart() =>
      _ch.invokeMethod('systemRestart');

  /// 是否已授予辅助功能权限(用于恢复最小化窗口)
  static Future<bool> axTrusted() async =>
      await _ch.invokeMethod('axTrusted') == true;

  /// 打开系统设置的辅助功能权限页面
  static Future<void> openAxSettings() =>
      _ch.invokeMethod('openAxSettings');

  /// 最小化所有运行中应用的全部窗口(需要辅助功能权限)
  /// 返回成功最小化的窗口数量,为 0 通常表示缺少辅助功能权限
  static Future<int> minimizeAllApps() async =>
      (await _ch.invokeMethod('minimizeAllApps')) as int? ?? 0;

  /// 恢复所有应用:取消隐藏并恢复最小化的窗口(需要辅助功能权限)
  /// 返回恢复的数量,为 0 通常表示缺少辅助功能权限或无需恢复
  static Future<int> restoreAllApps() async =>
      (await _ch.invokeMethod('restoreAllApps')) as int? ?? 0;
}

/// 应用图标:有真实图标显示图标,否则用首字符占位
Widget _buildAppIcon(BuildContext context, Uint8List? icon, String name) {
  if (icon != null && icon.isNotEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        icon,
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _letterAvatar(context, name),
      ),
    );
  }
  return _letterAvatar(context, name);
}

Widget _letterAvatar(BuildContext context, String name) {
  final theme = Theme.of(context);
  return CircleAvatar(
    backgroundColor: theme.colorScheme.primaryContainer,
    child: Text(
      name.isNotEmpty ? name.characters.first : '?',
      style: TextStyle(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

enum _ScheduleMode { countdown, absolute }

enum _CountdownUnit { seconds, minutes, hours }

/// 定时任务类型:关闭应用 / 系统关机 / 系统重启
enum _TaskKind { app, shutdown, restart }

class _TimerItem {
  final int pid;
  final String name;
  final DateTime terminateAt;
  final bool force;
  final Uint8List? icon;
  final String path;
  final _TaskKind kind;
  _TimerItem({
    required this.pid,
    required this.name,
    required this.terminateAt,
    required this.force,
    this.icon,
    this.path = '',
    this.kind = _TaskKind.app,
  });
}

class _AppPickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> apps;
  const _AppPickerSheet({required this.apps});

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  final Set<int> _selected = {};
  String _query = '';

  Future<void> _activate(String name, int pid) async {
    try {
      await MacChannel.activateApp(pid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已激活:$name(PID $pid)')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('激活 $name 失败:$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 统计同名应用数量,用于判断是否需要用路径区分
    final nameCount = <String, int>{};
    for (final a in widget.apps) {
      final n = (a['localizedName'] ?? '').toString();
      nameCount[n] = (nameCount[n] ?? 0) + 1;
    }
    final filtered = widget.apps
        .where((a) => (a['localizedName'] ?? '')
            .toString()
            .toLowerCase()
            .contains(_query.toLowerCase()))
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: 40, bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text('选择应用', style: theme.textTheme.titleLarge),
                const Spacer(),
                Text(
                  '已选 ${_selected.length} 个',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索应用',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text('没有匹配的应用', style: theme.textTheme.bodyMedium))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final app = filtered[i];
                      final pid = app['pid'] as int;
                      final name =
                          (app['localizedName'] ?? 'PID $pid') as String;
                      final path = (app['path'] ?? '') as String;
                      final icon = app['icon'] as Uint8List?;
                      // 同名应用存在多个时,用可执行路径区分
                      final duplicated = (nameCount[name] ?? 0) > 1;
                      final selected = _selected.contains(pid);
                      // ListTile 的背景与水波纹绘制在最近的 Material 祖先上,
                      // 外层 Container 的装饰背景会遮挡它们,因此单独包一层透明 Material
                      return Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                        leading: Checkbox(
                          value: selected,
                          onChanged: (v) => setState(() {
                            v == true
                                ? _selected.add(pid)
                                : _selected.remove(pid);
                          }),
                        ),
                        title: Text(name),
                        subtitle: Text(
                          duplicated
                              ? 'PID $pid · ${path.isEmpty ? "路径未知" : path}'
                              : 'PID $pid'
                                  '${app['isHidden'] == true ? " · 已隐藏" : ""}',
                          // 长路径自动换行显示,不用省略号截断
                          softWrap: true,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildAppIcon(context, icon, name),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '激活该应用窗口',
                              icon: const Icon(Icons.open_in_new),
                              onPressed: () => _activate(name, pid),
                            ),
                          ],
                        ),
                        onTap: () => setState(() {
                          selected ? _selected.remove(pid) : _selected.add(pid);
                        }),
                      ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () {
                          Navigator.pop(
                            context,
                            widget.apps
                                .where((a) => _selected.contains(a['pid']))
                                .toList(),
                          );
                        },
                  child: const Text('下一步'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
