import 'package:flutter/material.dart';

import '../../infrastructure/services/update_service.dart';
import '../../l10n/app_localizations.dart';

/// Shows the "update available" dialog with Skip / Download & install actions.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info,
  UpdateService service,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info, service: service),
  );
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.info, required this.service});

  final UpdateInfo info;
  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final installing = service.isInstalling;
        final progress = service.downloadProgress;

        return AlertDialog(
          title: Text(l10n.updateAvailableTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.updateAvailableMessage(info.version)),
              if (installing) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text(
                  l10n.updateDownloading,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: installing
              ? null
              : [
                  TextButton(
                    onPressed: () async {
                      await service.skip(info);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    child: Text(l10n.updateSkip),
                  ),
                  FilledButton(
                    onPressed: () async {
                      await service.downloadAndInstall(info);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    child: Text(l10n.updateDownloadInstall),
                  ),
                ],
        );
      },
    );
  }
}
