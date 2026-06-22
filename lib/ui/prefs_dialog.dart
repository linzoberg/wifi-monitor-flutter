// ─────────────────────────────────────────────
// Диалог пользовательских настроек.
//
// Аналог ui/dialogs.py → ask_prefs().
//
// Поведение 1:1 с Python:
//   • Два числовых поля со стрелочками (QSpinBox):
//       - "Интервал проверки сети:" с суффиксом " сек"
//       - "Интервал пинга:"          с суффиксом " сек"
//     Диапазоны kCheckInterval/kPingIntervalMin..Max (см. constants.dart).
//   • Подсказки (tooltip) над полями — как setToolTip в Python.
//   • Поле routerIp в Python было создано, но скрыто (router_input.hide()):
//     функция не используется в UI. Здесь поступаем так же — значение
//     routerIp передаётся через current.routerIp без изменений, отдельного
//     виджета нет (раскомментируем, когда понадобится).
//   • Серая подсказка снизу (как в Python).
//   • Кнопки OK / Cancel (QDialogButtonBox).
//
// Возвращает новый Prefs (clamped) или null при отмене. Сохранение в файл
// делает вызывающая сторона (как в Python — MainWindow._open_settings).
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
    // Ширина 380 — как в Python setFixedSize(380, ...). Высоту считает Flutter.
    return AlertDialog(
      title: const Text('Настройки', style: kTitleStyle),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FormRow(
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
            _FormRow(
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

            // ── routerIp поле — скрыто, как в Python (router_input.hide()).
            // Оставляем заготовку, чтобы при включении достаточно было
            // снять hide-обёртку.
            const SizedBox(height: 8),
            Offstage(
              offstage: true,
              child: _FormRow(
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
            // Серый текст-подсказка снизу.
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
        // OK — зелёная кнопка, как в Python (button_style зелёного цвета).
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
//   • ручной ввод цифр (на лету фильтруем не-цифры),
//   • клавиши Up/Down (как в QSpinBox),
//   • кнопки-стрелки справа,
//   • при потере фокуса парсит, клампит в [min, max] и форматирует обратно.
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
  late TextEditingController _ctrl;
  late FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _format(widget.value));
    _focus = FocusNode();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SecondsSpinBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Если родитель прислал новое значение (например, после clamp),
    // синхронизируем поле — но только когда фокуса нет, иначе курсор
    // будет прыгать во время набора.
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
    final raw = _ctrl.text;
    final digits = RegExp(r'\d+').firstMatch(raw)?.group(0);
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (node, event) {
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
              },
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  // Разрешаем цифры, пробел и три буквы "сек" — чтобы суффикс
                  // не ломал поле при редактировании.
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 сек]')),
                ],
                onSubmitted: (_) => _commit(),
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Стрелочки вверх/вниз — компактный столбик, как у QSpinBox.
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

/// Строка формы для диалога настроек — повторяет вёрстку QFormLayout.
/// Используем такой же стиль и ширину подписи, как в credentials_dialog.
class _FormRow extends StatelessWidget {
  final String label;
  final Widget field;

  const _FormRow({required this.label, required this.field});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 170,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.titleDark),
            ),
          ),
          Expanded(child: field),
        ],
      ),
    );
  }
}
