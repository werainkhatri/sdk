// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../../../client/completion_driver_test.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(IfElementTest1);
    defineReflectiveTests(IfElementTest2);
  });
}

@reflectiveTest
class IfElementTest1 extends AbstractCompletionDriverTest
    with IfElementTestCases {
  @override
  TestingCompletionProtocol get protocol => TestingCompletionProtocol.version1;
}

@reflectiveTest
class IfElementTest2 extends AbstractCompletionDriverTest
    with IfElementTestCases {
  @override
  TestingCompletionProtocol get protocol => TestingCompletionProtocol.version2;
}

mixin IfElementTestCases on AbstractCompletionDriverTest {
  Future<void> test_rightParen_withCondition_withoutCase() async {
    await computeSuggestions('''
var v = [ if (o ^) ];
''');
    assertResponse('''
suggestions
  case
    kind: keyword
  is
    kind: keyword
''');
  }

  Future<void> test_rightParen_withoutCondition() async {
    await computeSuggestions('''
var v = [ if (^) ];
''');
    assertResponse('''
suggestions
  false
    kind: keyword
  true
    kind: keyword
  null
    kind: keyword
  const
    kind: keyword
  switch
    kind: keyword
''');
  }
}
