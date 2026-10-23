import 'package:flutter/material.dart';

import '../l10n.dart';
import '../stores.dart';

String get aiNoticeText => t.aiNotice;

/// Shown when the app starts (until the user chooses not to see it again).
Future<void> showAiNotice(BuildContext context, AppSettings settings) async {
  var hide = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(t.aiNoticeTitle),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(aiNoticeText),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(t.dontShowAgain),
            value: hide,
            onChanged: (v) => setState(() => hide = v ?? false),
          ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.gotIt))],
      ),
    ),
  );
  if (hide) settings.aiNoticeHidden = true;
}
