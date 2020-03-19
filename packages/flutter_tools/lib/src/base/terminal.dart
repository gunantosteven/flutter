// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:platform/platform.dart';

import '../convert.dart';
import '../globals.dart' as globals;
import 'io.dart' as io;
import 'logger.dart';

enum TerminalColor {
  red,
  green,
  blue,
  cyan,
  yellow,
  magenta,
  grey,
}

/// Warning mark to use in stdout or stderr.
String get warningMark {
  return globals.terminal.bolden(globals.terminal.color('[!]', TerminalColor.red));
}

/// Success mark to use in stdout.
String get successMark {
  return globals.terminal.bolden(globals.terminal.color('✓', TerminalColor.green));
}

/// A class that contains the context settings for command text output to the
/// console.
class OutputPreferences {
  OutputPreferences({
    bool wrapText,
    int wrapColumn,
    bool showColor,
  }) : wrapText = wrapText ?? globals.stdio.hasTerminal,
       _overrideWrapColumn = wrapColumn,
       showColor = showColor ?? globals.platform.stdoutSupportsAnsi ?? false;

  /// A version of this class for use in tests.
  OutputPreferences.test({this.wrapText = false, int wrapColumn = kDefaultTerminalColumns, this.showColor = false})
    : _overrideWrapColumn = wrapColumn;

  /// If [wrapText] is true, then any text sent to the context's [Logger]
  /// instance (e.g. from the [printError] or [printStatus] functions) will be
  /// wrapped (newlines added between words) to be no longer than the
  /// [wrapColumn] specifies. Defaults to true if there is a terminal. To
  /// determine if there's a terminal, [OutputPreferences] asks the context's
  /// stdio.
  final bool wrapText;

  /// The terminal width used by the [wrapText] function if there is no terminal
  /// attached to [io.Stdio], --wrap is on, and --wrap-columns was not specified.
  static const int kDefaultTerminalColumns = 100;

  /// The column at which output sent to the context's [Logger] instance
  /// (e.g. from the [printError] or [printStatus] functions) will be wrapped.
  /// Ignored if [wrapText] is false. Defaults to the width of the output
  /// terminal, or to [kDefaultTerminalColumns] if not writing to a terminal.
  final int _overrideWrapColumn;
  int get wrapColumn {
    return _overrideWrapColumn ?? globals.stdio.terminalColumns ?? kDefaultTerminalColumns;
  }

  /// Whether or not to output ANSI color codes when writing to the output
  /// terminal. Defaults to whatever [platform.stdoutSupportsAnsi] says if
  /// writing to a terminal, and false otherwise.
  final bool showColor;

  @override
  String toString() {
    return '$runtimeType[wrapText: $wrapText, wrapColumn: $wrapColumn, showColor: $showColor]';
  }
}

/// The command line terminal, if available.
abstract class Terminal {
  factory Terminal.test() = _TestTerminal;

  /// Whether the current terminal supports color escape codes.
  bool get supportsColor;

  /// Whether the current terminal can display emoji.
  bool get supportsEmoji;

  /// Whether we are interacting with the flutter tool via the terminal.
  ///
  /// If not set, defaults to false.
  bool get usesTerminalUi;
  set usesTerminalUi(bool value);

  String bolden(String message);

  String color(String message, TerminalColor color);

  String clearScreen();

  set singleCharMode(bool value);

  /// Return keystrokes from the console.
  ///
  /// Useful when the console is in [singleCharMode].
  Stream<String> get keystrokes;

  /// Prompts the user to input a character within a given list. Re-prompts if
  /// entered character is not in the list.
  ///
  /// The `prompt`, if non-null, is the text displayed prior to waiting for user
  /// input each time. If `prompt` is non-null and `displayAcceptedCharacters`
  /// is true, the accepted keys are printed next to the `prompt`.
  ///
  /// The returned value is the user's input; if `defaultChoiceIndex` is not
  /// null, and the user presses enter without any other input, the return value
  /// will be the character in `acceptedCharacters` at the index given by
  /// `defaultChoiceIndex`.
  ///
  /// If [usesTerminalUi] is false, throws a [StateError].
  Future<String> promptForCharInput(
    List<String> acceptedCharacters, {
    @required Logger logger,
    String prompt,
    int defaultChoiceIndex,
    bool displayAcceptedCharacters = true,
  });
}

class AnsiTerminal implements Terminal {
  AnsiTerminal({
    @required io.Stdio stdio,
    @required Platform platform,
  })
    : _stdio = stdio,
      _platform = platform;

  final io.Stdio _stdio;
  final Platform _platform;

  static const String bold = '\u001B[1m';
  static const String resetAll = '\u001B[0m';
  static const String resetColor = '\u001B[39m';
  static const String resetBold = '\u001B[22m';
  static const String clear = '\u001B[2J\u001B[H';

  static const String red = '\u001b[31m';
  static const String green = '\u001b[32m';
  static const String blue = '\u001b[34m';
  static const String cyan = '\u001b[36m';
  static const String magenta = '\u001b[35m';
  static const String yellow = '\u001b[33m';
  static const String grey = '\u001b[1;30m';

  static const Map<TerminalColor, String> _colorMap = <TerminalColor, String>{
    TerminalColor.red: red,
    TerminalColor.green: green,
    TerminalColor.blue: blue,
    TerminalColor.cyan: cyan,
    TerminalColor.magenta: magenta,
    TerminalColor.yellow: yellow,
    TerminalColor.grey: grey,
  };

  static String colorCode(TerminalColor color) => _colorMap[color];

  @override
  bool get supportsColor => _platform.stdoutSupportsAnsi ?? false;

  // Assume unicode emojis are supported when not on Windows.
  // If we are on Windows, unicode emojis are supported in Windows Terminal,
  // which sets the WT_SESSION environment variable. See:
  // https://github.com/microsoft/terminal/blob/master/doc/user-docs/index.md#tips-and-tricks
  @override
  bool get supportsEmoji => !_platform.isWindows
    || _platform.environment.containsKey('WT_SESSION');

  final RegExp _boldControls = RegExp(
    '(${RegExp.escape(resetBold)}|${RegExp.escape(bold)})',
  );

  @override
  bool usesTerminalUi = false;

  @override
  String bolden(String message) {
    assert(message != null);
    if (!supportsColor || message.isEmpty) {
      return message;
    }
    final StringBuffer buffer = StringBuffer();
    for (String line in message.split('\n')) {
      // If there were bolds or resetBolds in the string before, then nuke them:
      // they're redundant. This prevents previously embedded resets from
      // stopping the boldness.
      line = line.replaceAll(_boldControls, '');
      buffer.writeln('$bold$line$resetBold');
    }
    final String result = buffer.toString();
    // avoid introducing a new newline to the emboldened text
    return (!message.endsWith('\n') && result.endsWith('\n'))
        ? result.substring(0, result.length - 1)
        : result;
  }

  @override
  String color(String message, TerminalColor color) {
    assert(message != null);
    if (!supportsColor || color == null || message.isEmpty) {
      return message;
    }
    final StringBuffer buffer = StringBuffer();
    final String colorCodes = _colorMap[color];
    for (String line in message.split('\n')) {
      // If there were resets in the string before, then keep them, but
      // restart the color right after. This prevents embedded resets from
      // stopping the colors, and allows nesting of colors.
      line = line.replaceAll(resetColor, '$resetColor$colorCodes');
      buffer.writeln('$colorCodes$line$resetColor');
    }
    final String result = buffer.toString();
    // avoid introducing a new newline to the colored text
    return (!message.endsWith('\n') && result.endsWith('\n'))
        ? result.substring(0, result.length - 1)
        : result;
  }

  @override
  String clearScreen() => supportsColor ? clear : '\n\n';

  @override
  set singleCharMode(bool value) {
    if (!_stdio.stdinHasTerminal) {
      return;
    }
    final io.Stdin stdin = _stdio.stdin as io.Stdin;
    // The order of setting lineMode and echoMode is important on Windows.
    if (value) {
      stdin.echoMode = false;
      stdin.lineMode = false;
    } else {
      stdin.lineMode = true;
      stdin.echoMode = true;
    }
  }

  Stream<String> _broadcastStdInString;

  @override
  Stream<String> get keystrokes {
    _broadcastStdInString ??= _stdio.stdin.transform<String>(const AsciiDecoder(allowInvalid: true)).asBroadcastStream();
    return _broadcastStdInString;
  }

  @override
  Future<String> promptForCharInput(
    List<String> acceptedCharacters, {
    @required Logger logger,
    String prompt,
    int defaultChoiceIndex,
    bool displayAcceptedCharacters = true,
  }) async {
    assert(acceptedCharacters != null);
    assert(acceptedCharacters.isNotEmpty);
    assert(prompt == null || prompt.isNotEmpty);
    assert(displayAcceptedCharacters != null);
    if (!usesTerminalUi) {
      throw StateError('cannot prompt without a terminal ui');
    }
    List<String> charactersToDisplay = acceptedCharacters;
    if (defaultChoiceIndex != null) {
      assert(defaultChoiceIndex >= 0 && defaultChoiceIndex < acceptedCharacters.length);
      charactersToDisplay = List<String>.from(charactersToDisplay);
      charactersToDisplay[defaultChoiceIndex] = bolden(charactersToDisplay[defaultChoiceIndex]);
      acceptedCharacters.add('\n');
    }
    String choice;
    singleCharMode = true;
    while (choice == null || choice.length > 1 || !acceptedCharacters.contains(choice)) {
      if (prompt != null) {
        logger.printStatus(prompt, emphasis: true, newline: false);
        if (displayAcceptedCharacters) {
          logger.printStatus(' [${charactersToDisplay.join("|")}]', newline: false);
        }
        logger.printStatus(': ', emphasis: true, newline: false);
      }
      choice = await keystrokes.first;
      logger.printStatus(choice);
    }
    singleCharMode = false;
    if (defaultChoiceIndex != null && choice == '\n') {
      choice = acceptedCharacters[defaultChoiceIndex];
    }
    return choice;
  }
}

class _TestTerminal implements Terminal {
  @override
  bool usesTerminalUi;

  @override
  String bolden(String message) => message;

  @override
  String clearScreen() => '\n\n';

  @override
  String color(String message, TerminalColor color) => message;

  @override
  Stream<String> get keystrokes => const Stream<String>.empty();

  @override
  Future<String> promptForCharInput(List<String> acceptedCharacters, {
    @required Logger logger,
    String prompt,
    int defaultChoiceIndex,
    bool displayAcceptedCharacters = true,
  }) {
    throw UnsupportedError('promptForCharInput not supported in the test terminal.');
  }

  @override
  set singleCharMode(bool value) { }

  @override
  bool get supportsColor => false;

  @override
  bool get supportsEmoji => false;
}
