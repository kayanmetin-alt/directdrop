import 'package:flutter/material.dart';

import '../services/device_identity_service.dart';

/// Cihaz adı düzenleme diyaloğu (ilk kurulum veya ayarlar).
Future<bool> showDeviceNameEditorDialog(
  BuildContext context, {
  required bool isFirstSetup,
}) async {
  final identity = DeviceIdentityService.instance;
  final controller = TextEditingController(text: identity.displayName);
  final formKey = GlobalKey<FormState>();
  var saving = false;

  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: !isFirstSetup,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return PopScope(
            canPop: !isFirstSetup,
            child: AlertDialog(
              title: Text(isFirstSetup ? 'Cihazınızı tanımlayın' : 'Cihaz adını değiştir'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isFirstSetup
                          ? 'Bağlantılarda sizi tanımak için bir ad seçin. '
                              'Örneğin: Metin iPhone, Ofis iPad.'
                          : 'Bu ad QR kodu, bağlantı istekleri ve eşleşme '
                              'listesinde görünür.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: controller,
                      autofocus: true,
                      maxLength: DeviceIdentityService.maxDisplayNameLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: 'Cihaz adı',
                        hintText: identity.platformDefaultName,
                        counterText: '',
                      ),
                      validator: (value) =>
                          DeviceIdentityService.validateDisplayName(
                        value ?? '',
                      ),
                      onFieldSubmitted: (_) async {
                        if (saving) return;
                        if (!(formKey.currentState?.validate() ?? false)) return;
                        setState(() => saving = true);
                        try {
                          await identity.setDisplayName(controller.text);
                          if (context.mounted) {
                            Navigator.of(context).pop(true);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                          setState(() => saving = false);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                if (!isFirstSetup)
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    child: const Text('İptal'),
                  ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!(formKey.currentState?.validate() ?? false)) {
                            return;
                          }
                          setState(() => saving = true);
                          try {
                            await identity.setDisplayName(controller.text);
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop(true);
                            }
                          } catch (e) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                SnackBar(content: Text('$e')),
                              );
                            }
                            setState(() => saving = false);
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(isFirstSetup ? 'Devam' : 'Kaydet'),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  controller.dispose();
  return saved == true;
}
