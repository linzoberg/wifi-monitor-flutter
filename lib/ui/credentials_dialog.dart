// ─────────────────────────────────────────────
// Диалог ввода учётных данных Wi-Fi.
//
// Аналог ui/dialogs.py → ask_credentials().
// Те же поля (SSID + пароль + чекбокс "Запомнить меня"),
// та же валидация ("SSID и пароль не могут быть пустыми!"),
// та же логика сохранения через SettingsService.
//
// Использование (из main.dart):
//
//   final creds = await showCredentialsDialog(context, settingsService);
//   if (creds == null) exit(0);
//
// Возвращает Credentials (с заполненными ssid/password) или null,
// если пользователь нажал "Отмена" или ввёл пустые поля.
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/settings_service.dart';
import 'styles.dart';

/// Показывает модальное окно ввода SSID/пароля.
/// Загружает сохранённые значения, при OK сохраняет/забывает
/// учётные данные в SettingsService.
Future<Credentials?> showCredentialsDialog(
  BuildContext context,
  SettingsService settings,
) async {
  // Подгружаем сохранённое: SSID/пароль/флаг remember.
  final saved = await settings.loadCredentials();
  if (!context.mounted) return null;

  return showDialog<Credentials>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _CredentialsDialog(
      initial: saved,
      settings: settings,
    ),
  );
}

class _CredentialsDialog extends StatefulWidget {
  final Credentials initial;
  final SettingsService settings;

  const _CredentialsDialog({
    required this.initial,
    required this.settings,
  });

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  late final TextEditingController _ssidCtrl;
  late final TextEditingController _passwordCtrl;
  late bool _remember;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ssidCtrl = TextEditingController(text: widget.initial.ssid);
    _passwordCtrl = TextEditingController(text: widget.initial.password);
    _remember = widget.initial.remember;
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _onOk() async {
    final ssid = _ssidCtrl.text.trim();
    final password = _passwordCtrl.text.trim();

    if (ssid.isEmpty || password.isEmpty) {
      // 1:1 с QMessageBox.critical из Python.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ошибка'),
          content: const Text('SSID и пароль не могут быть пустыми!'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      if (_remember) {
        await widget.settings.saveCredentials(ssid, password);
      } else {
        await widget.settings.forgetCredentials();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    Navigator.of(context).pop(
      Credentials(ssid: ssid, password: password, remember: _remember),
    );
  }

  void _onCancel() => Navigator.of(context).pop(null);

  @override
  Widget build(BuildContext context) {
    // Размер 350x210 — как Python setFixedSize(350, 210).
    return AlertDialog(
      title: const Text('Настройка Wi-Fi сети'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 350,
        height: 210,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormRow(
              label: 'SSID сети:',
              field: TextField(
                controller: _ssidCtrl,
                autofocus: true,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(isDense: true),
                inputFormatters: [
                  // Запрещаем перевод строки в SSID.
                  FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                ],
              ),
            ),
            const SizedBox(height: 8),
            AppFormRow(
              label: 'Пароль:',
              field: TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _busy ? null : _onOk(),
                decoration: InputDecoration(
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Показать пароль' : 'Скрыть пароль',
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                      size: 18,
                    ),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                // "Пустой label" слева — чтобы чекбокс встал под полями,
                // как в Python QFormLayout.addRow("", remember_checkbox).
                const SizedBox(width: 110),
                Checkbox(
                  value: _remember,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _remember = v ?? false),
                ),
                const Text('Запомнить меня'),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _onCancel,
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: _busy ? null : _onOk,
          child: const Text('OK'),
        ),
      ],
    );
  }
}

