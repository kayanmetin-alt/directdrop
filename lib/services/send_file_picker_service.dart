import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum SendFileSource {
  photosLibrary,
  deviceStorage,
}

/// Mac / iPhone: Dosya Gönder için kaynak seçimi ve dosya seçimi.
class SendFilePickerService {
  SendFilePickerService._();

  static const MethodChannel _mediaChannel =
      MethodChannel('com.directdrop.app/media_picker');

  static Future<List<String>?> pickWithSourceChoice(BuildContext context) async {
    if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) {
      return _pickFromDeviceStorage();
    }

    final source = await _showSourceSheet(context);
    if (source == null) return null;

    switch (source) {
      case SendFileSource.photosLibrary:
        return _pickFromPhotosLibrary();
      case SendFileSource.deviceStorage:
        return _pickFromDeviceStorage();
    }
  }

  static Future<SendFileSource?> _showSourceSheet(BuildContext context) {
    if (Platform.isMacOS) {
      return showDialog<SendFileSource>(
        context: context,
        builder: (context) => _SendSourceDialog(
          onSelected: (source) => Navigator.pop(context, source),
        ),
      );
    }

    final theme = Theme.of(context);

    return showModalBottomSheet<SendFileSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Dosyayı nereden göndermek istiyorsunuz?',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(
                    Icons.photo_library_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('Fotoğraflar'),
                  subtitle: const Text(
                    'Fotoğraf ve videolarınızı kütüphaneden seçin',
                  ),
                  onTap: () =>
                      Navigator.pop(context, SendFileSource.photosLibrary),
                ),
                ListTile(
                  leading: Icon(
                    Icons.folder_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('Dosyalar'),
                  subtitle: const Text(
                    'Cihazınızdaki veya harici diskteki dosyaları seçin',
                  ),
                  onTap: () =>
                      Navigator.pop(context, SendFileSource.deviceStorage),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<List<String>?> _pickFromPhotosLibrary() async {
    try {
      final result = await _mediaChannel.invokeMethod<List<dynamic>>(
        'pickFromPhotos',
      );
      if (result == null || result.isEmpty) return null;
      return result.whereType<String>().where((path) => path.isNotEmpty).toList();
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'Fotoğraflar seçilemedi.');
    }
  }

  static Future<List<String>?> _pickFromDeviceStorage() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withReadStream: false,
      dialogTitle: 'Gönderilecek dosyaları seçin',
    );

    if (result == null || result.files.isEmpty) return null;

    final paths = result.files
        .where((file) => file.path != null)
        .map((file) => file.path!)
        .toList();

    if (paths.isEmpty) {
      throw StateError('Seçilen dosyaların yolu alınamadı.');
    }

    return paths;
  }
}

class _SendSourceDialog extends StatelessWidget {
  const _SendSourceDialog({required this.onSelected});

  final ValueChanged<SendFileSource> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Dosyayı nereden göndermek istiyorsunuz?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              Icons.photo_library_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Fotoğraflar'),
            subtitle: const Text('Fotoğraf ve videolarınızı kütüphaneden seçin'),
            onTap: () => onSelected(SendFileSource.photosLibrary),
          ),
          ListTile(
            leading: Icon(
              Icons.folder_outlined,
              color: theme.colorScheme.primary,
            ),
            title: const Text('Dosyalar'),
            subtitle: const Text(
              'Cihazınızdaki veya harici diskteki dosyaları seçin',
            ),
            onTap: () => onSelected(SendFileSource.deviceStorage),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
      ],
    );
  }
}
