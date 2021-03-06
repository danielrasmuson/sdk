// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.src.refactoring.inline_method;

import 'dart:async';

import 'package:analysis_server/src/protocol_server.dart' hide Element;
import 'package:analysis_server/src/services/correction/source_range.dart';
import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/correction/strings.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/services/refactoring/refactoring.dart';
import 'package:analysis_server/src/services/refactoring/refactoring_internal.dart';
import 'package:analysis_server/src/services/search/element_visitors.dart';
import 'package:analysis_server/src/services/search/hierarchy.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/utilities_dart.dart';

/**
 * Returns the [SourceRange] to find conflicting locals in.
 */
SourceRange _getLocalsConflictingRange(AstNode node) {
  // maybe Block
  Block block = node.getAncestor((node) => node is Block);
  if (block != null) {
    int offset = node.offset;
    int endOffset = block.end;
    return rangeStartEnd(offset, endOffset);
  }
  // maybe whole executable
  AstNode executableNode = getEnclosingExecutableNode(node);
  if (executableNode != null) {
    return rangeNode(executableNode);
  }
  // not a part of a declaration with locals
  return SourceRange.EMPTY;
}

/**
 * Returns the source which should replace given invocation with given
 * arguments.
 */
String _getMethodSourceForInvocation(RefactoringStatus status, _SourcePart part,
    CorrectionUtils utils, AstNode contextNode, Expression targetExpression,
    List<Expression> arguments) {
  // prepare edits to replace parameters with arguments
  List<SourceEdit> edits = <SourceEdit>[];
  part._parameters.forEach((ParameterElement parameter,
      List<_ParameterOccurrence> occurrences) {
    // prepare argument
    Expression argument = null;
    for (Expression arg in arguments) {
      if (arg.bestParameterElement == parameter) {
        argument = arg;
        break;
      }
    }
    if (argument is NamedExpression) {
      argument = (argument as NamedExpression).expression;
    }
    // prepare argument properties
    int argumentPrecedence;
    String argumentSource;
    if (argument != null) {
      argumentPrecedence = getExpressionPrecedence(argument);
      argumentSource = utils.getNodeText(argument);
    } else {
      // report about a missing required parameter
      if (parameter.parameterKind == ParameterKind.REQUIRED) {
        status.addError('No argument for the parameter "${parameter.name}".',
            newLocation_fromNode(contextNode));
        return;
      }
      // an optional parameter
      argumentPrecedence = -1000;
      argumentSource = parameter.defaultValueCode;
      if (argumentSource == null) {
        argumentSource = 'null';
      }
    }
    // replace all occurrences of this parameter
    for (_ParameterOccurrence occurrence in occurrences) {
      SourceRange range = occurrence.range;
      // prepare argument source to apply at this occurrence
      String occurrenceArgumentSource;
      if (argumentPrecedence < occurrence.parentPrecedence) {
        occurrenceArgumentSource = "($argumentSource)";
      } else {
        occurrenceArgumentSource = argumentSource;
      }
      // do replace
      edits.add(newSourceEdit_range(range, occurrenceArgumentSource));
    }
  });
  // replace static field "qualifier" with invocation target
  part._staticFieldOffsets.forEach((String className, List<int> offsets) {
    for (int offset in offsets) {
//      edits.add(newSourceEdit_range(range, className + '.'));
      edits.add(new SourceEdit(offset, 0, className + '.'));
    }
  });
  // replace "this" references with invocation target
  if (targetExpression != null) {
    String targetSource = utils.getNodeText(targetExpression);
    // explicit "this" references
    for (int offset in part._explicitThisOffsets) {
      edits.add(new SourceEdit(offset, 4, targetSource));
    }
    // implicit "this" references
    targetSource += '.';
    for (int offset in part._implicitThisOffsets) {
      edits.add(new SourceEdit(offset, 0, targetSource));
    }
  }
  // prepare edits to replace conflicting variables
  Set<String> conflictingNames = _getNamesConflictingAt(contextNode);
  part._variables.forEach((VariableElement variable, List<SourceRange> ranges) {
    String originalName = variable.displayName;
    // prepare unique name
    String uniqueName;
    {
      uniqueName = originalName;
      int uniqueIndex = 2;
      while (conflictingNames.contains(uniqueName)) {
        uniqueName = originalName + uniqueIndex.toString();
        uniqueIndex++;
      }
    }
    // update references, if name was change
    if (uniqueName != originalName) {
      for (SourceRange range in ranges) {
        edits.add(newSourceEdit_range(range, uniqueName));
      }
    }
  });
  // prepare source with applied arguments
  edits.sort((SourceEdit a, SourceEdit b) => b.offset - a.offset);
  return SourceEdit.applySequence(part._source, edits);
}

/**
 * Returns the names which will shadow or will be shadowed by any declaration
 * at [node].
 */
Set<String> _getNamesConflictingAt(AstNode node) {
  Set<String> result = new Set<String>();
  // local variables and functions
  {
    SourceRange localsRange = _getLocalsConflictingRange(node);
    ExecutableElement enclosingExecutable = getEnclosingExecutableElement(node);
    if (enclosingExecutable != null) {
      visitChildren(enclosingExecutable, (element) {
        if (element is LocalElement) {
          SourceRange elementRange = element.visibleRange;
          if (elementRange != null && elementRange.intersects(localsRange)) {
            result.add(element.displayName);
          }
        }
        return true;
      });
    }
  }
  // fields
  {
    ClassElement enclosingClassElement = getEnclosingClassElement(node);
    if (enclosingClassElement != null) {
      Set<ClassElement> elements = new Set<ClassElement>();
      elements.add(enclosingClassElement);
      elements.addAll(getSuperClasses(enclosingClassElement));
      for (ClassElement classElement in elements) {
        List<Element> classMembers = getChildren(classElement);
        for (Element classMemberElement in classMembers) {
          result.add(classMemberElement.displayName);
        }
      }
    }
  }
  // done
  return result;
}

/**
 * [InlineMethodRefactoring] implementation.
 */
class InlineMethodRefactoringImpl extends RefactoringImpl
    implements InlineMethodRefactoring {
  final SearchEngine searchEngine;
  final CompilationUnit unit;
  final int offset;
  CorrectionUtils utils;
  SourceChange change;

  bool isDeclaration = false;
  bool deleteSource = false;
  bool inlineAll = true;

  ExecutableElement _methodElement;
  bool _isAccessor;
  CompilationUnit _methodUnit;
  CorrectionUtils _methodUtils;
  AstNode _methodNode;
  FormalParameterList _methodParameters;
  FunctionBody _methodBody;
  Expression _methodExpression;
  _SourcePart _methodExpressionPart;
  _SourcePart _methodStatementsPart;
  List<_ReferenceProcessor> _referenceProcessors = [];

  InlineMethodRefactoringImpl(this.searchEngine, this.unit, this.offset) {
    utils = new CorrectionUtils(unit);
  }

  @override
  String get className {
    if (_methodElement == null) {
      return null;
    }
    Element classElement = _methodElement.enclosingElement;
    if (classElement is ClassElement) {
      return classElement.displayName;
    }
    return null;
  }

  @override
  String get methodName {
    if (_methodElement == null) {
      return null;
    }
    return _methodElement.displayName;
  }

  @override
  String get refactoringName {
    if (_methodElement is MethodElement) {
      return "Inline Method";
    } else {
      return "Inline Function";
    }
  }

  @override
  Future<RefactoringStatus> checkFinalConditions() {
    change = new SourceChange(refactoringName);
    RefactoringStatus result = new RefactoringStatus();
    // check for compatibility of "deleteSource" and "inlineAll"
    if (deleteSource && !inlineAll) {
      result.addError('All references must be inlined to remove the source.');
    }
    // prepare changes
    for (_ReferenceProcessor processor in _referenceProcessors) {
      processor._process(result);
    }
    // delete method
    if (deleteSource && inlineAll) {
      SourceRange methodRange = rangeNode(_methodNode);
      SourceRange linesRange = _methodUtils.getLinesRange(methodRange);
      doSourceChange_addElementEdit(
          change, _methodElement, newSourceEdit_range(linesRange, ''));
    }
    // done
    return new Future.value(result);
  }

  @override
  Future<RefactoringStatus> checkInitialConditions() async {
    RefactoringStatus result = new RefactoringStatus();
    // prepare method information
    result.addStatus(_prepareMethod());
    if (result.hasFatalError) {
      return new Future.value(result);
    }
    // maybe operator
    if (_methodElement.isOperator) {
      result = new RefactoringStatus.fatal('Cannot inline operator.');
      return new Future.value(result);
    }
    // analyze method body
    result.addStatus(_prepareMethodParts());
    // process references
    List<SearchMatch> references =
        await searchEngine.searchReferences(_methodElement);
    _referenceProcessors.clear();
    for (SearchMatch reference in references) {
      _ReferenceProcessor processor = new _ReferenceProcessor(this, reference);
      _referenceProcessors.add(processor);
    }
    return result;
  }

  @override
  Future<SourceChange> createChange() {
    return new Future.value(change);
  }

  @override
  bool requiresPreview() => false;

  _SourcePart _createSourcePart(SourceRange range) {
    String source = _methodUtils.getRangeText(range);
    String prefix = getLinePrefix(source);
    _SourcePart result = new _SourcePart(range.offset, source, prefix);
    // remember parameters and variables occurrences
    _methodUnit.accept(new _VariablesVisitor(_methodElement, range, result));
    // done
    return result;
  }

  /**
   * Initializes [_methodElement] and related fields.
   */
  RefactoringStatus _prepareMethod() {
    _methodElement = null;
    _methodParameters = null;
    _methodBody = null;
    deleteSource = false;
    inlineAll = false;
    // prepare for failure
    RefactoringStatus fatalStatus = new RefactoringStatus.fatal(
        'Method declaration or reference must be selected to activate this refactoring.');
    // prepare selected SimpleIdentifier
    AstNode node = new NodeLocator(offset).searchWithin(unit);
    if (node is! SimpleIdentifier) {
      return fatalStatus;
    }
    SimpleIdentifier identifier = node as SimpleIdentifier;
    // prepare selected ExecutableElement
    Element element = identifier.bestElement;
    if (element is! ExecutableElement) {
      return fatalStatus;
    }
    if (element.isSynthetic) {
      return fatalStatus;
    }
    _methodElement = element as ExecutableElement;
    _isAccessor = element is PropertyAccessorElement;
    _methodUnit = element.unit;
    _methodUtils = new CorrectionUtils(_methodUnit);
    // class member
    bool isClassMember = element.enclosingElement is ClassElement;
    if (element is MethodElement || _isAccessor && isClassMember) {
      MethodDeclaration methodDeclaration = element.computeNode();
      _methodNode = methodDeclaration;
      _methodParameters = methodDeclaration.parameters;
      _methodBody = methodDeclaration.body;
      // prepare mode
      isDeclaration = node == methodDeclaration.name;
      deleteSource = isDeclaration;
      inlineAll = deleteSource;
      return new RefactoringStatus();
    }
    // unit member
    bool isUnitMember = element.enclosingElement is CompilationUnitElement;
    if (element is FunctionElement || _isAccessor && isUnitMember) {
      FunctionDeclaration functionDeclaration = element.computeNode();
      _methodNode = functionDeclaration;
      _methodParameters = functionDeclaration.functionExpression.parameters;
      _methodBody = functionDeclaration.functionExpression.body;
      // prepare mode
      isDeclaration = node == functionDeclaration.name;
      deleteSource = isDeclaration;
      inlineAll = deleteSource;
      return new RefactoringStatus();
    }
    // OK
    return fatalStatus;
  }

  /**
   * Analyze [_methodBody] to fill [_methodExpressionPart] and
   * [_methodStatementsPart].
   */
  RefactoringStatus _prepareMethodParts() {
    RefactoringStatus result = new RefactoringStatus();
    if (_methodBody is ExpressionFunctionBody) {
      ExpressionFunctionBody body = _methodBody as ExpressionFunctionBody;
      _methodExpression = body.expression;
      SourceRange methodExpressionRange = rangeNode(_methodExpression);
      _methodExpressionPart = _createSourcePart(methodExpressionRange);
    } else if (_methodBody is BlockFunctionBody) {
      Block body = (_methodBody as BlockFunctionBody).block;
      List<Statement> statements = body.statements;
      if (statements.length >= 1) {
        Statement lastStatement = statements[statements.length - 1];
        // "return" statement requires special handling
        if (lastStatement is ReturnStatement) {
          _methodExpression = lastStatement.expression;
          SourceRange methodExpressionRange = rangeNode(_methodExpression);
          _methodExpressionPart = _createSourcePart(methodExpressionRange);
          // exclude "return" statement from statements
          statements = statements.sublist(0, statements.length - 1);
        }
        // if there are statements, process them
        if (!statements.isEmpty) {
          SourceRange statementsRange =
              _methodUtils.getLinesRangeStatements(statements);
          _methodStatementsPart = _createSourcePart(statementsRange);
        }
      }
      // check if more than one return
      body.accept(new _ReturnsValidatorVisitor(result));
    } else {
      return new RefactoringStatus.fatal('Cannot inline method without body.');
    }
    return result;
  }
}

class _ParameterOccurrence {
  final int parentPrecedence;
  final SourceRange range;
  _ParameterOccurrence(this.parentPrecedence, this.range);
}

/**
 * Processor for single [SearchMatch] reference to [methodElement].
 */
class _ReferenceProcessor {
  final InlineMethodRefactoringImpl ref;

  Element refElement;
  CorrectionUtils _refUtils;
  SimpleIdentifier _node;
  SourceRange _refLineRange;
  String _refPrefix;

  _ReferenceProcessor(this.ref, SearchMatch reference) {
    refElement = reference.element;
    // prepare CorrectionUtils
    CompilationUnit refUnit = refElement.unit;
    _refUtils = new CorrectionUtils(refUnit);
    // prepare node and environment
    _node = _refUtils.findNode(reference.sourceRange.offset);
    Statement refStatement = _node.getAncestor((node) => node is Statement);
    if (refStatement != null) {
      _refLineRange = _refUtils.getLinesRangeStatements([refStatement]);
      _refPrefix = _refUtils.getNodePrefix(refStatement);
    } else {
      _refLineRange = null;
      _refPrefix = _refUtils.getLinePrefix(_node.offset);
    }
  }

  void _addRefEdit(SourceEdit edit) {
    doSourceChange_addElementEdit(ref.change, refElement, edit);
  }

  bool _canInlineBody(AstNode usage) {
    // no statements, usually just expression
    if (ref._methodStatementsPart == null) {
      // empty method, inline as closure
      if (ref._methodExpressionPart == null) {
        return false;
      }
      // OK, just expression
      return true;
    }
    // analyze point of invocation
    AstNode parent = usage.parent;
    AstNode parent2 = parent.parent;
    // OK, if statement in block
    if (parent is Statement) {
      return parent2 is Block;
    }
    // maybe assignment, in block
    if (parent is AssignmentExpression) {
      AssignmentExpression assignment = parent;
      // inlining setter
      if (assignment.leftHandSide == usage) {
        return parent2 is Statement && parent2.parent is Block;
      }
      // inlining initializer
      return ref._methodExpressionPart != null;
    }
    // maybe value for variable initializer, in block
    if (ref._methodExpressionPart != null) {
      if (parent is VariableDeclaration) {
        if (parent2 is VariableDeclarationList) {
          AstNode parent3 = parent2.parent;
          return parent3 is VariableDeclarationStatement &&
              parent3.parent is Block;
        }
      }
    }
    // not in block, cannot inline body
    return false;
  }

  void _inlineMethodInvocation(RefactoringStatus status, Expression usage,
      bool cascaded, Expression target, List<Expression> arguments) {
    // we don't support cascade
    if (cascaded) {
      status.addError(
          'Cannot inline cascade invocation.', newLocation_fromNode(usage));
    }
    // can we inline method body into "methodUsage" block?
    if (_canInlineBody(usage)) {
      // insert non-return statements
      if (ref._methodStatementsPart != null) {
        // prepare statements source for invocation
        String source = _getMethodSourceForInvocation(status,
            ref._methodStatementsPart, _refUtils, usage, target, arguments);
        source = _refUtils.replaceSourceIndent(
            source, ref._methodStatementsPart._prefix, _refPrefix);
        // do insert
        SourceRange range = rangeStartLength(_refLineRange, 0);
        SourceEdit edit = newSourceEdit_range(range, source);
        _addRefEdit(edit);
      }
      // replace invocation with return expression
      if (ref._methodExpressionPart != null) {
        // prepare expression source for invocation
        String source = _getMethodSourceForInvocation(status,
            ref._methodExpressionPart, _refUtils, usage, target, arguments);
        if (getExpressionPrecedence(ref._methodExpression) <
            getExpressionParentPrecedence(usage)) {
          source = "(${source})";
        }
        // do replace
        SourceRange methodUsageRange = rangeNode(usage);
        SourceEdit edit = newSourceEdit_range(methodUsageRange, source);
        _addRefEdit(edit);
      } else {
        SourceEdit edit = newSourceEdit_range(_refLineRange, "");
        _addRefEdit(edit);
      }
      return;
    }
    // inline as closure invocation
    String source;
    {
      source = ref._methodUtils.getRangeText(rangeStartEnd(
          ref._methodParameters.leftParenthesis, ref._methodNode));
      String methodPrefix =
          ref._methodUtils.getLinePrefix(ref._methodNode.offset);
      source = _refUtils.replaceSourceIndent(source, methodPrefix, _refPrefix);
      source = source.trim();
    }
    // do insert
    SourceRange range = rangeNode(_node);
    SourceEdit edit = newSourceEdit_range(range, source);
    _addRefEdit(edit);
  }

  void _process(RefactoringStatus status) {
    AstNode nodeParent = _node.parent;
    // may be only single place should be inlined
    if (!_shouldProcess()) {
      return;
    }
    // may be invocation of inline method
    if (nodeParent is MethodInvocation) {
      MethodInvocation invocation = nodeParent;
      Expression target = invocation.target;
      List<Expression> arguments = invocation.argumentList.arguments;
      _inlineMethodInvocation(
          status, invocation, invocation.isCascaded, target, arguments);
    } else {
      // cannot inline reference to method: var v = new A().method;
      if (ref._methodElement is MethodElement) {
        status.addFatalError('Cannot inline class method reference.',
            newLocation_fromNode(_node));
        return;
      }
      // PropertyAccessorElement
      if (ref._methodElement is PropertyAccessorElement) {
        Expression usage = _node;
        Expression target = null;
        bool cascade = false;
        if (nodeParent is PrefixedIdentifier) {
          PrefixedIdentifier propertyAccess = nodeParent;
          usage = propertyAccess;
          target = propertyAccess.prefix;
          cascade = false;
        }
        if (nodeParent is PropertyAccess) {
          PropertyAccess propertyAccess = nodeParent;
          usage = propertyAccess;
          target = propertyAccess.realTarget;
          cascade = propertyAccess.isCascaded;
        }
        // prepare arguments
        List<Expression> arguments = [];
        if (_node.inSetterContext()) {
          AssignmentExpression assignment =
              _node.getAncestor((node) => node is AssignmentExpression);
          arguments.add(assignment.rightHandSide);
        }
        // inline body
        _inlineMethodInvocation(status, usage, cascade, target, arguments);
        return;
      }
      // not invocation, just reference to function
      String source;
      {
        source = ref._methodUtils.getRangeText(rangeStartEnd(
            ref._methodParameters.leftParenthesis, ref._methodNode));
        String methodPrefix =
            ref._methodUtils.getLinePrefix(ref._methodNode.offset);
        source =
            _refUtils.replaceSourceIndent(source, methodPrefix, _refPrefix);
        source = source.trim();
        source = removeEnd(source, ';');
      }
      // do insert
      SourceRange range = rangeNode(_node);
      SourceEdit edit = newSourceEdit_range(range, source);
      _addRefEdit(edit);
    }
  }

  bool _shouldProcess() {
    if (!ref.inlineAll) {
      SourceRange parentRange = rangeNode(_node);
      return parentRange.contains(ref.offset);
    }
    return true;
  }
}

class _ReturnsValidatorVisitor extends RecursiveAstVisitor {
  final RefactoringStatus result;
  int _numReturns = 0;

  _ReturnsValidatorVisitor(this.result);

  @override
  visitReturnStatement(ReturnStatement node) {
    _numReturns++;
    if (_numReturns == 2) {
      result.addError('Ambiguous return value.', newLocation_fromNode(node));
    }
  }
}

/**
 * Information about the source of a method being inlined.
 */
class _SourcePart {
  /**
   * The base for all [SourceRange]s.
   */
  final int _base;

  /**
   * The source of the method.
   */
  final String _source;

  /**
   * The original prefix of the method.
   */
  final String _prefix;

  /**
   * The occurrences of the method parameters.
   */
  final Map<ParameterElement, List<_ParameterOccurrence>> _parameters = {};

  /**
   * The occurrences of the method local variables.
   */
  final Map<VariableElement, List<SourceRange>> _variables = {};

  /**
   * The offsets of explicit `this` expression references.
   */
  final List<int> _explicitThisOffsets = [];

  /**
   * The offsets of implicit `this` expression references.
   */
  final List<int> _implicitThisOffsets = [];

  /**
   * The offsets of the implicit class references in static field references.
   */
  final Map<String, List<int>> _staticFieldOffsets = {};

  _SourcePart(this._base, this._source, this._prefix);

  void addExplicitThisOffset(int offset) {
    _explicitThisOffsets.add(offset - _base);
  }

  void addImplicitThisOffset(int offset) {
    _implicitThisOffsets.add(offset - _base);
  }

  void addParameterOccurrence(
      ParameterElement parameter, SourceRange range, int precedence) {
    if (parameter != null) {
      List<_ParameterOccurrence> occurrences = _parameters[parameter];
      if (occurrences == null) {
        occurrences = [];
        _parameters[parameter] = occurrences;
      }
      range = rangeFromBase(range, _base);
      occurrences.add(new _ParameterOccurrence(precedence, range));
    }
  }

  void addStaticFieldOffset(String className, int offset) {
    List<int> offsets = _staticFieldOffsets[className];
    if (offsets == null) {
      offsets = [];
      _staticFieldOffsets[className] = offsets;
    }
    offsets.add(offset - _base);
  }

  void addVariable(VariableElement element, SourceRange range) {
    List<SourceRange> ranges = _variables[element];
    if (ranges == null) {
      ranges = [];
      _variables[element] = ranges;
    }
    range = rangeFromBase(range, _base);
    ranges.add(range);
  }
}

/**
 * A visitor that fills [_SourcePart] with fields, parameters and variables.
 */
class _VariablesVisitor extends GeneralizingAstVisitor {
  /**
   * The [ExecutableElement] being inlined.
   */
  final ExecutableElement methodElement;

  /**
   * The [SourceRange] of the element body.
   */
  SourceRange bodyRange;

  /**
   * The [_SourcePart] to record reference into.
   */
  _SourcePart result;

  int offset;

  _VariablesVisitor(this.methodElement, this.bodyRange, this.result);

  @override
  visitNode(AstNode node) {
    SourceRange nodeRange = rangeNode(node);
    if (!bodyRange.intersects(nodeRange)) {
      return null;
    }
    super.visitNode(node);
  }

  @override
  visitSimpleIdentifier(SimpleIdentifier node) {
    SourceRange nodeRange = rangeNode(node);
    if (bodyRange.covers(nodeRange)) {
      _addInstanceFieldQualifier(node);
      _addParameter(node);
      _addVariable(node);
    }
  }

  @override
  visitThisExpression(ThisExpression node) {
    int offset = node.offset;
    if (bodyRange.contains(offset)) {
      result.addExplicitThisOffset(offset);
    }
  }

  void _addInstanceFieldQualifier(SimpleIdentifier node) {
    PropertyAccessorElement accessor = getPropertyAccessorElement(node);
    if (isFieldAccessorElement(accessor)) {
      AstNode qualifier = getNodeQualifier(node);
      if (qualifier == null) {
        int offset = node.offset;
        if (accessor.isStatic) {
          String className = accessor.enclosingElement.displayName;
          result.addStaticFieldOffset(className, offset);
        } else {
          result.addImplicitThisOffset(offset);
        }
      }
    }
  }

  void _addParameter(SimpleIdentifier node) {
    ParameterElement parameterElement = getParameterElement(node);
    // not a parameter
    if (parameterElement == null) {
      return;
    }
    // not a parameter of the function being inlined
    if (!methodElement.parameters.contains(parameterElement)) {
      return;
    }
    // OK, add occurrence
    SourceRange nodeRange = rangeNode(node);
    int parentPrecedence = getExpressionParentPrecedence(node);
    result.addParameterOccurrence(
        parameterElement, nodeRange, parentPrecedence);
  }

  void _addVariable(SimpleIdentifier node) {
    VariableElement variableElement = getLocalVariableElement(node);
    if (variableElement != null) {
      SourceRange nodeRange = rangeNode(node);
      result.addVariable(variableElement, nodeRange);
    }
  }
}
