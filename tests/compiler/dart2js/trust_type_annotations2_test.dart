// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/expect.dart';
import "package:async_helper/async_helper.dart";
import 'memory_compiler.dart';

const MEMORY_SOURCE_FILES = const {
  'main.dart': '''

foo(int x, int y) {
  return x + y;
}

main (x, y) {
  if (x != null) {
    if (y != null) {
      return foo(x, y);
    }
  }
}
''',
};

main() {
  asyncTest(() async {
    var result = await runCompiler(
        memorySourceFiles: MEMORY_SOURCE_FILES,
        options: ['--trust-type-annotations']);
    var compiler = result.compiler;
    var element = compiler.mainFunction;
    var code = compiler.backend.assembleCode(element);
    Expect.isTrue(code.contains('+'), code);
  });
}
