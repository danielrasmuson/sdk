// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library analyzer.src.task.html;

import 'dart:collection';

import 'package:analyzer/src/generated/engine.dart' hide AnalysisTask;
import 'package:analyzer/src/generated/error.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/task/dart.dart';
import 'package:analyzer/src/task/general.dart';
import 'package:analyzer/task/dart.dart';
import 'package:analyzer/task/general.dart';
import 'package:analyzer/task/html.dart';
import 'package:analyzer/task/model.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:source_span/source_span.dart';
import 'package:analyzer/src/context/cache.dart';
import 'package:analyzer/src/generated/java_engine.dart';
import 'package:analyzer/src/generated/scanner.dart';

/**
 * The Dart scripts that are embedded in an HTML file.
 */
final ListResultDescriptor<DartScript> DART_SCRIPTS =
    new ListResultDescriptor<DartScript>('DART_SCRIPTS', DartScript.EMPTY_LIST);

/**
 * The errors found while parsing an HTML file.
 */
final ListResultDescriptor<AnalysisError> HTML_DOCUMENT_ERRORS =
    new ListResultDescriptor<AnalysisError>(
        'HTML_DOCUMENT_ERRORS', AnalysisError.NO_ERRORS);

/**
 * A Dart script that is embedded in an HTML file.
 */
class DartScript implements Source {
  /**
   * An empty list of scripts.
   */
  static final List<DartScript> EMPTY_LIST = <DartScript>[];

  /**
   * The source containing this script.
   */
  final Source source;

  /**
   * The fragments that comprise this content of the script.
   */
  final List<ScriptFragment> fragments;

  /**
   * Initialize a newly created script in the given [source] that is composed of
   * given [fragments].
   */
  DartScript(this.source, this.fragments);

  @override
  TimestampedData<String> get contents =>
      new TimestampedData(modificationStamp, fragments[0].content);

  @override
  String get encoding => source.encoding;

  @override
  String get fullName => source.fullName;

  @override
  bool get isInSystemLibrary => source.isInSystemLibrary;

  @override
  int get modificationStamp => source.modificationStamp;

  @override
  String get shortName => source.shortName;

  @override
  Uri get uri => throw new StateError('uri not supported for scripts');

  @override
  UriKind get uriKind =>
      throw new StateError('uriKind not supported for scripts');

  @override
  bool exists() => source.exists();

  @override
  Uri resolveRelativeUri(Uri relativeUri) =>
      throw new StateError('resolveRelativeUri not supported for scripts');
}

/**
 * A task that looks for Dart scripts in an HTML file and computes both the Dart
 * libraries that are referenced by those scripts and the embedded Dart scripts.
 */
class DartScriptsTask extends SourceBasedAnalysisTask {
  /**
   * The name of the [HTML_DOCUMENT] input.
   */
  static const String DOCUMENT_INPUT = 'DOCUMENT';

  /**
   * The task descriptor describing this kind of task.
   */
  static final TaskDescriptor DESCRIPTOR = new TaskDescriptor('DartScriptsTask',
      createTask, buildInputs, <ResultDescriptor>[
    DART_SCRIPTS,
    REFERENCED_LIBRARIES
  ]);

  DartScriptsTask(InternalAnalysisContext context, AnalysisTarget target)
      : super(context, target);

  @override
  TaskDescriptor get descriptor => DESCRIPTOR;

  @override
  void internalPerform() {
    //
    // Prepare inputs.
    //
    Source source = target.source;
    Document document = getRequiredInput(DOCUMENT_INPUT);
    //
    // Process the script tags.
    //
    List<Source> libraries = <Source>[];
    List<DartScript> inlineScripts = <DartScript>[];
    List<Element> scripts = document.getElementsByTagName('script');
    for (Element script in scripts) {
      LinkedHashMap<dynamic, String> attributes = script.attributes;
      if (attributes['type'] == 'application/dart') {
        String src = attributes['src'];
        if (src == null) {
          if (script.hasContent()) {
            List<ScriptFragment> fragments = <ScriptFragment>[];
            for (Node node in script.nodes) {
              if (node.nodeType == Node.TEXT_NODE) {
                FileLocation start = node.sourceSpan.start;
                fragments.add(new ScriptFragment(start.offset, start.line,
                    start.column, (node as Text).data));
              }
            }
            inlineScripts.add(new DartScript(source, fragments));
          }
        } else if (AnalysisEngine.isDartFileName(src)) {
          Source source = context.sourceFactory.resolveUri(target.source, src);
          if (source != null) {
            libraries.add(source);
          }
        }
      }
    }
    //
    // Record outputs.
    //
    outputs[REFERENCED_LIBRARIES] =
        libraries.isEmpty ? Source.EMPTY_LIST : libraries;
    outputs[DART_SCRIPTS] =
        inlineScripts.isEmpty ? DartScript.EMPTY_LIST : inlineScripts;
  }

  /**
   * Return a map from the names of the inputs of this kind of task to the task
   * input descriptors describing those inputs for a task with the
   * given [target].
   */
  static Map<String, TaskInput> buildInputs(Source target) {
    return <String, TaskInput>{DOCUMENT_INPUT: HTML_DOCUMENT.of(target)};
  }

  /**
   * Create a [DartScriptsTask] based on the given [target] in the given
   * [context].
   */
  static DartScriptsTask createTask(
      AnalysisContext context, AnalysisTarget target) {
    return new DartScriptsTask(context, target);
  }
}

/**
 * A task that merges all of the errors for a single source into a single list
 * of errors.
 */
class HtmlErrorsTask extends SourceBasedAnalysisTask {
  /**
   * The name of the input that is a list of errors from each of the embedded
   * Dart scripts.
   */
  static const String DART_ERRORS_INPUT = 'DART_ERRORS';

  /**
   * The name of the [HTML_DOCUMENT_ERRORS] input.
   */
  static const String DOCUMENT_ERRORS_INPUT = 'DOCUMENT_ERRORS';

  /**
   * The task descriptor describing this kind of task.
   */
  static final TaskDescriptor DESCRIPTOR = new TaskDescriptor('HtmlErrorsTask',
      createTask, buildInputs, <ResultDescriptor>[HTML_ERRORS]);

  HtmlErrorsTask(InternalAnalysisContext context, AnalysisTarget target)
      : super(context, target);

  @override
  TaskDescriptor get descriptor => DESCRIPTOR;

  @override
  void internalPerform() {
    //
    // Prepare inputs.
    //
    List<List<AnalysisError>> dartErrors = getRequiredInput(DART_ERRORS_INPUT);
    List<AnalysisError> documentErrors =
        getRequiredInput(DOCUMENT_ERRORS_INPUT);
    //
    // Compute the error list.
    //
    List<AnalysisError> errors = <AnalysisError>[];
    errors.addAll(documentErrors);
    for (List<AnalysisError> scriptErrors in dartErrors) {
      errors.addAll(scriptErrors);
    }
    //
    // Record outputs.
    //
    outputs[HTML_ERRORS] = removeDuplicateErrors(errors);
  }

  /**
   * Return a map from the names of the inputs of this kind of task to the task
   * input descriptors describing those inputs for a task with the
   * given [target].
   */
  static Map<String, TaskInput> buildInputs(Source target) {
    return <String, TaskInput>{
      DOCUMENT_ERRORS_INPUT: HTML_DOCUMENT_ERRORS.of(target),
      DART_ERRORS_INPUT: DART_SCRIPTS.of(target).toListOf(DART_ERRORS)
    };
  }

  /**
   * Create an [HtmlErrorsTask] based on the given [target] in the given
   * [context].
   */
  static HtmlErrorsTask createTask(
      AnalysisContext context, AnalysisTarget target) {
    return new HtmlErrorsTask(context, target);
  }
}

/**
 * A task that scans the content of a file, producing a set of Dart tokens.
 */
class ParseHtmlTask extends SourceBasedAnalysisTask {
  /**
   * The name of the input whose value is the content of the file.
   */
  static const String CONTENT_INPUT_NAME = 'CONTENT_INPUT_NAME';

  /**
   * The task descriptor describing this kind of task.
   */
  static final TaskDescriptor DESCRIPTOR = new TaskDescriptor('ParseHtmlTask',
      createTask, buildInputs, <ResultDescriptor>[
    HTML_DOCUMENT,
    HTML_DOCUMENT_ERRORS
  ]);

  /**
   * Initialize a newly created task to access the content of the source
   * associated with the given [target] in the given [context].
   */
  ParseHtmlTask(InternalAnalysisContext context, AnalysisTarget target)
      : super(context, target);

  @override
  TaskDescriptor get descriptor => DESCRIPTOR;

  @override
  void internalPerform() {
    String content = getRequiredInput(CONTENT_INPUT_NAME);

    if (context.getModificationStamp(target.source) < 0) {
      String message = 'Content could not be read';
      if (context is InternalAnalysisContext) {
        CacheEntry entry = (context as InternalAnalysisContext).getCacheEntry(target);
        CaughtException exception = entry.exception;
        if (exception != null) {
          message = exception.toString();
        }
      }

      outputs[HTML_DOCUMENT] = new Document();
      outputs[HTML_DOCUMENT_ERRORS] = <AnalysisError>[new AnalysisError(
          target.source, 0, 0, ScannerErrorCode.UNABLE_GET_CONTENT, [message])];
    } else {
      HtmlParser parser = new HtmlParser(content, generateSpans: true);
      parser.compatMode = 'quirks';
      Document document = parser.parse();
      List<ParseError> parseErrors = parser.errors;
      List<AnalysisError> errors = <AnalysisError>[];
      for (ParseError parseError in parseErrors) {
        SourceSpan span = parseError.span;
        errors.add(new AnalysisError(target.source, span.start.offset,
            span.length, HtmlErrorCode.PARSE_ERROR, [parseError.message]));
      }

      outputs[HTML_DOCUMENT] = document;
      outputs[HTML_DOCUMENT_ERRORS] = errors;
    }
  }

  /**
   * Return a map from the names of the inputs of this kind of task to the task
   * input descriptors describing those inputs for a task with the given
   * [source].
   */
  static Map<String, TaskInput> buildInputs(Source source) {
    return <String, TaskInput>{CONTENT_INPUT_NAME: CONTENT.of(source)};
  }

  /**
   * Create a [ParseHtmlTask] based on the given [target] in the given [context].
   */
  static ParseHtmlTask createTask(
      AnalysisContext context, AnalysisTarget target) {
    return new ParseHtmlTask(context, target);
  }
}

/**
 * A fragment of a [DartScript].
 */
class ScriptFragment {
  /**
   * The offset of the first character of the fragment, relative to the start of
   * the containing source.
   */
  final int offset;

  /**
   * The line number of the line containing the first character of the fragment.
   */
  final int line;

  /**
   * The column number of the line containing the first character of the
   * fragment.
   */
  final int column;

  /**
   * The content of the fragment.
   */
  final String content;

  /**
   * Initialize a newly created script fragment to have the given [offset] and
   * [content].
   */
  ScriptFragment(this.offset, this.line, this.column, this.content);
}
