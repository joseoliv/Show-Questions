import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';
import 'package:markdown/markdown.dart' as md;

const defaultIntervalSeconds = 60;
var duracaoTotalQuestionario = 0;
// ==========================================
// MODELOS DE DADOS
// ==========================================

class QuestionOption {
  String letter;
  String option;

  QuestionOption({required this.letter, required this.option});
}

class Pergunta {
  Pergunta({
    this.question = '',
    this.number = 0,
    this.optionList,
    this.value,
    this.duration,
    this.hasSpecifiedDuration = false,
    this.correctAnswerIndex = -1,
  });

  String? question;
  int number = 0;
  List<QuestionOption>? optionList;
  double? value;
  int? duration;
  bool hasSpecifiedDuration;
  int correctAnswerIndex = -1;
  String get correctAnswerLetter {
    if (correctAnswerIndex >= 0 &&
        optionList != null &&
        correctAnswerIndex < optionList!.length) {
      return optionList![correctAnswerIndex].letter;
    }
    return '';
  }
}

// ==========================================
// EXCEÇÃO E ANALISADOR SINTÁTICO (PARSER)
// ==========================================

class ParseException implements Exception {
  final int line;
  final String message;

  ParseException(this.line, this.message);

  @override
  String toString() => 'Linha $line: $message';
}

class PerguntaParser {
  /// Analisa o texto seguindo a gramática:
  /// Perguntas ::= Pergunta { Pergunta }
  /// Pergunta  ::= \p [ "(" Num [, NumSeg] ")" ] Texto Alts
  /// Alts      ::= Alt { NovaLinha Alt }
  /// Alt       ::= [ * ] \i Texto
  static List<Pergunta> parse(String content, int defaultDuration) {
    duracaoTotalQuestionario = 0;

    content = content.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    if (content.trim().isEmpty) {
      throw ParseException(1, 'O arquivo selecionado está vazio.');
    }

    final rawLines = content.split(RegExp(r'\r?\n'));
    final List<Pergunta> perguntas = [];

    int i = 0;
    final totalLines = rawLines.length;

    // Ignora linhas em branco iniciais
    while (i < totalLines && rawLines[i].trim().isEmpty) {
      i++;
    }

    if (i >= totalLines) {
      throw ParseException(1, 'Nenhuma pergunta encontrada no arquivo.');
    }

    while (i < totalLines) {
      // Ignora linhas em branco entre perguntas
      while (i < totalLines && rawLines[i].trim().isEmpty) {
        i++;
      }
      if (i >= totalLines) break;

      final lineNum = i + 1;
      final line = rawLines[i].trim();

      if (!line.startsWith(r'\p')) {
        throw ParseException(
          lineNum,
          'Esperado "\\p" para iniciar uma pergunta, mas foi encontrado: "$line"',
        );
      }

      // Processa o cabeçalho \p [ "(" Num [, NumSeg] ")" ]
      String afterP = line.substring(2).trim();
      double value = 10.0;
      int duration = defaultDuration;
      bool hasSpecifiedDuration = false;
      String questionFirstLine = '';

      if (afterP.startsWith('(')) {
        final closeParenIdx = afterP.indexOf(')');
        if (closeParenIdx == -1) {
          throw ParseException(
            lineNum,
            'Esperado ")" para fechar os parâmetros da pergunta.',
          );
        }

        final paramsStr = afterP.substring(1, closeParenIdx).trim();
        questionFirstLine = afterP.substring(closeParenIdx + 1).trim();

        if (paramsStr.isEmpty) {
          throw ParseException(
            lineNum,
            'Os parâmetros dentro de "(...)" não podem estar vazios.',
          );
        }

        final parts = paramsStr.split(',');
        if (parts.length > 2) {
          throw ParseException(
            lineNum,
            'Muitos parâmetros em "($paramsStr)". Esperado: (Num [, NumSeg]).',
          );
        }

        // Leitura de Num (real)
        final parsedValue = double.tryParse(parts[0].trim());
        if (parsedValue == null) {
          throw ParseException(
            lineNum,
            'Valor da questão inválido: "${parts[0].trim()}" não é um número real.',
          );
        }
        value = parsedValue;

        // Leitura de NumSeg (inteiro, opcional)
        if (parts.length == 2) {
          final parsedDur = int.tryParse(parts[1].trim());
          if (parsedDur == null || parsedDur <= 0) {
            throw ParseException(
              lineNum,
              'Duração da questão inválida: "${parts[1].trim()}" deve ser um número inteiro positivo.',
            );
          }
          duration = parsedDur;
          hasSpecifiedDuration = true;
        }
      } else {
        questionFirstLine = afterP;
      }

      final questionBuffer = StringBuffer();
      if (questionFirstLine.isNotEmpty) {
        questionBuffer.writeln(questionFirstLine);
      }

      i++; // Avança a linha do \p

      // Coleta o texto da pergunta até o primeiro \i
      while (i < totalLines) {
        final currentLine = rawLines[i];
        var trimmed = currentLine.trim();

        // uma linha de opção, que começa com \i, pode ser precedida por um único *
        // que indica a resposta correta. Elimine este *
        if (trimmed.startsWith('*')) {
          // elimine este * e continue a análise
          trimmed = trimmed.substring(1).trim();
        }

        if (trimmed.startsWith(r'\i')) {
          break;
        }
        if (trimmed.startsWith(r'\p')) {
          throw ParseException(
            i + 1,
            'Nova pergunta iniciada sem que a pergunta anterior tivesse alternativas (esperado "\\i").',
          );
        }
        questionBuffer.writeln(currentLine);
        i++;
      }

      final questionText = questionBuffer.toString().trim();
      if (questionText.isEmpty) {
        throw ParseException(
          lineNum,
          'O enunciado da pergunta não pode ser vazio.',
        );
      }

      if (i >= totalLines ||
          !RegExp(r'^\*?\s*\\i').hasMatch(rawLines[i].trim())) {
        throw ParseException(
          i < totalLines ? i + 1 : totalLines,
          'A pergunta não possui alternativas (esperado "\\i").',
        );
      }

      // Coleta as alternativas da pergunta
      final List<QuestionOption> options = [];
      int optionIndex = 0;

      var correctAnswerIndex = -1;

      while (i < totalLines) {
        final currentLine = rawLines[i];
        final trimmed = currentLine.trim();

        if (trimmed.startsWith(r'\p')) {
          break; // Início da próxima pergunta
        }

        bool isCorrectAnswer = trimmed.startsWith('*');
        final optionMatch = RegExp(r'^\*?\s*\\i').matchAsPrefix(trimmed);
        if (optionMatch != null) {
          final optLineNum = i + 1;
          final optFirstLine = trimmed.substring(optionMatch.end).trim();
          final optBuffer = StringBuffer();

          if (optFirstLine.isNotEmpty) {
            optBuffer.writeln(optFirstLine);
          }
          i++;

          // Coleta linhas subsequentes da alternativa até o próximo \i ou \p
          while (i < totalLines) {
            final nextLine = rawLines[i];
            final nextTrimmed = nextLine.trim();
            if (RegExp(r'^\*?\s*\\i').hasMatch(nextTrimmed) ||
                nextTrimmed.startsWith(r'\p')) {
              break;
            }
            optBuffer.writeln(nextLine);
            i++;
          }

          var optText = optBuffer.toString().trim();

          if (optText.isEmpty) {
            throw ParseException(
              optLineNum,
              'O texto da alternativa não pode ser vazio.',
            );
          }

          if (isCorrectAnswer) {
            correctAnswerIndex = optionIndex;
          }

          final letter = String.fromCharCode('a'.codeUnitAt(0) + optionIndex);
          options.add(QuestionOption(letter: letter, option: optText));
          optionIndex++;
        } else if (trimmed.isEmpty) {
          i++;
        } else {
          throw ParseException(
            i + 1,
            'Conteúdo inesperado fora de uma alternativa ou pergunta: "$trimmed"',
          );
        }
      }

      if (options.isEmpty) {
        throw ParseException(
          lineNum,
          'A pergunta deve ter pelo menos uma alternativa iniciada com "\\i".',
        );
      }
      var novaPergunta = Pergunta(
        question: questionText,
        number: perguntas.length + 1,
        optionList: options,
        value: value,
        duration: duration,
        hasSpecifiedDuration: hasSpecifiedDuration,
        correctAnswerIndex: correctAnswerIndex,
      );
      duracaoTotalQuestionario += duration;
      perguntas.add(novaPergunta);
    }

    return perguntas;
  }
}

// ==========================================
// APLICAÇÃO PRINCIPAL
// ==========================================

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  double _fontScale = 1.3;
  Color _seedColor = Colors.indigo;

  TextStyle? scaleTextStyle(TextStyle? style) {
    if (style == null) return null;
    return style.copyWith(fontSize: (style.fontSize ?? 14) * _fontScale);
  }

  TextTheme scaleTextTheme(TextTheme textTheme) {
    return TextTheme(
      displayLarge: scaleTextStyle(textTheme.displayLarge),
      displayMedium: scaleTextStyle(textTheme.displayMedium),
      displaySmall: scaleTextStyle(textTheme.displaySmall),
      headlineLarge: scaleTextStyle(textTheme.headlineLarge),
      headlineMedium: scaleTextStyle(textTheme.headlineMedium),
      headlineSmall: scaleTextStyle(textTheme.headlineSmall),
      titleLarge: scaleTextStyle(textTheme.titleLarge),
      titleMedium: scaleTextStyle(textTheme.titleMedium),
      titleSmall: scaleTextStyle(textTheme.titleSmall),
      bodyLarge: scaleTextStyle(textTheme.bodyLarge),
      bodyMedium: scaleTextStyle(textTheme.bodyMedium),
      bodySmall: scaleTextStyle(textTheme.bodySmall),
      labelLarge: scaleTextStyle(textTheme.labelLarge),
      labelMedium: scaleTextStyle(textTheme.labelMedium),
      labelSmall: scaleTextStyle(textTheme.labelSmall),
    );
  }

  void _setFontScale(double fontScale) {
    setState(() => _fontScale = fontScale);
  }

  void _setSeedColor(Color seedColor) {
    setState(() => _seedColor = seedColor);
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seedColor,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );

    return AppSettings(
      fontScale: _fontScale,
      seedColor: _seedColor,
      onFontScaleChanged: _setFontScale,
      onSeedColorChanged: _setSeedColor,
      child: MaterialApp(
        title: 'Apresentador de Perguntas',
        debugShowCheckedModeBanner: false,
        theme: baseTheme.copyWith(
          textTheme: scaleTextTheme(baseTheme.textTheme),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class AppSettings extends InheritedWidget {
  final double fontScale;
  final Color seedColor;
  final ValueChanged<double> onFontScaleChanged;
  final ValueChanged<Color> onSeedColorChanged;

  const AppSettings({
    super.key,
    required this.fontScale,
    required this.seedColor,
    required this.onFontScaleChanged,
    required this.onSeedColorChanged,
    required super.child,
  });

  static AppSettings of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppSettings>()!;
  }

  @override
  bool updateShouldNotify(AppSettings oldWidget) {
    return fontScale != oldWidget.fontScale || seedColor != oldWidget.seedColor;
  }
}

// ==========================================
// TELA INICIAL
// ==========================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _intervalController = TextEditingController(
    text: '$defaultIntervalSeconds',
  );

  List<Pergunta>? _perguntas;
  String? _loadedFileName;
  bool _isLoading = false;

  @override
  void dispose() {
    _intervalController.dispose();
    super.dispose();
  }

  int get _intervalSeconds {
    final val = int.tryParse(_intervalController.text.trim());
    return (val != null && val > 0) ? val : defaultIntervalSeconds;
  }

  // Escreve 'filename-respostas.txt' ao lado do arquivo original, com a letra correta de cada questão
  Future<void> _writeAnswersFile(
    PlatformFile file,
    List<Pergunta> parsed,
  ) async {
    final originalPath = file.path;
    if (originalPath == null) return;

    final directory = originalPath.substring(
      0,
      originalPath.length - file.name.length,
    );
    final baseName = file.name.toLowerCase().endsWith('.txt')
        ? file.name.substring(0, file.name.length - 4)
        : file.name;
    final answersPath = '$directory$baseName-respostas.txt';

    final buffer = StringBuffer();
    for (final pergunta in parsed) {
      buffer.writeln('${pergunta.number}. ${pergunta.correctAnswerLetter}');
    }

    await File(answersPath).writeAsString(buffer.toString(), encoding: utf8);
  }

  Future<void> _pickAndParseFile() async {
    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      final file = result.files.first;
      if (file.bytes == null) {
        throw Exception(
          'Não foi possível ler os bytes do arquivo selecionado.',
        );
      }

      // Decodificação garantida em UTF-8
      final content = utf8.decode(file.bytes!);

      // Executa a análise sintática
      final parsed = PerguntaParser.parse(content, _intervalSeconds);

      await _writeAnswersFile(file, parsed);

      setState(() {
        _perguntas = parsed;
        _loadedFileName = file.name;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Arquivo "${file.name}" carregado com sucesso (${parsed.length} perguntas)!',
            ),
            backgroundColor: Theme.of(context).colorScheme.tertiary,
          ),
        );
      }
    } on ParseException catch (e) {
      setState(() {
        _perguntas = null;
        _loadedFileName = null;
      });
      if (mounted) {
        _showErrorDialog('Erro de Sintaxe', 'Linha ${e.line}:\n${e.message}');
      }
    } catch (e) {
      setState(() {
        _perguntas = null;
        _loadedFileName = null;
      });
      if (mounted) {
        _showErrorDialog('Erro ao Ler Arquivo', e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
          size: 40,
        ),
        title: Text(title),
        content: SelectableText(message, style: const TextStyle(fontSize: 15)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  void _startQuiz() {
    if (_perguntas == null || _perguntas!.isEmpty) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => QuestionPlayerScreen(
          perguntas: _perguntas!,
          defaultDuration: _intervalSeconds,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool canPlay = _perguntas != null && _perguntas!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuração de Questões'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: _isLoading ? null : _pickAndParseFile,
                      icon: const Icon(Icons.file_open),
                      label: const Text('Escolha o arquivo com perguntas'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_loadedFileName != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .tertiaryContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '$_loadedFileName (${_perguntas!.length} questões)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onTertiaryContainer,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _intervalController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Intervalo (segundos)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.timer_outlined),
                        // helperText: 'Padrão caso a questão não defina NumSeg',
                      ),
                    ),
                    const SizedBox(height: 32),
                    Center(
                      child: IconButton.filled(
                        iconSize: 48,
                        padding: const EdgeInsets.all(16),
                        icon: const Icon(Icons.play_arrow),
                        onPressed: canPlay ? _startQuiz : null,
                        tooltip: canPlay
                            ? 'Iniciar Apresentação'
                            : 'Selecione um arquivo válido para liberar o play',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// WIDGET RENDERIZADOR DE MARKDOWN + LATEX
// ==========================================

class MarkdownLatexText extends StatelessWidget {
  final String text;
  final TextStyle? baseTextStyle;

  const MarkdownLatexText({super.key, required this.text, this.baseTextStyle});

  @override
  Widget build(BuildContext context) {
    final style = baseTextStyle ?? Theme.of(context).textTheme.bodyLarge!;
    final codeStyle = style.copyWith(
      fontSize: style.fontSize! * 1.1,
      fontWeight: FontWeight.w600,
    );

    return MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
          .copyWith(p: style, code: codeStyle),
      builders: {'latex': LatexElementBuilder(textStyle: style)},
      extensionSet: md.ExtensionSet(
        [LatexBlockSyntax()],
        [LatexInlineSyntax()],
      ),
    );
  }
}

// ==========================================
// TELA DO REPRODUTOR DE PERGUNTAS
// ==========================================

class QuestionPlayerScreen extends StatefulWidget {
  final List<Pergunta> perguntas;
  final int defaultDuration;

  const QuestionPlayerScreen({
    super.key,
    required this.perguntas,
    required this.defaultDuration,
  });

  @override
  State<QuestionPlayerScreen> createState() => _QuestionPlayerScreenState();
}

class _QuestionPlayerScreenState extends State<QuestionPlayerScreen> {
  final FocusNode _focusNode = FocusNode();

  int _currentIndex = 0;
  late int _remainingSeconds;
  late int _totalDuration;
  bool _isPaused = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadQuestion(_currentIndex);
    _startTimer();
  }

  void _showFontSizePicker() {
    final settings = AppSettings.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Tamanho da fonte')),
            for (final option in const [
              (label: 'Pequena', value: 1.0),
              (label: 'Normal', value: 1.2),
              (label: 'Grande', value: 1.4),
              (label: 'Muito grande', value: 1.8),
            ])
              RadioGroup<double>(
                groupValue: settings.fontScale,
                onChanged: (value) {
                  if (value != null) {
                    settings.onFontScaleChanged(value);
                    Navigator.of(sheetContext).pop();
                  }
                },
                child: RadioListTile<double>(
                  title: Text(option.label),
                  value: option.value,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showThemePicker() {
    final settings = AppSettings.of(context);
    var colors = [
      Colors.pink,
      Colors.red.shade800,
      Colors.red.shade500,
      Colors.red.shade300,
      Colors.deepPurple,
      Colors.purple.shade300,
      Colors.purple.shade600,
      Colors.indigo,
      Colors.lightBlueAccent,
      Colors.blue,
      Colors.teal,
      Colors.tealAccent,
      Colors.green,
      Colors.amberAccent,
      Colors.lime,
      Colors.orange,
      Colors.deepOrange,
      Colors.brown,
      Colors.brown.shade300,
    ];

    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              const SizedBox(
                width: double.infinity,
                child: Text(
                  'Cor do tema',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              for (final color in colors)
                IconButton(
                  tooltip: 'Selecionar tema',
                  icon: Icon(
                    Icons.circle,
                    color: color,
                    size: settings.seedColor == color ? 38 : 32,
                  ),
                  onPressed: () {
                    settings.onSeedColorChanged(color);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _loadQuestion(int index) {
    final current = widget.perguntas[index];
    _totalDuration =
        current.hasSpecifiedDuration == true && current.duration != null
        ? current.duration!
        : widget.defaultDuration;
    _remainingSeconds = _totalDuration;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isPaused) {
        if (_remainingSeconds > 0) {
          setState(() {
            _remainingSeconds--;
          });
        } else {
          _advanceQuestion();
        }
      }
    });
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });
  }

  void _advanceQuestion() {
    if (_currentIndex + 1 < widget.perguntas.length) {
      setState(() {
        _currentIndex++;
        _loadQuestion(_currentIndex);
      });
    } else {
      _timer?.cancel();
      _showCompletionDialog();
    }
  }

  void _goToPreviousQuestion() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _loadQuestion(_currentIndex);
      });
    }
  }

  void _showCompletionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.tertiary,
          size: 48,
        ),
        title: const Text('Fim das Questões!'),
        content: const Text('Todas as perguntas foram apresentadas.'),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: const Text('Voltar ao Início'),
          ),
        ],
      ),
    );
  }

  String _formatSeconds(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.of(context);
    final current = widget.perguntas[_currentIndex];
    final progress = _totalDuration > 0
        ? (_remainingSeconds / _totalDuration).clamp(0.0, 1.0)
        : 0.0;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.space) {
            _togglePause();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _isPaused = true;
            _goToPreviousQuestion();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _isPaused = true;
            _advanceQuestion();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Questão ${_currentIndex + 1} de ${widget.perguntas.length}',
              ),
              Text('Tempo total: ${_formatSeconds(duracaoTotalQuestionario)}'),
            ],
          ),
        ),
        body: Column(
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
              color: progress < 0.25
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).primaryColor,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10.0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Card de Cabeçalho com Valor e Tempo
                        Card(
                          color: _isPaused
                              ? Theme.of(context).colorScheme.secondaryContainer
                                    .withValues(alpha: 0.35)
                              : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                              vertical: 12.0,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Chip(
                                        avatar: const Icon(
                                          Icons.star_outline,
                                          size: 18,
                                        ),
                                        label: Text('Valor: ${current.value}'),
                                      ),
                                    ),
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      padding: EdgeInsets.zero,
                                      iconSize: 22,
                                      icon: const Icon(
                                        Icons.arrow_back,
                                        size: 40,
                                      ),
                                      tooltip: 'Questão anterior',
                                      onPressed: _currentIndex > 0
                                          ? _goToPreviousQuestion
                                          : null,
                                    ),
                                    const SizedBox(width: 10),
                                    IconButton(
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      padding: EdgeInsets.zero,
                                      iconSize: 22,
                                      icon: Icon(
                                        _isPaused
                                            ? Icons.play_arrow
                                            : Icons.pause,
                                        size: 40,
                                      ),
                                      tooltip: _isPaused
                                          ? 'Continuar (Espaço)'
                                          : 'Pausar (Espaço)',
                                      onPressed: _togglePause,
                                    ),
                                    const SizedBox(width: 10),

                                    IconButton(
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      padding: EdgeInsets.zero,
                                      iconSize: 22,
                                      icon: const Icon(
                                        Icons.arrow_forward,
                                        size: 40,
                                      ),
                                      tooltip: 'Próxima questão',
                                      onPressed: _advanceQuestion,
                                    ),
                                  ],
                                ),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Chip(
                                        avatar: const Icon(
                                          Icons.timer_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          _formatSeconds(_remainingSeconds),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Enunciado da Pergunta
                        Card(
                          elevation: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(10.0),
                            child: MarkdownLatexText(
                              text: '${current.number}\\. ${current.question}',
                              baseTextStyle: TextStyle(
                                fontSize: 18 * settings.fontScale,
                                fontWeight: FontWeight.w600,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Lista de Alternativas
                        if (current.optionList != null)
                          ...current.optionList!.map((opt) {
                            return Card(
                              margin: const EdgeInsets.only(bottom: 12.0),
                              child: Padding(
                                padding: const EdgeInsets.all(10.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 16,
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      child: Text(
                                        opt.letter.toUpperCase(),
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: MarkdownLatexText(
                                        text: opt.option,
                                        baseTextStyle: TextStyle(
                                          fontSize: 20 * settings.fontScale,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.text_fields),
              label: 'Font Size',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.palette_outlined),
              label: 'Theme',
            ),
          ],
          onTap: (index) {
            if (index == 0) {
              _showFontSizePicker();
            } else {
              _showThemePicker();
            }
          },
        ),
      ),
    );
  }
}
