#!/usr/bin/python
# Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

"""This module provides shared functionality for the systems to generate
native binding from the IDL database."""

import emitter
import os
import systembase
from generator import *


class NativeImplementationSystem(systembase.System):

  def __init__(self, options, auxiliary_dir):
    super(NativeImplementationSystem, self).__init__(options)
    self._auxiliary_dir = auxiliary_dir
    self._cpp_header_files = []
    self._cpp_impl_files = []

  def ImplementationGenerator(self, interface):
    return NativeImplementationGenerator(self, interface)

  def ProcessCallback(self, interface, info):
    self._interface = interface

    if IsPureInterface(self._interface.id):
      return None

    cpp_impl_includes = set()
    cpp_header_handlers_emitter = emitter.Emitter()
    cpp_impl_handlers_emitter = emitter.Emitter()
    class_name = 'Dart%s' % self._interface.id
    for operation in interface.operations:
      if operation.type.id == 'void':
        return_prefix = ''
        error_return = ''
      else:
        return_prefix = 'return '
        error_return = ' false'

      parameters = []
      arguments = []
      conversion_includes = []
      for argument in operation.arguments:
        argument_type_info = self._type_registry.TypeInfo(argument.type.id)
        parameters.append('%s %s' % (argument_type_info.parameter_type(),
                                     argument.id))
        arguments.append(argument_type_info.to_dart_conversion(argument.id))
        conversion_includes.extend(argument_type_info.conversion_includes())

      native_return_type = self._type_registry.TypeInfo(operation.type.id).native_type()
      cpp_header_handlers_emitter.Emit(
          '\n'
          '    virtual $TYPE handleEvent($PARAMETERS);\n',
          TYPE=native_return_type, PARAMETERS=', '.join(parameters))

      if 'Custom' in operation.ext_attrs:
        continue

      cpp_impl_includes |= set(conversion_includes)
      arguments_declaration = 'Dart_Handle arguments[] = { %s }' % ', '.join(arguments)
      if not len(arguments):
        arguments_declaration = 'Dart_Handle* arguments = 0'
      cpp_impl_handlers_emitter.Emit(
          '\n'
          '$TYPE $CLASS_NAME::handleEvent($PARAMETERS)\n'
          '{\n'
          '    if (!m_callback.isolate()->isAlive())\n'
          '        return$ERROR_RETURN;\n'
          '    DartIsolate::Scope scope(m_callback.isolate());\n'
          '    DartApiScope apiScope;\n'
          '    $ARGUMENTS_DECLARATION;\n'
          '    $(RETURN_PREFIX)m_callback.handleEvent($ARGUMENT_COUNT, arguments);\n'
          '}\n',
          TYPE=native_return_type,
          CLASS_NAME=class_name,
          PARAMETERS=', '.join(parameters),
          ERROR_RETURN=error_return,
          RETURN_PREFIX=return_prefix,
          ARGUMENTS_DECLARATION=arguments_declaration,
          ARGUMENT_COUNT=len(arguments))

    cpp_header_path = self._FilePathForCppHeader(self._interface.id)
    cpp_header_emitter = self._emitters.FileEmitter(cpp_header_path)
    cpp_header_emitter.Emit(
        self._templates.Load('cpp_callback_header.template'),
        INTERFACE=self._interface.id,
        HANDLERS=cpp_header_handlers_emitter.Fragments())

    cpp_impl_path = self._FilePathForCppImplementation(self._interface.id)
    self._cpp_impl_files.append(cpp_impl_path)
    cpp_impl_emitter = self._emitters.FileEmitter(cpp_impl_path)
    cpp_impl_emitter.Emit(
        self._templates.Load('cpp_callback_implementation.template'),
        INCLUDES=_GenerateCPPIncludes(cpp_impl_includes),
        INTERFACE=self._interface.id,
        HANDLERS=cpp_impl_handlers_emitter.Fragments())

  def GenerateLibraries(self, interface_files):
    # Generate dart:html library.
    auxiliary_dir = os.path.relpath(self._auxiliary_dir, self._output_dir)
    self._GenerateLibFile(
        'html_dartium.darttemplate',
        os.path.join(self._output_dir, 'html_dartium.dart'),
        interface_files,
        AUXILIARY_DIR=systembase.MassagePath(auxiliary_dir))

    # Generate DartDerivedSourcesXX.cpp.
    partitions = 20 # FIXME: this should be configurable.
    sources_count = len(self._cpp_impl_files)
    for i in range(0, partitions):
      derived_sources_path = os.path.join(self._output_dir,
          'DartDerivedSources%02i.cpp' % (i + 1))

      includes_emitter = emitter.Emitter()
      for impl_file in self._cpp_impl_files[i::partitions]:
          path = os.path.relpath(impl_file, os.path.dirname(derived_sources_path))
          includes_emitter.Emit('#include "$PATH"\n', PATH=path)

      derived_sources_emitter = self._emitters.FileEmitter(derived_sources_path)
      derived_sources_emitter.Emit(
          self._templates.Load('cpp_derived_sources.template'),
          INCLUDES=includes_emitter.Fragments())

    # Generate DartResolver.cpp.
    cpp_resolver_path = os.path.join(self._output_dir, 'DartResolver.cpp')

    includes_emitter = emitter.Emitter()
    resolver_body_emitter = emitter.Emitter()
    for file in self._cpp_header_files:
        path = os.path.relpath(file, os.path.dirname(cpp_resolver_path))
        includes_emitter.Emit('#include "$PATH"\n', PATH=path)
        resolver_body_emitter.Emit(
            '    if (Dart_NativeFunction func = $CLASS_NAME::resolver(name, argumentCount))\n'
            '        return func;\n',
            CLASS_NAME=os.path.splitext(os.path.basename(path))[0])

    cpp_resolver_emitter = self._emitters.FileEmitter(cpp_resolver_path)
    cpp_resolver_emitter.Emit(
        self._templates.Load('cpp_resolver.template'),
        INCLUDES=includes_emitter.Fragments(),
        RESOLVER_BODY=resolver_body_emitter.Fragments())

  def Finish(self):
    pass

  def _FilePathForCppHeader(self, interface_name):
    return os.path.join(self._output_dir, 'cpp', 'Dart%s.h' % interface_name)

  def _FilePathForCppImplementation(self, interface_name):
    return os.path.join(self._output_dir, 'cpp', 'Dart%s.cpp' % interface_name)


class NativeImplementationGenerator(systembase.BaseGenerator):
  """Generates Dart implementation for one DOM IDL interface."""

  def __init__(self, system, interface):
    """Generates Dart and C++ code for the given interface.

    Args:
      system: The NativeImplementationSystem.
      interface: an IDLInterface instance. It is assumed that all types have
          been converted to Dart types (e.g. int, String), unless they are in
          the same package as the interface.
    """
    super(NativeImplementationGenerator, self).__init__(
        system._database, interface)
    self._system = system
    self._current_secondary_parent = None
    self._html_interface_name = system._renamer.RenameInterface(self._interface)

  def HasImplementation(self):
    return not IsPureInterface(self._interface.id)

  def ImplementationClassName(self):
    return self._ImplClassName(self._interface.id)

  def FilePathForDartImplementation(self):
    return os.path.join(self._system._output_dir, 'dart',
                        '%sImplementation.dart' % self._interface.id)

  def FilePathForDartFactoryProviderImplementation(self):
    file_name = '%sFactoryProviderImplementation.dart' % self._interface.id
    return os.path.join(self._system._output_dir, 'dart', file_name)

  def FilePathForDartElementsFactoryProviderImplementation(self):
    return os.path.join(self._system._output_dir, 'dart',
                        '_ElementsFactoryProviderImplementation.dart')

  def SetImplementationEmitter(self, implementation_emitter):
    self._dart_impl_emitter = implementation_emitter

  def ImplementsMergedMembers(self):
    # We could not add merged functions to implementation class because
    # underlying c++ object doesn't implement them. Merged functions are
    # generated on merged interface implementation instead.
    return False

  def StartInterface(self):
    # Create emitters for c++ implementation.
    if self.HasImplementation():
      cpp_header_path = self._system._FilePathForCppHeader(self._interface.id)
      self._system._cpp_header_files.append(cpp_header_path)
      self._cpp_header_emitter = self._system._emitters.FileEmitter(cpp_header_path)
      cpp_impl_path = self._system._FilePathForCppImplementation(self._interface.id)
      self._system._cpp_impl_files.append(cpp_impl_path)
      self._cpp_impl_emitter = self._system._emitters.FileEmitter(cpp_impl_path)
    else:
      self._cpp_header_emitter = emitter.Emitter()
      self._cpp_impl_emitter = emitter.Emitter()

    self._interface_type_info = self._TypeInfo(self._interface.id)
    self._members_emitter = emitter.Emitter()
    self._cpp_declarations_emitter = emitter.Emitter()
    self._cpp_impl_includes = set()
    self._cpp_definitions_emitter = emitter.Emitter()
    self._cpp_resolver_emitter = emitter.Emitter()

    self._GenerateConstructors()
    return self._members_emitter

  def _GenerateConstructors(self):
    if not self._IsConstructable():
      return

    # TODO(antonm): currently we don't have information about number of arguments expected by
    # the constructor, so name only dispatch.
    self._cpp_resolver_emitter.Emit(
        '    if (name == "$(INTERFACE_NAME)_constructor_Callback")\n'
        '        return Dart$(INTERFACE_NAME)Internal::constructorCallback;\n',
        INTERFACE_NAME=self._interface.id)


    constructor_info = AnalyzeConstructor(self._interface)

    ext_attrs = self._interface.ext_attrs

    if 'CustomConstructor' in ext_attrs:
      # We have a custom implementation for it.
      self._cpp_declarations_emitter.Emit(
          '\n'
          'void constructorCallback(Dart_NativeArguments);\n')
      return

    raises_dom_exceptions = 'ConstructorRaisesException' in ext_attrs
    raises_exceptions = raises_dom_exceptions or len(constructor_info.idl_args) > 0
    arguments = []
    parameter_definitions_emitter = emitter.Emitter()
    create_function = 'create'
    if 'NamedConstructor' in ext_attrs:
      raises_exceptions = True
      self._cpp_impl_includes.add('"DOMWindow.h"')
      parameter_definitions_emitter.Emit(
            '        DOMWindow* domWindow = DartUtilities::domWindowForCurrentIsolate();\n'
            '        if (!domWindow) {\n'
            '            exception = Dart_NewString("Failed to fetch domWindow");\n'
            '            goto fail;\n'
            '        }\n'
            '        Document* document = domWindow->document();\n')
      arguments.append('document')
      create_function = 'createForJSConstructor'
    if 'CallWith' in ext_attrs:
      call_with = ext_attrs['CallWith']
      if call_with == 'ScriptExecutionContext':
        raises_exceptions = True
        parameter_definitions_emitter.Emit(
            '        ScriptExecutionContext* context = DartUtilities::scriptExecutionContext();\n'
            '        if (!context) {\n'
            '            exception = Dart_NewString("Failed to create an object");\n'
            '            goto fail;\n'
            '        }\n')
        arguments.append('context')
      else:
        raise Exception('Unsupported CallWith=%s attribute' % call_with)

    # Process constructor arguments.
    for (i, argument) in enumerate(constructor_info.idl_args):
      argument_expression = self._GenerateToNative(
          parameter_definitions_emitter, argument, i)
      arguments.append(argument_expression)

    function_expression = '%s::%s' % (self._interface_type_info.native_type(), create_function)
    invocation = self._GenerateWebCoreInvocation(function_expression, arguments,
        self._interface.id, ext_attrs, raises_dom_exceptions)

    runtime_check = None
    database = self._database
    assert (not (
      'synthesizedV8EnabledPerContext' in ext_attrs and
      'synthesizedV8EnabledAtRuntime' in ext_attrs))
    if 'synthesizedV8EnabledPerContext' in ext_attrs:
      raises_exceptions = True
      self._cpp_impl_includes.add('"ContextFeatures.h"')
      self._cpp_impl_includes.add('"DOMWindow.h"')
      runtime_check = emitter.Format(
          '        if (!ContextFeatures::$(FEATURE)Enabled(DartUtilities::domWindowForCurrentIsolate()->document())) {\n'
          '            exception = Dart_NewString("Feature $FEATURE is not enabled");\n'
          '            goto fail;\n'
          '        }',
          FEATURE=ext_attrs['synthesizedV8EnabledPerContext'])

    if 'synthesizedV8EnabledAtRuntime' in ext_attrs:
      raises_exceptions = True
      self._cpp_impl_includes.add('"RuntimeEnabledFeatures.h"')
      runtime_check = emitter.Format(
          '        if (!RuntimeEnabledFeatures::$(FEATURE)Enabled()) {\n'
          '            exception = Dart_NewString("Feature $FEATURE is not enabled");\n'
          '            goto fail;\n'
          '        }',
          FEATURE=_ToWebKitName(ext_attrs['synthesizedV8EnabledAtRuntime']))

    self._GenerateNativeCallback(callback_name='constructorCallback',
        parameter_definitions=parameter_definitions_emitter.Fragments(),
        needs_receiver=False, invocation=invocation,
        raises_exceptions=raises_exceptions,
        runtime_check=runtime_check,
        requires_v8_scope=self._RequiresV8Scope(ext_attrs, constructor_info.idl_args))


  def _ImplClassName(self, interface_name):
    return '_%sImpl' % interface_name

  def _BaseClassName(self):
    root_class = 'NativeFieldWrapperClass1'

    if not self._interface.parents:
      return root_class

    supertype = self._interface.parents[0].type.id

    if IsPureInterface(supertype):    # The class is a root.
      return root_class

    # FIXME: We're currently injecting List<..> and EventTarget as
    # supertypes in dart.idl. We should annotate/preserve as
    # attributes instead.  For now, this hack lets the self._interfaces
    # inherit, but not the classes.
    # List methods are injected in AddIndexer.
    if IsDartListType(supertype) or IsDartCollectionType(supertype):
      return root_class

    return self._ImplClassName(supertype)

  def _IsConstructable(self):
    # FIXME: support ConstructorTemplate.
    return set(['CustomConstructor', 'V8CustomConstructor', 'Constructor', 'NamedConstructor']) & set(self._interface.ext_attrs)

  def EmitFactoryProvider(self, constructor_info, factory_provider, emitter):
    template_file = 'factoryprovider_%s.darttemplate' % self._html_interface_name
    template = self._system._templates.TryLoad(template_file)
    if not template:
      template = self._system._templates.Load('factoryprovider.darttemplate')

    native_binding = '%s_constructor_Callback' % self._interface.id
    emitter.Emit(
        template,
        FACTORYPROVIDER=factory_provider,
        INTERFACE=self._html_interface_name,
        PARAMETERS=constructor_info.ParametersImplementationDeclaration(self._DartType),
        ARGUMENTS=constructor_info.ParametersAsArgumentList(),
        NATIVE_NAME=native_binding)

  def FinishInterface(self):
    template = None
    if self._html_interface_name == self._interface.id or not self._database.HasInterface(self._html_interface_name):
      template_file = 'impl_%s.darttemplate' % self._html_interface_name
      template = self._system._templates.TryLoad(template_file)
    if not template:
      template = self._system._templates.Load('dart_implementation.darttemplate')

    class_name = self._ImplClassName(self._interface.id)
    members_emitter = self._dart_impl_emitter.Emit(
        template,
        CLASSNAME=class_name,
        EXTENDS=' extends ' + self._BaseClassName(),
        IMPLEMENTS=' implements ' + self._html_interface_name,
        NATIVESPEC='')
    members_emitter.Emit(''.join(self._members_emitter.Fragments()))

    self._GenerateCppHeader()

    self._cpp_impl_emitter.Emit(
        self._system._templates.Load('cpp_implementation.template'),
        INTERFACE=self._interface.id,
        INCLUDES=_GenerateCPPIncludes(self._cpp_impl_includes),
        CALLBACKS=self._cpp_definitions_emitter.Fragments(),
        RESOLVER=self._cpp_resolver_emitter.Fragments(),
        DART_IMPLEMENTATION_CLASS=class_name)

  def _GenerateCppHeader(self):
    to_native_emitter = emitter.Emitter()
    if self._interface_type_info.custom_to_native():
      to_native_emitter.Emit(
          '    static PassRefPtr<NativeType> toNative(Dart_Handle handle, Dart_Handle& exception);\n')
    else:
      to_native_emitter.Emit(
          '    static NativeType* toNative(Dart_Handle handle, Dart_Handle& exception)\n'
          '    {\n'
          '        return DartDOMWrapper::unwrapDartWrapper<Dart$INTERFACE>(handle, exception);\n'
          '    }\n',
          INTERFACE=self._interface.id)

    to_dart_emitter = emitter.Emitter()
    if ('CustomToJS' in self._interface.ext_attrs or
        'CustomToJSObject' in self._interface.ext_attrs or
        'PureInterface' in self._interface.ext_attrs or
        'CPPPureInterface' in self._interface.ext_attrs or
        self._interface_type_info.custom_to_dart()):
      to_dart_emitter.Emit(
          '    static Dart_Handle toDart(NativeType* value);\n')
    else:
      to_dart_emitter.Emit(
          '    static Dart_Handle toDart(NativeType* value)\n'
          '    {\n'
          '        return DartDOMWrapper::toDart<Dart$(INTERFACE)>(value);\n'
          '    }\n',
          INTERFACE=self._interface.id)

    webcore_includes = _GenerateCPPIncludes(self._interface_type_info.webcore_includes())

    is_node_test = lambda interface: interface.id == 'Node'
    is_active_test = lambda interface: 'ActiveDOMObject' in interface.ext_attrs
    is_event_target_test = lambda interface: 'EventTarget' in interface.ext_attrs
    def TypeCheckHelper(test):
      return 'true' if any(map(test, self._database.Hierarchy(self._interface))) else 'false'

    self._cpp_header_emitter.Emit(
        self._system._templates.Load('cpp_header.template'),
        INTERFACE=self._interface.id,
        WEBCORE_INCLUDES=webcore_includes,
        WEBCORE_CLASS_NAME=self._interface_type_info.native_type(),
        DECLARATIONS=self._cpp_declarations_emitter.Fragments(),
        IS_NODE=TypeCheckHelper(is_node_test),
        IS_ACTIVE=TypeCheckHelper(is_active_test),
        IS_EVENT_TARGET=TypeCheckHelper(is_event_target_test),
        TO_NATIVE=to_native_emitter.Fragments(),
        TO_DART=to_dart_emitter.Fragments())

  def _GenerateCallWithHandling(self, node, parameter_definitions_emitter, arguments):
    if 'CallWith' not in node.ext_attrs:
      return False

    call_with = node.ext_attrs['CallWith']
    if call_with == 'ScriptExecutionContext':
      parameter_definitions_emitter.Emit(
          '\n'
          '        ScriptExecutionContext* context = DartUtilities::scriptExecutionContext();\n'
          '        if (!context)\n'
          '            return;\n')
      arguments.append('context')
      return False

    if call_with == 'ScriptArguments|CallStack':
      self._cpp_impl_includes.add('"ScriptArguments.h"')
      self._cpp_impl_includes.add('"ScriptCallStack.h"')
      parameter_definitions_emitter.Emit(
          '\n'
          '        Dart_Handle customArgument = Dart_GetNativeArgument(args, $INDEX);\n'
          '        RefPtr<ScriptArguments> scriptArguments(DartUtilities::createScriptArguments(customArgument, exception));\n'
          '        if (!scriptArguments)\n'
          '            goto fail;\n'
          '        RefPtr<ScriptCallStack> scriptCallStack(DartUtilities::createScriptCallStack());\n'
          '        if (!scriptCallStack->size())\n'
          '            return;\n',
          INDEX=len(node.arguments))
      arguments.extend(['scriptArguments', 'scriptCallStack'])
      return True

    return False

  def AddAttribute(self, attribute, html_name, read_only):
    if 'CheckSecurityForNode' in attribute.ext_attrs:
      # FIXME: exclude from interface as well.
      return

    self._AddGetter(attribute, html_name)
    if not read_only:
      self._AddSetter(attribute, html_name)

  def _AddGetter(self, attr, html_name):
    type_info = self._TypeInfo(attr.type.id)
    dart_declaration = '%s get %s()' % (self._DartType(attr.type.id), html_name)
    is_custom = 'Custom' in attr.ext_attrs or 'CustomGetter' in attr.ext_attrs
    cpp_callback_name = self._GenerateNativeBinding(attr.id, 1,
        dart_declaration, 'Getter', is_custom)
    if is_custom:
      return

    arguments = []
    parameter_definitions_emitter = emitter.Emitter()
    raises_exceptions = self._GenerateCallWithHandling(
        attr, parameter_definitions_emitter, arguments)
    raises_exceptions = raises_exceptions or attr.get_raises

    if 'Reflect' in attr.ext_attrs:
      webcore_function_name = self._TypeInfo(attr.type.id).webcore_getter_name()
      if 'URL' in attr.ext_attrs:
        if 'NonEmpty' in attr.ext_attrs:
          webcore_function_name = 'getNonEmptyURLAttribute'
        else:
          webcore_function_name = 'getURLAttribute'
      arguments.append(self._GenerateWebCoreReflectionAttributeName(attr))
    else:
      if attr.id == 'operator':
        webcore_function_name = '_operator'
      elif attr.id == 'target' and attr.type.id == 'SVGAnimatedString':
        webcore_function_name = 'svgTarget'
      else:
        webcore_function_name = _ToWebKitName(attr.id)
      if attr.type.id.startswith('SVGAnimated'):
        webcore_function_name += 'Animated'

    function_expression = self._GenerateWebCoreFunctionExpression(webcore_function_name, attr)
    invocation = self._GenerateWebCoreInvocation(function_expression,
        arguments, attr.type.id, attr.ext_attrs, attr.get_raises)
    self._GenerateNativeCallback(cpp_callback_name, parameter_definitions_emitter.Fragments(),
        True, invocation, raises_exceptions=raises_exceptions,
        runtime_check=None,
        requires_v8_scope=self._RequiresV8Scope(attr.ext_attrs, []))

  def _AddSetter(self, attr, html_name):
    type_info = self._TypeInfo(attr.type.id)
    dart_declaration = 'void set %s(%s)' % (html_name, self._DartType(attr.type.id))
    is_custom = set(['Custom', 'CustomSetter', 'V8CustomSetter']) & set(attr.ext_attrs)
    cpp_callback_name = self._GenerateNativeBinding(attr.id, 2,
        dart_declaration, 'Setter', is_custom)
    if is_custom:
      return

    arguments = []
    parameter_definitions_emitter = emitter.Emitter()
    self._GenerateCallWithHandling(attr, parameter_definitions_emitter, arguments)

    if 'Reflect' in attr.ext_attrs:
      webcore_function_name = self._TypeInfo(attr.type.id).webcore_setter_name()
      arguments.append(self._GenerateWebCoreReflectionAttributeName(attr))
    else:
      webcore_function_name = re.sub(r'^(xml(?=[A-Z])|\w)',
                                     lambda s: s.group(1).upper(),
                                     attr.id)
      webcore_function_name = 'set%s' % webcore_function_name
      if attr.type.id.startswith('SVGAnimated'):
        webcore_function_name += 'Animated'

    argument_expression = self._GenerateToNative(
        parameter_definitions_emitter, attr, 1, argument_name='value')
    arguments.append(argument_expression)

    parameter_definitions = parameter_definitions_emitter.Fragments()
    function_expression = self._GenerateWebCoreFunctionExpression(webcore_function_name, attr)
    invocation = self._GenerateWebCoreInvocation(function_expression,
        arguments, 'void', attr.ext_attrs, attr.set_raises)

    self._GenerateNativeCallback(cpp_callback_name, parameter_definitions_emitter.Fragments(),
        True, invocation, raises_exceptions=True,
        runtime_check=None,
        requires_v8_scope=self._RequiresV8Scope(attr.ext_attrs, [attr]))

  def AddIndexer(self, element_type):
    """Adds all the methods required to complete implementation of List."""
    # We would like to simply inherit the implementation of everything except
    # get length(), [], and maybe []=.  It is possible to extend from a base
    # array implementation class only when there is no other implementation
    # inheritance.  There might be no implementation inheritance other than
    # DOMBaseWrapper for many classes, but there might be some where the
    # array-ness is introduced by a non-root interface:
    #
    #   interface Y extends X, List<T> ...
    #
    # In the non-root case we have to choose between:
    #
    #   class YImpl extends XImpl { add List<T> methods; }
    #
    # and
    #
    #   class YImpl extends ListBase<T> { copies of transitive XImpl methods; }
    #
    dart_element_type = self._DartType(element_type)
    if self._HasNativeIndexGetter():
      self._EmitNativeIndexGetter(dart_element_type)
    else:
      self._members_emitter.Emit(
          '\n'
          '  $TYPE operator[](int index) native "$(INTERFACE)_item_Callback";\n',
          TYPE=dart_element_type, INTERFACE=self._interface.id)

    if self._HasNativeIndexSetter():
      self._EmitNativeIndexSetter(dart_element_type)
    else:
      # The HTML library implementation of NodeList has a custom indexed setter
      # implementation that uses the parent node the NodeList is associated
      # with if one is available.
      if self._interface.id != 'NodeList':
        self._members_emitter.Emit(
            '\n'
            '  void operator[]=(int index, $TYPE value) {\n'
            '    throw new UnsupportedOperationException("Cannot assign element of immutable List.");\n'
            '  }\n',
            TYPE=dart_element_type)

    # The list interface for this class is manually generated.
    if self._interface.id == 'NodeList':
      return

    # TODO(sra): Use separate mixins for mutable implementations of List<T>.
    # TODO(sra): Use separate mixins for typed array implementations of List<T>.
    template_file = 'immutable_list_mixin.darttemplate'
    template = self._system._templates.Load(template_file)
    self._members_emitter.Emit(template, E=dart_element_type)

  def AmendIndexer(self, element_type):
    # If interface is marked as having native indexed
    # getter or setter, we must emit overrides as it's not
    # guaranteed that the corresponding methods in C++ would be
    # virtual.  For example, as of time of writing, even though
    # Uint8ClampedArray inherits from Uint8Array, ::set method
    # is not virtual and accessing it through Uint8Array pointer
    # would lead to wrong semantics (modulo vs. clamping.)
    dart_element_type = self._DartType(element_type)

    if self._HasNativeIndexGetter():
      self._EmitNativeIndexGetter(dart_element_type)
    if self._HasNativeIndexSetter():
      self._EmitNativeIndexSetter(dart_element_type)

  def _HasNativeIndexGetter(self):
    ext_attrs = self._interface.ext_attrs
    return ('CustomIndexedGetter' in ext_attrs or
        'NumericIndexedGetter' in ext_attrs)

  def _EmitNativeIndexGetter(self, element_type):
    dart_declaration = '%s operator[](int index)' % element_type
    self._GenerateNativeBinding('numericIndexGetter', 2, dart_declaration,
        'Callback', True)

  def _HasNativeIndexSetter(self):
    return 'CustomIndexedSetter' in self._interface.ext_attrs

  def _EmitNativeIndexSetter(self, element_type):
    dart_declaration = 'void operator[]=(int index, %s value)' % element_type
    self._GenerateNativeBinding('numericIndexSetter', 3, dart_declaration,
        'Callback', True)

  def AddOperation(self, info, html_name):
    """
    Arguments:
      info: An OperationInfo object.
    """

    operation = info.operations[0]

    if 'CheckSecurityForNode' in operation.ext_attrs:
      # FIXME: exclude from interface as well.
      return

    is_custom = 'Custom' in operation.ext_attrs
    has_optional_arguments = any(_IsArgumentOptionalInWebCore(argument) for argument in operation.arguments)
    needs_dispatcher = not is_custom and (len(info.operations) > 1 or has_optional_arguments)

    if not needs_dispatcher:
      type_renamer = self._DartType
      default_value = 'null'
    else:
      type_renamer = lambda x: 'Dynamic'
      default_value = '_null'

    dart_declaration = '%s%s %s(%s)' % (
        'static ' if info.IsStatic() else '',
        self._DartType(info.type_name),
        html_name,
        info.ParametersImplementationDeclaration(type_renamer, default_value))

    if not needs_dispatcher:
      # Bind directly to native implementation
      argument_count = (0 if info.IsStatic() else 1) + len(info.param_infos)
      cpp_callback_name = self._GenerateNativeBinding(
          info.name, argument_count, dart_declaration, 'Callback', is_custom)
      if not is_custom:
        self._GenerateOperationNativeCallback(operation, operation.arguments, cpp_callback_name)
    else:
      self._GenerateDispatcher(info.operations, dart_declaration, [info.name for info in info.param_infos])

  def _GenerateDispatcher(self, operations, dart_declaration, argument_names):

    body = self._members_emitter.Emit(
        '\n'
        '  $DECLARATION {\n'
        '$!BODY'
        '  }\n',
        DECLARATION=dart_declaration)

    version = [1]
    def GenerateCall(operation, argument_count, checks):
      if checks:
        if operation.type.id != 'void':
          template = '    if ($CHECKS) {\n      return $CALL;\n    }\n'
        else:
          template = '    if ($CHECKS) {\n      $CALL;\n      return;\n    }\n'
      else:
        if operation.type.id != 'void':
          template = '    return $CALL;\n'
        else:
          template = '    $CALL;\n'

      overload_name = '%s_%s' % (operation.id, version[0])
      version[0] += 1
      argument_list = ', '.join(argument_names[:argument_count])
      call = '_%s(%s)' % (overload_name, argument_list)
      body.Emit(template, CHECKS=' && '.join(checks), CALL=call)

      dart_declaration = '%s%s _%s(%s)' % (
          'static ' if operation.is_static else '',
          self._DartType(operation.type.id), overload_name, argument_list)
      cpp_callback_name = self._GenerateNativeBinding(
          overload_name, (0 if operation.is_static else 1) + argument_count,
          dart_declaration, 'Callback', False)
      self._GenerateOperationNativeCallback(operation, operation.arguments[:argument_count], cpp_callback_name)

    def GenerateChecksAndCall(operation, argument_count):
      checks = ['%s === _null' % name for name in argument_names]
      for i in range(0, argument_count):
        argument = operation.arguments[i]
        argument_name = argument_names[i]
        checks[i] = '(%s is %s || %s === null)' % (
            argument_name, self._DartType(argument.type.id), argument_name)
      GenerateCall(operation, argument_count, checks)

    # TODO: Optimize the dispatch to avoid repeated checks.
    if len(operations) > 1:
      for operation in operations:
        for position, argument in enumerate(operation.arguments):
          if _IsArgumentOptionalInWebCore(argument):
            GenerateChecksAndCall(operation, position)
        GenerateChecksAndCall(operation, len(operation.arguments))
      body.Emit('    throw "Incorrect number or type of arguments";\n');
    else:
      operation = operations[0]
      for position, argument in list(enumerate(operation.arguments))[::-1]:
        if _IsArgumentOptionalInWebCore(argument):
          check = '%s === _null' % argument_names[position]
          GenerateCall(operation, position, [check])
      GenerateCall(operation, len(operation.arguments), [])

  def SecondaryContext(self, interface):
    pass

  def _GenerateOperationNativeCallback(self, operation, arguments, cpp_callback_name):
    webcore_function_name = operation.ext_attrs.get('ImplementedAs', operation.id)

    parameter_definitions_emitter = emitter.Emitter()
    cpp_arguments = []
    raises_exceptions = self._GenerateCallWithHandling(
        operation, parameter_definitions_emitter, cpp_arguments)
    raises_exceptions = raises_exceptions or len(arguments) > 0 or operation.raises

    # Process Dart cpp_arguments.
    start_index = 1
    if operation.is_static:
      start_index = 0
    for (i, argument) in enumerate(arguments):
      if (i == len(arguments) - 1 and
          self._interface.id == 'Console' and
          argument.id == 'arg'):
        # FIXME: we are skipping last argument here because it was added in
        # supplemental dart.idl. Cleanup dart.idl and remove this check.
        break
      argument_expression = self._GenerateToNative(
          parameter_definitions_emitter, argument, start_index + i)
      cpp_arguments.append(argument_expression)

    if operation.id in ['addEventListener', 'removeEventListener']:
      # addEventListener's and removeEventListener's last argument is marked
      # as optional in idl, but is not optional in webcore implementation.
      if len(arguments) == 2:
        cpp_arguments.append('false')

    if self._interface.id == 'CSSStyleDeclaration' and operation.id == 'setProperty':
      # CSSStyleDeclaration.setProperty priority parameter is optional in Dart
      # idl, but is not optional in webcore implementation.
      if len(arguments) == 2:
        cpp_arguments.append('String()')

    if 'NeedsUserGestureCheck' in operation.ext_attrs:
      cpp_arguments.append('DartUtilities::processingUserGesture')

    function_expression = self._GenerateWebCoreFunctionExpression(webcore_function_name, operation)
    invocation = self._GenerateWebCoreInvocation(function_expression, cpp_arguments,
        operation.type.id, operation.ext_attrs, operation.raises)
    self._GenerateNativeCallback(cpp_callback_name,
        parameter_definitions=parameter_definitions_emitter.Fragments(),
        needs_receiver=not operation.is_static, invocation=invocation,
        raises_exceptions=raises_exceptions,
        runtime_check=None,
        requires_v8_scope=self._RequiresV8Scope(operation.ext_attrs, arguments))

  def _GenerateNativeCallback(self, callback_name, parameter_definitions,
      needs_receiver, invocation, raises_exceptions, runtime_check,
      requires_v8_scope):

    head_emitter = emitter.Emitter()

    if requires_v8_scope:
      head_emitter.Emit(
          '        V8Scope v8scope;\n\n')

    if runtime_check:
      head_emitter.Emit(
          '$RUNTIME_CHECK\n',
          RUNTIME_CHECK=runtime_check)

    if needs_receiver:
      head_emitter.Emit(
          '        $WEBCORE_CLASS_NAME* receiver = DartDOMWrapper::receiver< $WEBCORE_CLASS_NAME >(args);\n',
          WEBCORE_CLASS_NAME=self._interface_type_info.native_type())

    head_emitter.Emit(
        '$PARAMETE_DEFINITIONS\n',
        PARAMETE_DEFINITIONS=parameter_definitions)

    body = emitter.Format(
        '    {\n'
        '$HEAD'
        '$INVOCATION'
        '        return;\n'
        '    }\n',
        HEAD=head_emitter.Fragments(),
        INVOCATION=invocation)

    if raises_exceptions:
      body = emitter.Format(
          '    Dart_Handle exception = 0;\n'
          '$BODY'
          '\n'
          'fail:\n'
          '    Dart_ThrowException(exception);\n'
          '    ASSERT_NOT_REACHED();\n',
          BODY=body)

    self._cpp_definitions_emitter.Emit(
        '\n'
        'static void $CALLBACK_NAME(Dart_NativeArguments args)\n'
        '{\n'
        '    DartApiScope dartApiScope;\n'
        '$BODY'
        '}\n',
        CALLBACK_NAME=callback_name,
        BODY=body)

  def _GenerateToNative(self, emitter, idl_node, index, argument_name=None):
    """idl_node is IDLArgument or IDLAttribute."""
    type_info = self._TypeInfo(idl_node.type.id)
    self._cpp_impl_includes |= set(type_info.to_native_includes())
    argument_name = argument_name or idl_node.id
    handle = 'Dart_GetNativeArgument(args, %i)' % index
    argument_expression = type_info.emit_to_native(
        emitter, idl_node, argument_name, handle, self._interface.id)
    return argument_expression

  def _RequiresV8Scope(self, ext_attrs, arguments):
    if 'CallWith' in ext_attrs and ext_attrs['CallWith'] == 'ScriptArguments|CallStack':
      return True
    for argument in arguments:
      if self._TypeInfo(argument.type.id).requires_v8_scope():
        return True
    return False

  def _GenerateNativeBinding(self, idl_name, argument_count, dart_declaration,
      native_suffix, is_custom):
    native_binding = '%s_%s_%s' % (self._interface.id, idl_name, native_suffix)
    self._members_emitter.Emit(
        '\n'
        '  $DART_DECLARATION native "$NATIVE_BINDING";\n',
        DART_DECLARATION=dart_declaration, NATIVE_BINDING=native_binding)

    cpp_callback_name = '%s%s' % (idl_name, native_suffix)
    self._cpp_resolver_emitter.Emit(
        '    if (argumentCount == $ARGC && name == "$NATIVE_BINDING")\n'
        '        return Dart$(INTERFACE_NAME)Internal::$CPP_CALLBACK_NAME;\n',
        ARGC=argument_count,
        NATIVE_BINDING=native_binding,
        INTERFACE_NAME=self._interface.id,
        CPP_CALLBACK_NAME=cpp_callback_name)

    if is_custom:
      self._cpp_declarations_emitter.Emit(
          '\n'
          'void $CPP_CALLBACK_NAME(Dart_NativeArguments);\n',
          CPP_CALLBACK_NAME=cpp_callback_name)

    return cpp_callback_name

  def _GenerateWebCoreReflectionAttributeName(self, attr):
    namespace = 'HTMLNames'
    svg_exceptions = ['class', 'id', 'onabort', 'onclick', 'onerror', 'onload',
                      'onmousedown', 'onmousemove', 'onmouseout', 'onmouseover',
                      'onmouseup', 'onresize', 'onscroll', 'onunload']
    if self._interface.id.startswith('SVG') and not attr.id in svg_exceptions:
      namespace = 'SVGNames'
    self._cpp_impl_includes.add('"%s.h"' % namespace)

    attribute_name = attr.ext_attrs['Reflect'] or attr.id.lower()
    return 'WebCore::%s::%sAttr' % (namespace, attribute_name)

  def _GenerateWebCoreFunctionExpression(self, function_name, idl_node):
    if 'ImplementedBy' in idl_node.ext_attrs:
      return '%s::%s' % (idl_node.ext_attrs['ImplementedBy'], function_name)
    if idl_node.is_static:
      return '%s::%s' % (self._interface_type_info.idl_type(), function_name)
    return '%s%s' % (self._interface_type_info.receiver(), function_name)

  def _GenerateWebCoreInvocation(self, function_expression, arguments,
      idl_return_type, attributes, raises_dom_exceptions):
    invocation_template = '        $FUNCTION_CALL;\n'
    if idl_return_type != 'void':
      return_type_info = self._TypeInfo(idl_return_type)
      self._cpp_impl_includes |= set(return_type_info.conversion_includes())

      # Generate to Dart conversion of C++ value.
      to_dart_conversion = return_type_info.to_dart_conversion('$FUNCTION_CALL', self._interface.id, attributes)
      invocation_template = emitter.Format(
          '        Dart_Handle returnValue = $TO_DART_CONVERSION;\n'
          '        if (returnValue)\n'
          '            Dart_SetReturnValue(args, returnValue);\n',
          TO_DART_CONVERSION=to_dart_conversion)

    if raises_dom_exceptions:
      # Add 'ec' argument to WebCore invocation and convert DOM exception to Dart exception.
      arguments.append('ec')
      invocation_template = emitter.Format(
          '        ExceptionCode ec = 0;\n'
          '$INVOCATION'
          '        if (UNLIKELY(ec)) {\n'
          '            exception = DartDOMWrapper::exceptionCodeToDartException(ec);\n'
          '            goto fail;\n'
          '        }\n',
          INVOCATION=invocation_template)

    if 'ImplementedBy' in attributes:
      # FIXME: rather ugly way to solve the problem.
      index = 1 if 'ScriptExecutionContext' == attributes.get('CallWith') else 0
      arguments.insert(index, 'receiver')
      self._cpp_impl_includes.add('"%s.h"' % attributes['ImplementedBy'])

    return emitter.Format(invocation_template,
        FUNCTION_CALL='%s(%s)' % (function_expression, ', '.join(arguments)))

  def _TypeInfo(self, type_name):
    return self._system._type_registry.TypeInfo(type_name)


def _GenerateCPPIncludes(includes):
  return ''.join(['#include %s\n' % include for include in sorted(includes)])

def _FindInHierarchy(database, interface, test):
  if test(interface):
    return interface
  for parent in interface.parents:
    parent_name = parent.type.id
    if not database.HasInterface(parent.type.id):
      continue
    parent_interface = database.GetInterface(parent.type.id)
    parent_interface = _FindInHierarchy(database, parent_interface, test)
    if parent_interface:
      return parent_interface

def _IsArgumentOptionalInWebCore(argument):
  return IsOptional(argument) and not 'Callback' in argument.ext_attrs

def _ToWebKitName(name):
  name = name[0].lower() + name[1:]
  name = re.sub(r'^(hTML|uRL|jS|xML|xSLT)', lambda s: s.group(1).lower(),
                name)
  return re.sub(r'^(create|exclusive)', lambda s: 'is' + s.group(1).capitalize(),
                name)