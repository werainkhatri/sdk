// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';

import '../js_interop.dart'
    show
        getJSName,
        hasAnonymousAnnotation,
        hasInternalJSInteropAnnotation,
        hasJSInteropAnnotation,
        hasNativeAnnotation,
        hasStaticInteropAnnotation,
        hasTrustTypesAnnotation;

/// Replaces js_util methods with inline calls to foreign_helper JS which
/// emits the code as a JavaScript code fragment.
class JsUtilOptimizer extends Transformer {
  final Procedure _callMethodTarget;
  final Procedure _callMethodTrustTypeTarget;
  final List<Procedure> _callMethodUncheckedTargets;
  final List<Procedure> _callMethodUncheckedTrustTypeTargets;
  final Procedure _callConstructorTarget;
  final List<Procedure> _callConstructorUncheckedTargets;
  final Procedure _getPropertyTarget;
  final Procedure _getPropertyTrustTypeTarget;
  final Procedure _globalThisTarget;
  final InterfaceType _objectType;
  final Procedure _setPropertyTarget;
  final Procedure _setPropertyUncheckedTarget;

  /// Dynamic members in js_util that interop allowed.
  static final Iterable<String> _allowedInteropJsUtilMembers = <String>[
    'callConstructor',
    'callMethod',
    'getProperty',
    'jsify',
    'newObject',
    'setProperty'
  ];
  final Iterable<Procedure> _allowedInteropJsUtilTargets;
  final Procedure _jsTarget;
  final Procedure _allowInteropTarget;
  final Procedure _listEmptyFactory;

  final CoreTypes _coreTypes;
  final StatefulStaticTypeContext _staticTypeContext;

  late InlineExtensionIndex _inlineExtensionIndex;

  static const Set<String> _existingJsAnnotationsUsers = {
    'dart:_engine',
    'dart:ui'
  };

  JsUtilOptimizer(this._coreTypes, ClassHierarchy hierarchy)
      : _callMethodTarget =
            _coreTypes.index.getTopLevelProcedure('dart:js_util', 'callMethod'),
        _callMethodTrustTypeTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', '_callMethodTrustType'),
        _callMethodUncheckedTargets = List<Procedure>.generate(
            5,
            (i) => _coreTypes.index.getTopLevelProcedure(
                'dart:js_util', '_callMethodUnchecked$i')),
        _callMethodUncheckedTrustTypeTargets = List<Procedure>.generate(
            5,
            (i) => _coreTypes.index.getTopLevelProcedure(
                'dart:js_util', '_callMethodUncheckedTrustType$i')),
        _callConstructorTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'callConstructor'),
        _callConstructorUncheckedTargets = List<Procedure>.generate(
            5,
            (i) => _coreTypes.index.getTopLevelProcedure(
                'dart:js_util', '_callConstructorUnchecked$i')),
        _getPropertyTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'getProperty'),
        _getPropertyTrustTypeTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', '_getPropertyTrustType'),
        _globalThisTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'get:globalThis'),
        _objectType = hierarchy.coreTypes.objectNonNullableRawType,
        _setPropertyTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'setProperty'),
        _setPropertyUncheckedTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', '_setPropertyUnchecked'),
        _jsTarget =
            _coreTypes.index.getTopLevelProcedure('dart:_foreign_helper', 'JS'),
        _allowInteropTarget = _coreTypes.index
            .getTopLevelProcedure('dart:js_util', 'allowInterop'),
        _allowedInteropJsUtilTargets = _allowedInteropJsUtilMembers.map(
            (member) =>
                _coreTypes.index.getTopLevelProcedure('dart:js_util', member)),
        _listEmptyFactory =
            _coreTypes.index.getProcedure('dart:core', 'List', 'empty'),
        _staticTypeContext = StatefulStaticTypeContext.stacked(
            TypeEnvironment(_coreTypes, hierarchy)) {}

  @override
  visitLibrary(Library lib) {
    _inlineExtensionIndex = InlineExtensionIndex(lib);
    _staticTypeContext.enterLibrary(lib);
    lib.transformChildren(this);
    _staticTypeContext.leaveLibrary(lib);
    return lib;
  }

  @override
  defaultMember(Member node) {
    _staticTypeContext.enterMember(node);
    node.transformChildren(this);
    _staticTypeContext.leaveMember(node);
    return node;
  }

  @override
  visitProcedure(Procedure node) {
    _staticTypeContext.enterMember(node);
    ReturnStatement? transformedBody;
    if (node.isExternal) {
      if (_inlineExtensionIndex.isInstanceInteropMember(node)) {
        var shouldTrustType =
            _inlineExtensionIndex.isTrustTypesMember(node.reference);
        if (_isGetter(node)) {
          transformedBody = _getExternalGetterBody(node, shouldTrustType);
        } else if (_isSetter(node)) {
          transformedBody = _getExternalSetterBody(node);
        } else if (_isMethod(node)) {
          transformedBody = _getExternalMethodBody(node, shouldTrustType);
        }
      } else {
        // Do the lowerings for top-levels, static class members, and
        // constructors/factories.
        var dottedPrefix = _getDottedPrefixForStaticallyResolvableMember(node);
        if (dottedPrefix != null) {
          var receiver = _getObjectOffGlobalThis(
              node, dottedPrefix.isEmpty ? [] : dottedPrefix.split('.'));
          var shouldTrustType = node.enclosingClass != null &&
              hasTrustTypesAnnotation(node.enclosingClass!);
          if (_isGetter(node)) {
            transformedBody =
                _getExternalGetterBody(node, shouldTrustType, receiver);
          } else if (_isSetter(node)) {
            transformedBody = _getExternalSetterBody(node, receiver);
          } else if (_isMethod(node)) {
            transformedBody =
                _getExternalMethodBody(node, shouldTrustType, receiver);
          } else if (_isNonLiteralConstructor(node)) {
            transformedBody = _getExternalConstructorBody(
                node,
                // Get the constructor object using the class name.
                _getObjectOffGlobalThis(node, dottedPrefix.split('.')));
          }
        }
      }
    }
    if (transformedBody != null) {
      node.function.body = transformedBody;
      transformedBody.parent = node.function;
      node.isExternal = false;
    } else {
      node.transformChildren(this);
    }
    _staticTypeContext.leaveMember(node);
    return node;
  }

  bool _isOneOfKinds(Procedure node, InlineClassMemberKind inlineKind,
      ExtensionMemberKind extensionKind, ProcedureKind procedureKind) {
    var reference = node.reference;
    if (node.isInlineClassMember) {
      return _inlineExtensionIndex.getInlineDescriptor(reference)?.kind ==
          inlineKind;
    } else if (node.isExtensionMember) {
      return _inlineExtensionIndex.getExtensionDescriptor(reference)?.kind ==
          extensionKind;
    } else {
      return node.kind == procedureKind;
    }
  }

  bool _isGetter(Procedure node) => _isOneOfKinds(
      node,
      InlineClassMemberKind.Getter,
      ExtensionMemberKind.Getter,
      ProcedureKind.Getter);

  bool _isSetter(Procedure node) => _isOneOfKinds(
      node,
      InlineClassMemberKind.Setter,
      ExtensionMemberKind.Setter,
      ProcedureKind.Setter);

  bool _isMethod(Procedure node) => _isOneOfKinds(
      node,
      InlineClassMemberKind.Method,
      ExtensionMemberKind.Method,
      ProcedureKind.Method);

  bool _isNonLiteralConstructor(Procedure node) {
    if (node.isInlineClassMember) {
      var kind =
          _inlineExtensionIndex.getInlineDescriptor(node.reference)?.kind;
      return kind == InlineClassMemberKind.Constructor ||
          kind == InlineClassMemberKind.Factory;
    } else {
      return node.kind == ProcedureKind.Factory &&
          node.enclosingClass != null &&
          !hasAnonymousAnnotation(node.enclosingClass!);
    }
  }

  /// Returns the prefixed JS name for the given [node] using the enclosing
  /// library's, enclosing class' (if any), and member's `@JS` values.
  ///
  /// Returns null if [node] is not external and one of:
  /// 1. A top-level member
  /// 2. A `@staticInterop` factory
  /// 3. A `@staticInterop` static member
  /// 4. A `@JS` inline class constructor
  /// 5. A `@JS` inline class static member
  String? _getDottedPrefixForStaticallyResolvableMember(Procedure node) {
    if (!node.isExternal) return null;

    var dottedPrefix = getJSName(node.enclosingLibrary);

    if (!node.isInlineClassMember &&
        node.enclosingClass == null &&
        ((hasInternalJSInteropAnnotation(node) ||
                hasInternalJSInteropAnnotation(node.enclosingLibrary)) &&
            !_existingJsAnnotationsUsers
                .contains(node.enclosingLibrary.importUri.toString()))) {
      // Top-level external member. We only lower top-levels if we're using the
      // `dart:_js_annotations`' `@JS` annotation to avoid a breaking change for
      // `package:js` users. There are some internal libraries that already use
      // this library, so we exclude them here.
      // TODO(srujzs): When they're ready to migrate to sound semantics, we
      // should remove this exception.

      // If the `@JS` value of the node has any '.'s, we take the entries
      // before the last '.' to determine the dotted prefix name.
      var jsName = getJSName(node);
      if (jsName.isNotEmpty) {
        var lastDotIndex = jsName.lastIndexOf('.');
        if (lastDotIndex != -1) {
          dottedPrefix = _concatenateJSNames(
              dottedPrefix, jsName.substring(0, lastDotIndex));
        }
      }
    } else {
      Annotatable enclosingClass;
      if (node.isInlineClassMember) {
        var descriptor =
            _inlineExtensionIndex.getInlineDescriptor(node.reference);
        if (descriptor == null ||
            (!descriptor.isStatic &&
                descriptor.kind != InlineClassMemberKind.Constructor &&
                descriptor.kind != InlineClassMemberKind.Factory)) {
          return null;
        }
        enclosingClass = _inlineExtensionIndex.getInlineClass(node.reference)!;
      } else if (node.enclosingClass != null &&
          hasStaticInteropAnnotation(node.enclosingClass!)) {
        if (!node.isFactory && !node.isStatic) return null;
        enclosingClass = node.enclosingClass!;
      } else {
        return null;
      }
      // `@staticInterop` or `@JS` inline class
      // factory/constructor/static member, use the class name as part of the
      // dotted prefix.
      var className = getJSName(enclosingClass);
      if (className.isEmpty) {
        className = enclosingClass is Class
            ? enclosingClass.name
            : (enclosingClass as InlineClass).name;
      }
      dottedPrefix = _concatenateJSNames(dottedPrefix, className);
    }
    return dottedPrefix;
  }

  /// Given two `@JS` values, combines them into a concatenated name using '.'.
  ///
  /// If either parameters are empty, returns the other.
  String _concatenateJSNames(String prefix, String suffix) {
    if (prefix.isEmpty) return suffix;
    if (suffix.isEmpty) return prefix;
    return '$prefix.$suffix';
  }

  /// Given a list of strings, [selectors], recursively fetches the property
  /// that corresponds to each string off of the `globalThis` object.
  ///
  /// Returns an expression that contains the nested property gets.
  Expression _getObjectOffGlobalThis(Procedure node, List<String> selectors) {
    Expression currentTarget = StaticGet(_globalThisTarget)
      ..fileOffset = node.fileOffset;
    for (String selector in selectors) {
      currentTarget = StaticInvocation(
          _getPropertyTrustTypeTarget,
          Arguments([currentTarget, StringLiteral(selector)],
              types: [_objectType]))
        ..fileOffset = node.fileOffset;
    }
    return currentTarget;
  }

  /// Returns a new function body for the given [node] external getter.
  ///
  /// The new function body will call the optimized version of
  /// `js_util.getProperty` for the given external getter. If [shouldTrustType]
  /// is true, we call a variant that does not check the return type. If
  /// [receiver] is non-null, we use that instead of the first positional
  /// parameter as the receiver for `js_util.getProperty`.
  ReturnStatement _getExternalGetterBody(Procedure node, bool shouldTrustType,
      [Expression? receiver]) {
    var function = node.function;
    // Parameter `this` only exists for inline and extension instance members.
    assert(function.positionalParameters.length ==
        (_inlineExtensionIndex.isInstanceInteropMember(node) ? 1 : 0));
    Procedure target =
        shouldTrustType ? _getPropertyTrustTypeTarget : _getPropertyTarget;
    var getPropertyInvocation = StaticInvocation(
        target,
        Arguments([
          receiver ?? VariableGet(function.positionalParameters.first),
          StringLiteral(_getMemberJSName(node))
        ], types: [
          function.returnType
        ]))
      ..fileOffset = node.fileOffset;
    return ReturnStatement(getPropertyInvocation);
  }

  /// Returns a new function body for the given [node] external setter.
  ///
  /// The new function body will call the optimized version of
  /// `js_util.setProperty` for the given external setter. If [receiver] is
  /// non-null, we use that instead of the first positional parameter as the
  /// receiver for `js_util.setProperty`.
  ReturnStatement _getExternalSetterBody(Procedure node,
      [Expression? receiver]) {
    var function = node.function;
    // Parameter `this` only exists for inline and extension instance members.
    assert(function.positionalParameters.length ==
        (_inlineExtensionIndex.isInstanceInteropMember(node) ? 2 : 1));
    var value = function.positionalParameters.last;
    var setPropertyInvocation = StaticInvocation(
        _setPropertyTarget,
        Arguments([
          receiver ?? VariableGet(function.positionalParameters.first),
          StringLiteral(_getMemberJSName(node)),
          VariableGet(value)
        ], types: [
          value.type
        ]))
      ..fileOffset = node.fileOffset;
    return ReturnStatement(_lowerSetProperty(setPropertyInvocation));
  }

  /// Returns a new function body for the given [node] external method.
  ///
  /// The new function body will call the optimized version of
  /// `js_util.callMethod` for the given external method. If [shouldTrustType]
  /// is true, we call a variant that does not check the return type. If
  /// [receiver] is non-null, we use that instead of the first positional
  /// parameter as the receiver for `js_util.callMethod`.
  ReturnStatement _getExternalMethodBody(Procedure node, bool shouldTrustType,
      [Expression? receiver]) {
    var function = node.function;
    Procedure target =
        shouldTrustType ? _callMethodTrustTypeTarget : _callMethodTarget;
    var positionalParameters = function.positionalParameters;
    if (_inlineExtensionIndex.isInstanceInteropMember(node)) {
      // Ignore `this` for inline and extension members.
      positionalParameters = positionalParameters.sublist(1);
    }
    var callMethodInvocation = StaticInvocation(
        target,
        Arguments([
          receiver ?? VariableGet(function.positionalParameters.first),
          StringLiteral(_getMemberJSName(node)),
          ListLiteral(positionalParameters
              .map<Expression>((argument) => VariableGet(argument))
              .toList())
        ], types: [
          function.returnType
        ]))
      ..fileOffset = node.fileOffset;
    return ReturnStatement(_lowerCallMethod(callMethodInvocation,
        shouldTrustType: shouldTrustType));
  }

  /// Returns a new function body for the given [node] external non-object
  /// literal factory.
  ///
  /// The new function body will call the optimized version of
  /// `js_util.callConstructor` using the given [constructor] and the arguments
  /// of the provided external factory.
  ReturnStatement _getExternalConstructorBody(
      Procedure node, Expression constructor) {
    var function = node.function;
    assert(function.namedParameters.isEmpty);
    var callConstructorInvocation = StaticInvocation(
        _callConstructorTarget,
        Arguments([
          constructor,
          ListLiteral(function.positionalParameters
              .map<Expression>((argument) => VariableGet(argument))
              .toList())
        ], types: [
          function.returnType
        ]))
      ..fileOffset = node.fileOffset;
    return ReturnStatement(_lowerCallConstructor(callConstructorInvocation));
  }

  /// Returns the underlying JS name.
  ///
  /// Returns either the name from the `@JS` annotation if non-empty, or the
  /// declared name of the member. In the case of an extension or inline class
  /// member, this does not return the CFE generated name for the top level
  /// member, but rather the name of the original member.
  String _getMemberJSName(Procedure node) {
    var jsAnnotationName = getJSName(node);
    if (jsAnnotationName.isNotEmpty) {
      // In the case of top-level external members, this may contain '.'. The
      // namespacing before the last '.' should be resolved when we provide a
      // receiver to the lowerings. Here, we just take the final identifier.
      return jsAnnotationName.split('.').last;
    } else if (node.isExtensionMember) {
      return _inlineExtensionIndex
          .getExtensionDescriptor(node.reference)!
          .name
          .text;
    } else if (node.isInlineClassMember) {
      return _inlineExtensionIndex
          .getInlineDescriptor(node.reference)!
          .name
          .text;
    } else {
      return node.name.text;
    }
  }

  /// Replaces js_util method calls with optimization when possible.
  ///
  /// Lowers `setProperty` to  `_setPropertyUnchecked` for values that are
  /// not Function type and guaranteed to be interop allowed.
  /// Lowers `callMethod` to `_callMethodUncheckedN` when the number of given
  /// arguments is 0-4 and all arguments are guaranteed to be interop allowed.
  /// Lowers `callConstructor` to `_callConstructorUncheckedN` when there are
  /// 0-4 arguments and all arguments are guaranteed to be interop allowed.
  @override
  visitStaticInvocation(StaticInvocation node) {
    if (node.target == _setPropertyTarget) {
      node = _lowerSetProperty(node);
    } else if (node.target == _callMethodTarget) {
      // Never trust types on explicit `js_util` calls.
      node = _lowerCallMethod(node, shouldTrustType: false);
    } else if (node.target == _callConstructorTarget) {
      node = _lowerCallConstructor(node);
    }
    node.transformChildren(this);
    return node;
  }

  /// Lowers the given js_util `setProperty` call to `_setPropertyUnchecked`
  /// when the additional validation checks in `setProperty` can be elided.
  ///
  /// Removing the checks allows further inlining by the compilers.
  StaticInvocation _lowerSetProperty(StaticInvocation node) {
    Arguments arguments = node.arguments;
    assert(arguments.positional.length == 3);
    assert(arguments.named.isEmpty);

    if (!_allowedInterop(arguments.positional.last)) {
      return node;
    }

    return StaticInvocation(_setPropertyUncheckedTarget, arguments)
      ..fileOffset = node.fileOffset;
  }

  /// Lowers the given js_util `callMethod` call to `_callMethodUncheckedN`
  /// when the additional validation checks on the arguments can be elided.
  ///
  /// Calls will be lowered when using a List literal or constant list with 0-4
  /// elements for the `callMethod` arguments, or the `List.empty()` factory.
  /// Removing the checks allows further inlining by the compilers.
  StaticInvocation _lowerCallMethod(StaticInvocation node,
      {required bool shouldTrustType}) {
    Arguments arguments = node.arguments;
    assert(arguments.positional.length == 3);
    assert(arguments.named.isEmpty);
    List<Procedure> targets = shouldTrustType
        ? _callMethodUncheckedTrustTypeTargets
        : _callMethodUncheckedTargets;

    return _lowerToCallUnchecked(
        node, targets, arguments.positional.sublist(0, 2));
  }

  /// Lowers the given js_util `callConstructor` call to
  /// `_callConstructorUncheckedN` when the additional validation checks on the
  /// arguments can be elided.
  ///
  /// Calls will be lowered when using a List literal or constant list with 0-4
  /// elements for the `callConstructor` arguments, or the `List.empty()`
  /// factory. Removing the checks allows further inlining by the compilers.
  StaticInvocation _lowerCallConstructor(StaticInvocation node) {
    Arguments arguments = node.arguments;
    assert(arguments.positional.length == 2);
    assert(arguments.named.isEmpty);

    return _lowerToCallUnchecked(
        node, _callConstructorUncheckedTargets, [arguments.positional.first]);
  }

  /// Helper to lower the given [node] to the relevant unchecked target in the
  /// [callUncheckedTargets] based on whether the validation checks on the
  /// [originalArguments] can be elided.
  ///
  /// Calls will be lowered when using a List literal or constant list with 0-4
  /// arguments, or the `List.empty()` factory. Removing the checks allows further
  /// inlining by the compilers.
  StaticInvocation _lowerToCallUnchecked(
      StaticInvocation node,
      List<Procedure> callUncheckedTargets,
      List<Expression> originalArguments) {
    var argumentsList = node.arguments.positional.last;
    // Lower arguments in a List.empty factory call.
    if (argumentsList is StaticInvocation &&
        argumentsList.target == _listEmptyFactory) {
      return _createCallUncheckedNode(
          callUncheckedTargets,
          node.arguments.types,
          [],
          originalArguments,
          node.fileOffset,
          node.arguments.fileOffset);
    }

    // Lower arguments in other kinds of Lists.
    List<Expression> callUncheckedArguments;
    DartType entryType;
    if (argumentsList is ListLiteral) {
      if (argumentsList.expressions.length >= callUncheckedTargets.length) {
        return node;
      }
      callUncheckedArguments = argumentsList.expressions;
      entryType = argumentsList.typeArgument;
    } else if (argumentsList is ConstantExpression &&
        argumentsList.constant is ListConstant) {
      var argumentsListConstant = argumentsList.constant as ListConstant;
      if (argumentsListConstant.entries.length >= callUncheckedTargets.length) {
        return node;
      }
      callUncheckedArguments = argumentsListConstant.entries
          .map<Expression>((constant) => ConstantExpression(
              constant, constant.getType(_staticTypeContext)))
          .toList();
      entryType = argumentsListConstant.typeArgument;
    } else {
      // Skip lowering arguments in any other type of List.
      return node;
    }

    // Check the arguments List type, then verify each argument if needed.
    if (!_allowedInteropType(entryType)) {
      for (var argument in callUncheckedArguments) {
        if (!_allowedInterop(argument)) {
          return node;
        }
      }
    }

    return _createCallUncheckedNode(
        callUncheckedTargets,
        node.arguments.types,
        callUncheckedArguments,
        originalArguments,
        node.fileOffset,
        node.arguments.fileOffset);
  }

  /// Creates a new StaticInvocation node for the relevant unchecked target
  /// with the given 0-4 arguments.
  StaticInvocation _createCallUncheckedNode(
      List<Procedure> callUncheckedTargets,
      List<DartType> callUncheckedTypes,
      List<Expression> callUncheckedArguments,
      List<Expression> originalArguments,
      int nodeFileOffset,
      int argumentsFileOffset) {
    assert(callUncheckedArguments.length <= 4);
    return StaticInvocation(
        callUncheckedTargets[callUncheckedArguments.length],
        Arguments(
          [...originalArguments, ...callUncheckedArguments],
          types: callUncheckedTypes,
        )..fileOffset = argumentsFileOffset)
      ..fileOffset = nodeFileOffset;
  }

  /// Returns whether the given Expression is guaranteed to be allowed to
  /// interop with JS.
  ///
  /// Returns true when the node is guaranteed to be not a function:
  ///    - has a static DartType that is NullType or an InterfaceType that is
  ///      not Function or Object
  /// Also returns true for allowed method calls within the JavaScript domain:
  ///        - dart:_foreign_helper JS
  ///        - dart:js `allowInterop`
  ///        - dart:js_util and any of the `_allowedInteropJsUtilMembers`
  bool _allowedInterop(Expression node) {
    // TODO(rileyporter): Detect functions that have been wrapped at some point
    // with `allowInterop`
    if (node is StaticInvocation) {
      if (node.target == _allowInteropTarget) return true;
      if (node.target == _jsTarget) return true;
      if (_allowedInteropJsUtilTargets.contains(node.target)) return true;
    }

    return _allowedInteropType(node.getStaticType(_staticTypeContext));
  }

  /// Returns whether the given DartType is guaranteed to be not a function
  /// and therefore allowed to interop with JS.
  bool _allowedInteropType(DartType type) {
    if (type is InterfaceType) {
      return type.classNode != _coreTypes.functionClass &&
          type.classNode != _coreTypes.objectClass;
    } else {
      // Only other DartType guaranteed to not be a function.
      return type is NullType;
    }
  }
}

/// Lazily-initialized indexes for extension members and inline class members.
class InlineExtensionIndex {
  Map<Reference, ExtensionMemberDescriptor>? _extensionMemberIndex;
  late Map<Reference, InlineClass> _inlineClassIndex;
  Map<Reference, InlineClassMemberDescriptor>? _inlineMemberIndex;
  late Set<Reference> _shouldTrustType;

  final Library _library;

  InlineExtensionIndex(this._library);

  /// For all extension members in `_library` whose on-type has a
  /// `@JS` or `@Native` annotation, initializes `_extensionMemberIndex` to an
  /// index of the extension member references to the member's
  /// `ExtensionMemberDescriptor`.
  ///
  /// Also initializes `_shouldTrustType` to the set of extension member
  /// references whose on-type has a `@trustTypes` annotation.
  void _createExtensionIndexes() {
    if (_extensionMemberIndex != null) return;
    _extensionMemberIndex = {};
    _shouldTrustType = {};
    _library.extensions
        .forEach((extension) => extension.members.forEach((descriptor) {
              var reference = descriptor.member;
              var onType = extension.onType;
              Annotatable? cls;
              if (onType is InterfaceType) {
                cls = onType.classNode;
                // For now, `@trustTypes` can only be used on non-inline
                // classes.
                if (hasTrustTypesAnnotation(cls)) {
                  _shouldTrustType.add(reference);
                }
              } else if (onType is InlineType) {
                cls = onType.inlineClass;
              }
              if (cls == null) return;
              if (hasJSInteropAnnotation(cls) || hasNativeAnnotation(cls)) {
                _extensionMemberIndex![reference] = descriptor;
              }
            }));
  }

  ExtensionMemberDescriptor? getExtensionDescriptor(Reference reference) {
    _createExtensionIndexes();
    return _extensionMemberIndex![reference];
  }

  bool isTrustTypesMember(Reference reference) {
    _createExtensionIndexes();
    return _shouldTrustType.contains(reference);
  }

  /// For all inline class members in `_library` whose class has a `@JS`
  /// annotation, initializes `_inlineMemberIndex` and `_inlineClassIndex` to
  /// indices of the inline class member references to the member's
  /// `InlineClassMemberDescriptor` and `InlineClass`.
  void _createInlineIndexes() {
    if (_inlineMemberIndex != null) return;
    _inlineMemberIndex = {};
    _inlineClassIndex = {};
    _library.inlineClasses.forEach((inlineClass) {
      if (hasJSInteropAnnotation(inlineClass)) {
        inlineClass.members.forEach((descriptor) {
          var reference = descriptor.member;
          _inlineMemberIndex![reference] = descriptor;
          _inlineClassIndex[reference] = inlineClass;
        });
      }
    });
  }

  InlineClassMemberDescriptor? getInlineDescriptor(Reference reference) {
    _createInlineIndexes();
    return _inlineMemberIndex![reference];
  }

  InlineClass? getInlineClass(Reference reference) {
    _createInlineIndexes();
    return _inlineClassIndex[reference];
  }

  /// Return whether [node] is either an extension member that's declared as
  /// non-`static` or an inline class member that's declared as non-`static`
  /// and is not a factory or constructor.
  bool isInstanceInteropMember(Member node) {
    if (node.isExtensionMember) {
      var descriptor = getExtensionDescriptor(node.reference);
      return descriptor != null && !descriptor.isStatic;
    } else if (node.isInlineClassMember) {
      var descriptor = getInlineDescriptor(node.reference);
      return descriptor != null &&
          !descriptor.isStatic &&
          descriptor.kind != InlineClassMemberKind.Constructor &&
          descriptor.kind != InlineClassMemberKind.Factory;
    }
    return false;
  }
}
