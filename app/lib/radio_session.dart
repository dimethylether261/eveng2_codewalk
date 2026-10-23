import 'package:flutter/foundation.dart';

import 'models.dart';

/// The call being played on the radio screen.
class RadioSession extends ChangeNotifier {
  Dialogue? dialogue;
  int index = 0;
  bool finished = false;

  bool get active => dialogue != null;

  void start(Dialogue d) {
    dialogue = d;
    index = 0;
    finished = false;
    notifyListeners();
  }

  /// Next line; past the last line, the sources page.
  void next() {
    final d = dialogue;
    if (d == null || finished) return;
    if (index + 1 < d.lines.length) {
      index++;
    } else {
      finished = true;
    }
    notifyListeners();
  }

  void prev() {
    if (dialogue == null) return;
    if (finished) {
      finished = false;
    } else if (index > 0) {
      index--;
    } else {
      return;
    }
    notifyListeners();
  }

  void end() {
    if (dialogue == null) return;
    dialogue = null;
    index = 0;
    finished = false;
    notifyListeners();
  }
}
