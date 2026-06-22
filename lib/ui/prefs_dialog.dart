// ─────────────────────────────────────────────
// Диалог пользовательских настроек.
//
// Аналог ui/dialogs.py → ask_prefs().
//
// Поведение 1:1 с Python:
//   • Два числовых поля со стрелочками (QSpinBox) с суффиксом " сек".
//   • Подсказки (tooltip) над полями — как setToolTip в Python.
//   • Поле routerIp в Python было скрыто (router_input.hide()) — поступаем
//     так же: Offstage-заглушка, чтобы при необходимости включить было
//     достаточно одного флага.
//   • Серая подсказка снизу.
//   • Кнопки OK / Cancel (QDialogButtonBox).
//
// Возвращает новый Prefs (clamped) или null при отмене. Сохранение в файл
// делает вызывающая сторона (как в Python — MainWindow._open_settings).
//
// Изменения: AppFormRow и сам спинбокс вынесены — но спинбокс
// специфичен для этого диалога, оставляем его здесь приватным.
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/models.dart';
import 'styles.dart';

/// Показать диалог настроек. Возвращает обновлённый Prefs или null,
/// если пользователь нажал «Отмена».
Future<Prefs?> showPrefsDialog(
  BuildContext context, {
  required Prefs current,
}) {
  return showDialog<Prefs>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PrefsDialog(initial: current),
  );
}

class _PrefsDialog extends StatefulWidget {
  final Prefs initial;
  const _PrefsDialog({required this.initial});

  @override
  State<_PrefsDialog> createState() => _PrefsDialogState();
}

class _PrefsDialogState extends State<_PrefsDialog> {
  late int _checkInterval;
  late int _pingInterval;

  @override
  void initState() {
    super.initState();
    _checkInterval = widget.initial.checkInterval;
    _pingInterval = widget.initial.pingInterval;
  }

  void _onOk() {
    // routerIp не редактируется в UI (Python тоже его скрывал) —
    // переносим как есть. clamped() ещё раз страхует диапазон.
    final result = Prefs(
      checkInterval: _checkInterval,
      pingInterval: _pingInterval,
      routerIp: widget.initial.routerIp,
    ).clamped();
    Navigator.of(context).pop(result);
  }

  void _onCancel() => Navigator.of(context).pop(null);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Настройки', style: kTitleStyle),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormRow(
              labelWidth: 170,
              label: 'Интервал проверки сети:',
              field: Tooltip(
                message: 'Как часто проверять состояние Wi-Fi сети',
                child: _SecondsSpinBox(
                  value: _checkInterval,
                  min: kCheckIntervalMin,
                  max: kCheckIntervalMax,
                  onChanged: (v) => setState(() => _checkInterval = v),
                ),
              ),
            ),
            const SizedBox(height: 8),
            AppFormRow(
              labelWidth: 170,
              label: 'Интервал пинга:',
              field: Tooltip(
                message:
                    'Как часто пинговать 8.8.8.8 для отображения задержки',
                child: _SecondsSpinBox(
                  value: _pingInterval,
                  min: kPingIntervalMin,
                  max: kPingIntervalMax,
                  onChanged: (v) => setState(() => _pingInterval = v),
                ),
              ),
            ),

            // routerIp поле — скрыто, как в Python (router_input.hide()).
            const SizedBox(height: 8),
            Offstage(
              offstage: true,
              child: AppFormRow(
                labelWidth: 170,
                label: 'IP роутера:',
                field: TextField(
                  enabled: false,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.initial.routerIp,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),
            const Text(
              'Изменения применяются сразу: '
              'потоки мониторинга и пинга перезапускаются.',
              style: kHintStyle,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _onCancel, child: const Text('Отмена')),
        // OK — зелёная кнопка, как в Python.
        ElevatedButton(
          onPressed: _onOk,
          style: kButtonStart,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// _SecondsSpinBox: число + стрелки ↑/↓ + суффикс " сек".
// Аналог QSpinBox(setSuffix(" сек")) из Python.
//
// Поддерживает:
//   • ручной ввод цифр,
//   • клавиши Up/Down,
//   • кнопки-стрелки справа,
//   • при потере фокуса/Enter — clamp + форматирование.
// ─────────────────────────────────────────────

class _SecondsSpinBox extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _SecondsSpinBox({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  State<_SecondsSpinBox> createState() => _SecondsSpinBoxState();
}

class _SecondsSpinBoxState extends State<_SecondsSpinBox> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _format(widget.value));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SecondsSpinBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Синхронизация поля при внешнем изменении значения — только когда
    // фокуса нет, иначе курсор бы прыгал во время набора.
    if (!_focus.hasFocus && widget.value != oldWidget.value) {
      _ctrl.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  String _format(int v) => '$v сек';

  int _clamp(int v) =>
      v < widget.min ? widget.min : (v > widget.max ? widget.max : v);

  void _commit() {
    final digits = RegExp(r'\d+').firstMatch(_ctrl.text)?.group(0);
    final parsed = int.tryParse(digits ?? '');
    final next = _clamp(parsed ?? widget.value);
    _ctrl.text = _format(next);
    if (next != widget.value) widget.onChanged(next);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _bump(int delta) {
    final next = _clamp(widget.value + delta);
    if (next != widget.value) widget.onChanged(next);
    _ctrl.text = _format(next);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _bump(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _bump(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _handleKey,
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  // Разрешаем цифры, пробел и суффикс " сек".
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 сек]')),
                ],
                onSubmitted: (_) => _commit(),
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ArrowButton(
                icon: Icons.keyboard_arrow_up,
                onPressed: () => _bump(1),
              ),
              _ArrowButton(
                icon: Icons.keyboard_arrow_down,
                onPressed: () => _bump(-1),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _ArrowButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 16,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Icon(icon, size: 16, color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}
